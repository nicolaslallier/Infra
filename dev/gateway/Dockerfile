# SSH jump host for dev sessions: user "jump", key auth, port forwarding to
# <session>:2222 only, no shell. nginx (stream.d/devssh.conf) fronts it.
FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
RUN apk add --no-cache openssh-server \
 && adduser -D -s /sbin/nologin jump \
 # adduser -D leaves the password "!", which sshd reads as a locked account.
 && echo 'jump:*' | chpasswd -e \
 && mkdir -p /etc/ssh/keys && mkdir -m 755 /etc/ssh/authorized_keys
COPY sshd_config /etc/ssh/sshd_config
COPY --chown=root:root --chmod=644 authorized_keys /etc/ssh/authorized_keys/jump
EXPOSE 22
# Host key in a volume, so a rebuild keeps the fingerprint clients trust.
CMD ["sh", "-c", "test -f /etc/ssh/keys/ssh_host_ed25519_key || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/keys/ssh_host_ed25519_key; exec /usr/sbin/sshd -D -e"]
