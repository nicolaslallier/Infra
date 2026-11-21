"""Tests for the Portail vhost: security headers, closed internal routes, long-lived streams. Stdlib only.

Run: python3 scripts/test_portail_vhost.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF = open(os.path.join(ROOT, "nginx", "conf.d", "portail.conf")).read()
SERVER_LEVEL = CONF[:CONF.index("\n    location")]


def locations():
    return re.findall(r"location\s+([^{]+?)\s*\{(.*?)\n    \}", CONF, re.S)


def test_security_headers_are_set_once_at_server_level():
    for h in ("Content-Security-Policy", "X-Content-Type-Options nosniff", "Referrer-Policy no-referrer",
              "X-Trace-Id $otel_trace_id"):
        assert re.search(rf"add_header {re.escape(h)}.* always;", SERVER_LEVEL), h
    assert "img-src 'self' data:;" in SERVER_LEVEL and "frame-ancestors 'none'" in SERVER_LEVEL
    for loc, body in locations():  # an add_header in a location would drop the server-level ones
        assert "add_header" not in body, loc


def test_metrics_and_interne_are_404_before_the_catch_all():
    for p in ("/metrics", "/interne"):
        m = re.search(rf"location \^~ {p} \{{\s*return 404;\s*\}}", CONF)
        assert m and m.start() < CONF.index("location / {"), p


def test_streams_are_unbuffered_for_an_hour_and_authenticated():
    body = dict(locations())[r"~ ^/api/(evenements|conversations/[0-9]+/flux)$"]
    for d in ("auth_request /oauth2/auth;", "proxy_buffering off;", "proxy_read_timeout 1h;",
              "proxy_set_header X-Auth-Request-Email $email;"):
        assert d in body, d
    pattern = r"^/api/(evenements|conversations/[0-9]+/flux)$"
    for ok in ("/api/evenements", "/api/conversations/12/flux"):
        assert re.match(pattern, ok), ok
    for no in ("/api/evenementsx", "/api/conversations/x/flux", "/api/conversations/1/flux/x"):
        assert not re.match(pattern, no), no


def test_every_proxied_location_is_authenticated():
    for loc, body in locations():
        if "set $upstream http://portail" in body:
            assert "auth_request /oauth2/auth;" in body, loc


def test_oauth2_stays_on_the_infra_container():
    assert "192.168.2.68" not in CONF and CONF.count("http://oauth2-proxy-portail:4180;") == 2


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
