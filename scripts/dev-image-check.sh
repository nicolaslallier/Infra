#!/usr/bin/env bash
# Smoke test for devbox-session:1 (make dev-image): toolchain present, non-root,
# no sudo, then the REAL entrypoint against a stub S3 on a throwaway --internal
# network (no Internet, no proxy). Everything it creates is named
# devbox-smoke-<pid>* and removed on exit. Works across DOCKER_HOST: no bind mount.
set -euo pipefail
IMG="${DEVBOX_IMAGE:-devbox-session:1}"
for c in "node --version" "python3 --version" "rustc --version" "cc --version" \
         "pkg-config --version" "claude --version" "gh --version" "rclone version"; do
  # shellcheck disable=SC2086
  docker run --rm --entrypoint ${c%% *} "$IMG" ${c#* } >/dev/null || { echo "FAIL: $c" >&2; exit 1; }
  echo "ok: $c"
done
uid="$(docker run --rm --entrypoint id "$IMG" -u)"
[ "$uid" != 0 ] || { echo "FAIL: runs as root" >&2; exit 1; }
echo "ok: uid $uid"
if docker run --rm --entrypoint sh "$IMG" -c 'command -v sudo' >/dev/null; then echo "FAIL: sudo present" >&2; exit 1; fi
echo "ok: no sudo"

# --- entrypoint smoke -------------------------------------------------------
t=devbox-smoke-$$
tmp="$(mktemp -d)"
cleanup() {
  docker rm -f "$t" "$t-r" "$t-s3" >/dev/null 2>&1 || true
  docker volume rm "$t-work" "$t-state" "$t-empty" "$t-rwork" "$t-rstate" >/dev/null 2>&1 || true
  docker network rm "$t" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; docker logs "$t" 2>&1 | tail -20 >&2 || true; exit 1; }

# S3 stub: nothing is saved except a small repo under devbox/restore/work, whose
# object "slow" hangs on its first GET (an interrupted restore). Every write
# succeeds and is then found by HEAD. It prints each request: that is how pushes
# and deletes are seen.
read -r -d '' S3 <<'PY' || true
import hashlib, http.server as h, time, urllib.parse as up
from xml.sax.saxutils import escape
OBJ = {"restore/work/" + k: v for k, v in {
    ".git/HEAD": b"ref: refs/heads/main\n",
    ".git/config": b'[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://github.com/devbox/restore.git\n',
    ".git/refs/heads/.keep": b"", ".git/objects/.keep": b"", "f": b"hi\n", "slow": b"slow\n"}.items()}
SIZES, SLOWED = {}, []
def listing(q):
    p, d = q.get("prefix", [""])[0], q.get("delimiter", [""])[0]
    keys, cps = [], set()
    for k in sorted(OBJ):
        if not k.startswith(p): continue
        r = k[len(p):]
        if d and d in r: cps.add(p + r.split(d)[0] + d)
        else: keys.append(k)
    x = "".join(f'<Contents><Key>{escape(k)}</Key><LastModified>2025-01-01T00:00:00.000Z</LastModified>'
                f'<ETag>"{hashlib.md5(OBJ[k]).hexdigest()}"</ETag><Size>{len(OBJ[k])}</Size></Contents>' for k in keys)
    x += "".join(f"<CommonPrefixes><Prefix>{escape(c)}</Prefix></CommonPrefixes>" for c in sorted(cps))
    return ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            f"<Name>devbox</Name><Prefix>{escape(p)}</Prefix><KeyCount>{len(keys) + len(cps)}</KeyCount>"
            f"<MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>{x}</ListBucketResult>").encode()
