#!/usr/bin/env bash
# Regression checks for the dev-session image's state handling, against a
# throwaway SeaweedFS (auth on, one identity per session, scoped like the
# devbox CLI scopes them) on a throwaway network. Local daemon only:
#   DOCKER_HOST= scripts/dev-session-check.sh [image]
set -uo pipefail
img="${1:-devbox-session:1}"
net=devsession-check
seaweed=chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882
fail=0
ok() { printf 'OK  %s\n' "$1"; }
ko() { printf 'KO  %s: %s\n' "$1" "$2"; fail=1; }
cleanup() {
  docker rm -f devsession-s3 devsession-a >/dev/null 2>&1
  for v in work state; do docker volume rm "devsession-$v" >/dev/null 2>&1; done
  docker network rm "$net" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

docker network create "$net" >/dev/null
docker run -d --name devsession-s3 --network "$net" --network-alias s3 "$seaweed" \
  server -s3 -s3.port=8333 -dir=/data >/dev/null
ws() { docker exec devsession-s3 sh -c "printf '%s\n' '$1' | weed shell -master=localhost:9333" >/dev/null 2>&1; }
for _ in $(seq 60); do ws "s3.bucket.create -name devbox" && break; sleep 2; done
ws "s3.configure -user admin -access_key admin -secret_key adminadminadmin1 -actions Admin -apply"
for s in nos3 modes part other chk; do
  ws "s3.configure -user devbox-$s -access_key devbox-$s -secret_key secret-$s-123456 -actions Read:devbox/$s/*,Write:devbox/$s/*,List:devbox/$s/* -apply"
done
sleep 2

envs() { # <session> [repo] -> E, the docker run -e flags
  E=(-e "SESSION=$1" -e "REPO_URL=${2:-https://github.com/o/r}" -e GH_TOKEN=dummy
     -e "SSH_PUBKEYS=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtest a,ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtest b"
     -e "S3_ACCESS_KEY=devbox-$1" -e "S3_SECRET_KEY=secret-$1-123456")
}
rc='mkdir -p ~/.config/rclone; printf "[s3]\ntype = s3\nprovider = SeaweedFS\nendpoint = http://s3:8333\nno_check_bucket = true\naccess_key_id = $S3_ACCESS_KEY\nsecret_access_key = $S3_SECRET_KEY\n" > ~/.config/rclone/rclone.conf'
sh_in() { envs "$1"; shift; docker run --rm --network "$net" "${E[@]}" --entrypoint "" "$@" "$img" bash -c "$rc; $CMD"; }
repo='cd /work && git init -q -b main && git config user.email t@t && git config user.name t && git remote add origin https://github.com/o/r.git'

# 1. unreachable bucket stops the start
envs nos3; out="$(docker run --rm --network none "${E[@]}" "$img" 2>&1)"; code=$?
[ "$code" -ne 0 ] && ! grep -q cloning <<<"$out" && ok "unreachable bucket stops the start" \
  || ko "unreachable bucket stops the start" "exit $code, $(grep -m1 cloning <<<"$out")"

# 2. modes, symlinks and a gc'ed repo survive push + restore; no push before ready
CMD="$repo && printf '#!/bin/sh\n' > x.sh && chmod 755 x.sh && ln -s x.sh l && git add -A && git commit -qm c && git gc -q && mkdir -p \$STATE && touch \$STATE/ready && sync.sh push" \
  sh_in modes >/dev/null 2>&1
CMD='sync.sh restore && test -x /work/x.sh && test -L /work/l && git -C /work log --oneline >/dev/null' sh_in modes >/dev/null 2>&1 \
  && ok "restore keeps modes, symlinks and a gc'ed repo" \
  || ko "restore keeps modes, symlinks and a gc'ed repo" "$(CMD='sync.sh restore; ls -l /work; git -C /work log 2>&1 | head -1' sh_in modes 2>&1 | tail -3 | tr '\n' ' ')"
CMD='rm -f $STATE/ready; sync.sh push' sh_in modes >/dev/null 2>&1 \
  && ko "no push before ready" "push ran without the marker" || ok "no push before ready"

# 3. a partial /work (interrupted restore) is completed, not pushed over
CMD="$repo && for i in 1 2 3; do echo \$i > f\$i; done && git add -A && git commit -qm c && mkdir -p \$STATE && touch \$STATE/ready && sync.sh push" \
  sh_in part >/dev/null 2>&1
docker run --rm -v devsession-work:/work --user 1000 --entrypoint "" "$img" bash -c "$repo && echo 1 > f1" >/dev/null 2>&1
envs part; docker run -d --name devsession-a --network "$net" "${E[@]}" -e SYNC_INTERVAL=2 \
  -v devsession-work:/work -v devsession-state:/home/dev/state "$img" >/dev/null
for _ in $(seq 60); do docker exec devsession-a pgrep -x sshd >/dev/null 2>&1 && break; sleep 2; done
sleep 5
CMD='rclone lsf s3:devbox/part/work/ | grep -c "^f[123]$"' sh_in part 2>/dev/null | grep -qx 3 \
  && docker exec devsession-a test -f /work/f3 && ok "partial /work is completed, bucket intact" \
  || ko "partial /work is completed, bucket intact" "$(CMD='rclone lsf s3:devbox/part/work/' sh_in part 2>&1 | tr '\n' ' ')"

# 4. forwarding off, 5. host key survives recreation (same volumes)
cfg="$(docker exec devsession-a /usr/sbin/sshd -T -f /home/dev/.ssh/sshd_config 2>&1)"
grep -qi '^disableforwarding yes' <<<"$cfg" && ok "session sshd forwards nothing" \
  || ko "session sshd forwards nothing" "$(grep -i forwarding <<<"$cfg" | tr '\n' ' ')"
fp() { docker exec devsession-a sh -c 'ssh-keyscan -t ed25519 -p 2222 127.0.0.1 2>/dev/null' | awk '{print $3}'; }
k1="$(fp)"
# 6. every configured key is authorised
[ "$(docker exec devsession-a grep -c '^ssh-' /home/dev/.ssh/authorized_keys)" = 2 ] && ok "all owner keys authorised" \
  || ko "all owner keys authorised" "$(docker exec devsession-a cat /home/dev/.ssh/authorized_keys)"
# 7. docker stop of a running session is quick and pushes
t0=$(date +%s); docker stop -t 60 devsession-a >/dev/null; t1=$(date +%s)
docker logs devsession-a 2>&1 | grep -q 'final sync' && [ $((t1 - t0)) -lt 30 ] && ok "stop pushes and returns ($((t1 - t0))s)" \
  || ko "stop pushes and returns" "$((t1 - t0))s, $(docker logs devsession-a 2>&1 | tail -1)"
docker rm -f devsession-a >/dev/null
envs part; docker run -d --name devsession-a --network "$net" "${E[@]}" -v devsession-work:/work -v devsession-state:/home/dev/state "$img" >/dev/null
for _ in $(seq 60); do docker exec devsession-a pgrep -x sshd >/dev/null 2>&1 && break; sleep 2; done
k2="$(fp)"
[ -n "$k1" ] && [ "$k1" = "$k2" ] && ok "host key survives recreation" || ko "host key survives recreation" "${k1:20:12} vs ${k2:20:12}"
docker rm -f devsession-a >/dev/null

# 8. a stop during setup (bucket unreachable, rclone retrying) is quick
envs nos3; docker run -d --name devsession-a --network none "${E[@]}" "$img" >/dev/null; sleep 3
t0=$(date +%s); docker stop -t 60 devsession-a >/dev/null; t1=$(date +%s)
[ $((t1 - t0)) -lt 15 ] && ok "stop during setup is quick ($((t1 - t0))s)" || ko "stop during setup is quick" "$((t1 - t0))s"
docker rm -f devsession-a >/dev/null

# 9. a name reused for another repo refuses to start
for v in work state; do docker volume rm "devsession-$v" >/dev/null 2>&1; done
envs part https://github.com/o/other; out="$(docker run --rm --network "$net" "${E[@]}" -v devsession-work:/work -v devsession-state:/home/dev/state "$img" 2>&1)"; code=$?
[ "$code" -ne 0 ] && grep -q 'checkout of' <<<"$out" && ok "other repo under a reused name refused" \
  || ko "other repo under a reused name refused" "exit $code, $(tail -1 <<<"$out")"

exit "$fail"
