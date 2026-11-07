#!/usr/bin/env bash
# Regression checks for the dev-session image's state handling, against a
# throwaway SeaweedFS on a throwaway network (local daemon: DOCKER_HOST=).
#   1. an unreachable bucket fails the start instead of cloning over it
#   2. push/restore keep executable bits and symlinks
#   3. the session's sshd allows no forwarding (agent, TCP, X11)
#   4. the SSH host key survives the container being recreated
set -uo pipefail
img="${1:-devbox-session:1}"
net=devsession-check
seaweed=chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882
fail=0
ok() { printf 'OK  %s\n' "$1"; }
ko() { printf 'KO  %s: %s\n' "$1" "$2"; fail=1; }
cleanup() {
  docker rm -f devsession-s3 devsession-a >/dev/null 2>&1
  docker volume rm devsession-work >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

docker network create "$net" >/dev/null
# No identities: SeaweedFS serves anonymously, any key signs.
docker run -d --name devsession-s3 --network "$net" --network-alias s3 "$seaweed" \
  server -s3 -s3.port=8333 -dir=/data >/dev/null
env=(-e SESSION=chk -e REPO_URL=https://github.com/o/r -e GH_TOKEN=dummy -e S3_SECRET_KEY=x
     -e "SSH_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtest test")
rc='mkdir -p ~/.config/rclone; printf "[s3]\ntype = s3\nprovider = SeaweedFS\nendpoint = http://s3:8333\naccess_key_id = devbox\nsecret_access_key = x\n" > ~/.config/rclone/rclone.conf'
sh_in() { docker run --rm --network "$net" "${env[@]}" --entrypoint "" "$img" bash -c "$rc; $1"; }
for _ in $(seq 60); do sh_in 'rclone mkdir s3:devbox' >/dev/null 2>&1 && break; sleep 2; done

# 1
out="$(docker run --rm --network none "${env[@]}" -e SESSION=nos3 "$img" 2>&1)"; code=$?
if [ "$code" -ne 0 ] && ! grep -q cloning <<<"$out"; then ok "unreachable bucket stops the start"
else ko "unreachable bucket stops the start" "exit $code, $(grep -m1 cloning <<<"$out")"; fi

# 2
sh_in 'printf "#!/bin/sh\n" > /work/x.sh && chmod 755 /work/x.sh && ln -s x.sh /work/l && SESSION=modes sync.sh push' >/dev/null 2>&1
if sh_in 'SESSION=modes sync.sh restore && test -x /work/x.sh && test -L /work/l' >/dev/null 2>&1; then
  ok "restore keeps exec bits and symlinks"
else ko "restore keeps exec bits and symlinks" "$(sh_in 'SESSION=modes sync.sh restore; ls -l /work' 2>&1 | tail -3 | tr '\n' ' ')"; fi

# 3, 4: a full start on a seeded /work (no clone needed)
docker run --rm -v devsession-work:/work --user 1000 --entrypoint git "$img" init -q /work
start() { docker run -d --name devsession-a --network "$net" "${env[@]}" -v devsession-work:/work "$img" >/dev/null
  for _ in $(seq 60); do docker exec devsession-a pgrep -x sshd >/dev/null 2>&1 && return; sleep 2; done
  docker logs devsession-a 2>&1 | tail -3; }
fp() { docker exec devsession-a sh -c 'ssh-keyscan -t ed25519 -p 2222 127.0.0.1 2>/dev/null' | awk '{print $3}'; }
start
cfg="$(docker exec devsession-a bash -c '/usr/sbin/sshd -T -f /etc/devbox/sshd_config 2>&1 || /usr/sbin/sshd -T -f ~/.ssh/sshd_config 2>&1')"
grep -qi '^disableforwarding yes' <<<"$cfg" && ok "session sshd forwards nothing" \
  || ko "session sshd forwards nothing" "$(grep -i forwarding <<<"$cfg" | tr '\n' ' ')"
k1="$(fp)"; docker rm -f devsession-a >/dev/null; start; k2="$(fp)"
[ -n "$k1" ] && [ "$k1" = "$k2" ] && ok "host key survives recreation" || ko "host key survives recreation" "${k1:0:12} vs ${k2:0:12}"
exit "$fail"