class S(h.BaseHTTPRequestHandler):
    def answer(self, code, body=b"", length=None, key=None):
        print(self.command, self.path, flush=True)
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        self.send_response(code)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body) if length is None else length))
        if key in OBJ:
            self.send_header("ETag", f'"{hashlib.md5(OBJ[key]).hexdigest()}"')
            self.send_header("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def key(self):
        u = up.urlsplit(self.path)
        return up.unquote(u.path[len("/devbox/"):]), up.parse_qs(u.query)
    def do_GET(self):
        k, q = self.key()
        if not k: return self.answer(200, listing(q))
        if k not in OBJ: return self.answer(404)
        if k.endswith("/slow") and not SLOWED:
            SLOWED.append(1); print("SLOW", k, flush=True); time.sleep(120)
        self.answer(200, OBJ[k], key=k)
    def do_HEAD(self):
        k, _ = self.key()
        if k in OBJ: return self.answer(200, length=len(OBJ[k]), key=k)
        self.answer(200, length=SIZES[self.path.split("?")[0]]) if self.path.split("?")[0] in SIZES else self.answer(404)
    def do_PUT(self):
        SIZES[self.path.split("?")[0]] = int(self.headers.get("X-Amz-Decoded-Content-Length") or self.headers.get("Content-Length") or 0)
        self.answer(200)
    def do_POST(self): self.answer(200)
    def do_DELETE(self): self.answer(204)
    def log_message(self, *a): pass
h.ThreadingHTTPServer(("", 8333), S).serve_forever()
PY

ssh-keygen -q -t ed25519 -N '' -C smoke -f "$tmp/id"
pub="$(cat "$tmp/id.pub")"
docker network create --internal "$t" >/dev/null
docker run -d --name "$t-s3" --network "$t" --network-alias s3 --entrypoint python3 "$IMG" -c "$S3" >/dev/null

# /work already holds a clone of the session's repo: the entrypoint must neither
# restore nor clone over it (hermetic: no GitHub needed).
repo=https://github.com/devbox/smoke
docker run --rm -v "$t-work:/work" --entrypoint sh "$IMG" \
  -c "git init -q /work && git -C /work remote add origin $repo.git && echo hi > /work/f"

start() { # start <REPO_URL> [docker run args...]: the session as compose runs it
  local url=$1; shift
  docker run "$@" --name "$t" --network "$t" --cap-drop ALL --security-opt no-new-privileges:true \
    -v "$t-work:/work" -v "$t-state:/home/dev/.state" \
    -e SESSION=smoke -e REPO_URL="$url" -e SSH_PUBKEY="$pub" -e S3_SECRET_KEY=x "$IMG"
}
keyscan() { # keyscan [container]: host key served on 2222, or nothing after 60 s
  local k c=${1:-$t}
  for _ in $(seq 30); do
    k="$(docker run --rm --network "$t" --entrypoint ssh-keyscan "$IMG" -T 3 -t ed25519 -p 2222 "$c" 2>/dev/null | grep -v '^#' || true)"
    [ -n "$k" ] && { echo "${k#* }"; return; }
    docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || return 0
    sleep 2
  done
}
client() { # client <cmd...>: run as the dev user in a sibling container with the key
  docker run --rm -i --network "$t" --entrypoint bash "$IMG" -c \
    'umask 077; cat > /tmp/id; "$@"' _ "$@" < "$tmp/id"
}
SSH=(-i /tmp/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

start "$repo" -d >/dev/null
key1="$(keyscan)"; [ -n "$key1" ] || fail "sshd does not answer on 2222"
echo "ok: entrypoint starts sshd on 2222"
grep -q 'not restored' <<<"$(docker logs "$t" 2>&1)" || fail "an intact /work was not left alone"
echo "ok: intact /work left alone"

# shellcheck disable=SC2016 # expanded by the remote shell
out="$(client ssh "${SSH[@]}" -p 2222 "dev@$t" \
  'command -v cargo; echo "$CLAUDE_CONFIG_DIR $GIT_CONFIG_GLOBAL"; echo {} > "$CLAUDE_CONFIG_DIR/.claude.json"; git config --global user.name smoke')" \
  || fail "non-interactive ssh failed"
grep -q '/home/dev/.cargo/bin/cargo' <<<"$out" || fail "cargo not on PATH over ssh: $out"
grep -q '/home/dev/.state/claude /home/dev/.state/gitconfig' <<<"$out" || fail "state env missing over ssh: $out"
echo "ok: ssh dev@session cmd sees cargo and the state dirs"
client sh -c "echo pwd | sftp -b - $(printf '%q ' "${SSH[@]}") -P 2222 dev@$t" >/dev/null \
  || fail "sftp subsystem"
echo "ok: sftp"

docker stop -t 60 "$t" >/dev/null
s3log="$(docker logs "$t-s3" 2>&1)"
grep -q '^PUT /devbox/smoke/work/' <<<"$s3log" || fail "no final push of /work on docker stop"
grep -q '^PUT /devbox/smoke/claude/' <<<"$s3log" || fail "no final push of the Claude state on docker stop"
echo "ok: docker stop pushes /work and the Claude state"

# Recreated container, same volumes: same host key (no known_hosts warning).
docker rm "$t" >/dev/null
start "$repo" -d >/dev/null
key2="$(keyscan)"; [ "$key2" = "$key1" ] || fail "host key changed across recreate"
echo "ok: host key survives a recreate"
[ "$(client ssh "${SSH[@]}" -p 2222 "dev@$t" 'git config --global user.name')" = smoke ] \
  || fail "git identity lost across recreate"
echo "ok: git identity survives a recreate"
# sshd crashing on its own: the entrypoint still pushes before the container stops.
n="$(docker logs "$t-s3" 2>&1 | grep -c '^PUT /devbox/smoke/work/' || true)"
docker exec "$t" pkill -KILL -x sshd # a crash: non-zero status
[ "$(docker wait "$t")" = 1 ] || fail "container did not stop with sshd"
[ "$(docker logs "$t-s3" 2>&1 | grep -c '^PUT /devbox/smoke/work/' || true)" -gt "$n" ] || fail "no push after sshd died"
echo "ok: sshd dying still pushes, then stops the container"
docker rm -f "$t" >/dev/null

# Same volume, another repo (a session deleted and recreated under its name): refuse.
if out="$(start https://github.com/devbox/other --rm 2>&1)"; then fail "started over another repo's /work"; fi
grep -q 'refusing to start' <<<"$out" || { echo "$out" >&2; fail "no clear refusal for a foreign /work"; }
echo "ok: a /work cloned from another repo is refused"

# Empty /work and nothing saved: the entrypoint goes to clone (which fails
# here, there is no Internet), and does not push anything.
if out="$(docker run --rm --network "$t" -v "$t-empty:/work" -e SESSION=smoke2 -e REPO_URL="$repo" \
  -e SSH_PUBKEY="$pub" -e S3_SECRET_KEY=x "$IMG" 2>&1)"; then fail "clone without Internet succeeded?"; fi
grep -q "cloning $repo" <<<"$out" || { echo "$out" >&2; fail "empty prefix did not lead to a clone"; }
grep -q '^PUT /devbox/smoke2/' <<<"$(docker logs "$t-s3" 2>&1)" && fail "a failed clone pushed to S3"
echo "ok: empty /work + empty prefix -> clone, nothing pushed"

# Restore interrupted by `docker stop` (its object "slow" hangs): the container
# stops at once without pushing, keeps its marker, and the next start resumes
# the restore; nothing is pushed or deleted remotely meanwhile.
r=$t-r
docker run -d --name "$r" --network "$t" --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$t-rwork:/work" -v "$t-rstate:/home/dev/.state" -e SESSION=restore \
  -e REPO_URL=https://github.com/devbox/restore -e SSH_PUBKEY="$pub" -e S3_SECRET_KEY=x "$IMG" >/dev/null
for _ in $(seq 60); do
  grep -q '^SLOW restore/work/slow' <<<"$(docker logs "$t-s3" 2>&1)" && break
  sleep 1
done
grep -q '^SLOW restore/work/slow' <<<"$(docker logs "$t-s3" 2>&1)" || fail "restore never reached the slow object"
docker stop -t 30 "$r" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$r")" = 143 ] || fail "stop during restore: exit $(docker inspect -f '{{.State.ExitCode}}' "$r")"
grep -q 'nothing pushed' <<<"$(docker logs "$r" 2>&1)" || fail "no clean early stop"
docker run --rm -v "$t-rstate:/s" --entrypoint ls "$IMG" /s | grep -qx restoring-work || fail "restore marker missing after the interruption"
echo "ok: docker stop mid-restore exits at once and keeps the marker"
docker start "$r" >/dev/null
[ -n "$(keyscan "$r")" ] || { docker logs "$r" >&2; fail "restarted session did not come up"; }
grep -q 'resuming the interrupted restore of /work' <<<"$(docker logs "$r" 2>&1)" || fail "restore not resumed"
[ "$(docker exec "$r" cat /work/slow)" = slow ] || fail "resumed restore incomplete"
[ -z "$(docker exec "$r" sh -c 'ls /home/dev/.state/restoring-* 2>/dev/null' || true)" ] || fail "markers left after the restore"
s3log="$(docker logs "$t-s3" 2>&1)"
grep -q '^DELETE ' <<<"$s3log" && fail "a remote object was deleted"
grep -q '^PUT /devbox/restore/' <<<"$s3log" && fail "something was pushed around the interrupted restore"
echo "ok: the next start resumes the restore, clears the markers, nothing pushed or deleted"
if docker exec "$r" sh -c 'touch /home/dev/.state/restoring-claude && sync.sh push' 2>/dev/null; then
  fail "sync.sh pushed with a restore marker present"
fi
grep -q '^PUT /devbox/restore/' <<<"$(docker logs "$t-s3" 2>&1)" && fail "push with a marker reached S3"
echo "ok: sync.sh refuses to push while a restore marker exists"
echo "all devbox image checks passed"
