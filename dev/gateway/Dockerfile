FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
RUN apk add --no-cache openssh-server \
 && adduser -D -s /bin/false jump \
 && echo 'jump:*' | chpasswd -e \
 && mkdir -p /etc/ssh/hostkeys /etc/ssh/authorized_keys
COPY sshd_config /etc/ssh/sshd_config
# The owner's public key, baked in (gitignored; `make dev-up` checks it first).
# Not a bind mount: from the Mac, DOCKER_HOST is the laptop, and a Mac path
# would arrive there as an empty auto-created directory. The build context does cross.
COPY --chmod=0644 authorized_keys /etc/ssh/authorized_keys/jump
# Host keys live in a volume so the fingerprint survives recreation.
CMD ["sh", "-c", "[ -f /etc/ssh/hostkeys/ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ed25519; exec /usr/sbin/sshd -D -e"]
