FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
RUN apk add --no-cache openssh-server \
 && adduser -D -s /bin/false jump \
 && echo 'jump:*' | chpasswd -e \
 && mkdir -p /etc/ssh/hostkeys
COPY sshd_config /etc/ssh/sshd_config
# Host keys live in a volume so the fingerprint survives recreation.
CMD ["sh", "-c", "[ -f /etc/ssh/hostkeys/ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ed25519; exec /usr/sbin/sshd -D -e"]
