# The dev sessions' only way out: squid with a domain allow-list (squid.conf).
FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
RUN apk add --no-cache squid
COPY squid.conf /etc/squid/squid.conf
EXPOSE 3128
# Unprivileged from the start: squid started as root drops to "squid" and can
# then no longer write the stdout/stderr it logs to.
USER squid
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
