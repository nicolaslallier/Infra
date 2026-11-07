# squid.conf baked in: a bind mount would resolve on the machine running make, not on DOCKER_HOST's.
FROM ubuntu/squid:6.6-24.04_edge@sha256:8a3baed477e2c282ab8aa5edad442f69873246964f225c5c2ae8364b6610963c
COPY squid.conf /etc/squid/squid.conf
