#!/usr/bin/env python3
"""Fake Dozzle for outage testing — never touches the real server.

  python3 scripts/fixture_server.py --port 9911                 # healthy stream
  python3 scripts/fixture_server.py --port 9911 --stall-after 8 # stream goes silent, socket stays open
  python3 scripts/fixture_server.py --port 9911 --auth          # stream returns 401
  python3 scripts/fixture_server.py --port 9911 --demo          # a fuller, made-up homelab (README screenshots)

Authentication and proxies (combine freely):
  --simple-auth me:pw [--auth-ttl 30]   Dozzle's own login: / redirects to /login, POST /api/token sets jwt
  --oauth-only                          login page offers only GitHub; POST /api/token is 404
  --basic proxy:pw                      a proxy's HTTP basic auth on every path, /healthcheck included
  --require-header 'X-Token: abc'       a proxy that wants this header on every path
  --forward-proxy                       Dozzle in forward-proxy mode: / is 401 without a Remote-User header
  --portal https://sso.example/         a proxy that redirects everything to a sign-in portal
  --tls cert.pem key.pem                HTTPS with that (e.g. self-signed) certificate
  --drop-after 8                        end each event stream after 8 s (exercises reconnects)
Dozzle modes:
  --mode swarm | --mode k8s             the data shapes Dozzle sends in Swarm and Kubernetes mode
  kill the process                                             # simulates Dozzle going down

Point the app at it:  .build/debug/DozzleDesk --url http://127.0.0.1:9911 --grace 20 --stall 6
"""
import argparse
import base64
import json
import random
import secrets
import ssl
import time
from urllib.parse import parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOSTS = [
    {"name": "fixture-a", "id": "HA", "nCPU": 4, "memTotal": 8e9, "diskTotal": 5e11, "diskFree": 3e11,
     "type": "local", "available": True},
    {"name": "fixture-b", "id": "HB", "nCPU": 2, "memTotal": 4e9, "diskTotal": 2e11, "diskFree": 1e11,
     "type": "agent", "available": True},
]
CONTAINERS = [
    {"id": f"{i:012x}", "name": name, "state": "running", "health": health, "host": host,
     "startedAt": "2026-11-07T10:00:00.123456789Z",
     "stats": {"cpu": [1.0], "memory": [2.0], "memoryUsage": [mem]}}
    for i, (name, host, health, mem) in enumerate([
        ("web", "HA", "healthy", 2.5e8), ("db", "HA", "healthy", 6e8),
        ("worker", "HB", None, 1.2e8), ("cache", "HB", "unhealthy", 5e7)], start=1)
]

# --demo: a made-up but typical homelab, with one unhealthy and one restarting container.
DEMO_HOSTS = [
    {"name": "nas", "id": "H1", "nCPU": 8, "memTotal": 32e9, "diskTotal": 8e12, "diskFree": 3.1e12,
     "type": "local", "available": True},
    {"name": "pi", "id": "H2", "nCPU": 4, "memTotal": 8e9, "diskTotal": 2.56e11, "diskFree": 1.7e11,
     "type": "agent", "available": True},
    {"name": "edge", "id": "H3", "nCPU": 2, "memTotal": 4e9, "diskTotal": 6.4e10, "diskFree": 4.1e10,
     "type": "agent", "available": True},
]
DEMO_SPEC = [  # name, host, health, memory bytes, typical cpu %, state
    ("jellyfin", "H1", "healthy", 1.8e9, 22, "running"), ("immich-server", "H1", "healthy", 1.2e9, 9, "running"),
    ("immich-ml", "H1", "unhealthy", 9e8, 31, "running"), ("postgres", "H1", "healthy", 6e8, 5, "running"),
    ("redis", "H1", None, 6e7, 1, "running"), ("paperless", "H1", "healthy", 7e8, 4, "running"),
    ("nextcloud", "H1", None, 5e8, 6, "running"), ("grafana", "H1", None, 1.8e8, 2, "running"),
    ("prometheus", "H1", "healthy", 4.5e8, 7, "running"), ("homeassistant", "H2", "healthy", 4.5e8, 12, "running"),
    ("pihole", "H2", "healthy", 9e7, 3, "running"), ("mosquitto", "H2", None, 1.5e7, 1, "running"),
    ("zigbee2mqtt", "H2", None, 1.1e8, 4, "running"), ("uptime-kuma", "H2", "healthy", 1.2e8, 3, "running"),
    ("traefik", "H3", "healthy", 7e7, 4, "running"), ("vaultwarden", "H3", "healthy", 4e7, 1, "running"),
    ("cloudflared", "H3", None, 3e7, 2, "running"), ("wireguard", "H3", None, 2e7, 0, "exited"),
]
DEMO_CONTAINERS = [
    {"id": f"d{i:011x}", "name": name, "state": state, "health": health, "host": host,
     "startedAt": "2026-11-01T08:00:00.000000000Z",
     "stats": {"cpu": [float(cpu)], "memory": [2.0], "memoryUsage": [mem]}, "_cpu": cpu}
    for i, (name, host, health, mem, cpu, state) in enumerate(DEMO_SPEC, start=1)
]

# --mode k8s: hosts are nodes (id = node name); containers are pod containers ("ns:pod:container").
K8S_HOSTS = [
    {"name": "node-1", "id": "node-1", "nCPU": 4, "memTotal": 16e9, "type": "k8s", "available": True},
    {"name": "node-2", "id": "node-2", "nCPU": 4, "memTotal": 16e9, "type": "k8s", "available": True},
]
K8S_CONTAINERS = [
    {"id": cid, "name": name, "state": state, "host": host, "group": cid.split(":")[0],
     "startedAt": "2026-11-01T08:00:00.000000000Z", "stats": {"cpu": [2.0], "memory": [1.0], "memoryUsage": [mem]}}
    for cid, name, state, host, mem in [
        ("kube-system:coredns-5d78c9869d-abcde:coredns", "coredns", "running", "node-1", 4e7),
        ("kube-system:coredns-5d78c9869d-fghij:coredns", "coredns", "running", "node-2", 4e7),
        ("kube-system:metrics-server-7f8d6b-xyz12:metrics-server", "metrics-server", "running", "node-1", 6e7),
        ("apps:web-6c9f7d-qwert:web", "web", "running", "node-2", 2.5e8),
        ("apps:worker-58b4c-asdfg:worker", "worker", "restarting", "node-1", 9e7),
        ("apps:migrate-29w8x:migrate", "migrate", "exited", "node-2", 0),
    ]
]
# --mode swarm: Swarm nodes reached through Dozzle's agents; task containers carry stack labels.
SWARM_HOSTS = [
    {"name": "manager-1", "id": "N1", "nCPU": 4, "memTotal": 8e9, "type": "swarm", "available": True},
    {"name": "worker-1", "id": "N2", "nCPU": 2, "memTotal": 4e9, "type": "swarm", "available": True},
]
SWARM_CONTAINERS = [
    {"id": f"{i:012x}", "name": name, "state": "running", "health": health, "host": host,
     "labels": {"com.docker.stack.namespace": "media", "com.docker.swarm.service.name": name.split(".")[0]},
     "startedAt": "2026-11-01T08:00:00.000000000Z", "stats": {"cpu": [3.0], "memory": [2.0], "memoryUsage": [mem]}}
    for i, (name, host, health, mem) in enumerate([
        ("media_jellyfin.1.k2j4h5g6f7d8", "N1", "healthy", 1.5e9), ("media_sonarr.1.a1s2d3f4g5h6", "N2", None, 3e8),
        ("media_radarr.1.q1w2e3r4t5y6", "N2", "unhealthy", 3.2e8)], start=0x51)
]


def rfc3339(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def make_handler(args):
    if args.mode == "k8s":
        hosts, containers = K8S_HOSTS, K8S_CONTAINERS
    elif args.mode == "swarm":
        hosts, containers = SWARM_HOSTS, SWARM_CONTAINERS
    else:
        hosts = DEMO_HOSTS if args.demo else HOSTS
        containers = DEMO_CONTAINERS if args.demo else CONTAINERS
    mem_total = {h["id"]: h["memTotal"] for h in hosts}
    version = "demo" if args.demo else "v0-fixture"
    auth_provider = "simple" if (args.simple_auth or args.oauth_only) else ("forward-proxy" if args.forward_proxy else "none")
    sessions = {}  # jwt -> expiry (0 = no expiry)

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            print("fixture:", fmt % a, flush=True)

        def send_plain(self, code, body=b"", ctype="text/plain", headers=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def page(self, cfg):
            html = f'<html><head><script type="application/json" id="config__json">{json.dumps(cfg)}</script></head></html>'
            self.send_plain(200, html.encode(), "text/html")

        # What a reverse proxy in front of Dozzle would check, on every path.
        def proxy_blocks(self):
            if args.portal:
                self.send_plain(302, headers={"Location": args.portal})
                return True
            if args.basic:
                want = "Basic " + base64.b64encode(args.basic.encode()).decode()
                if self.headers.get("Authorization") != want:
                    self.send_plain(401, b"proxy login required", headers={"WWW-Authenticate": 'Basic realm="proxy"'})
                    return True
            if args.require_header:
                name, _, value = args.require_header.partition(":")
                if self.headers.get(name.strip()) != value.strip():
                    self.send_plain(401, b"missing header")
                    return True
            return False

        def signed_in(self):
            if not (args.simple_auth or args.oauth_only):
                return True
            cookies = dict(c.strip().split("=", 1) for c in (self.headers.get("Cookie") or "").split(";") if "=" in c)
            exp = sessions.get(cookies.get("jwt"))
            return exp is not None and (exp == 0 or time.time() < exp)

        def do_POST(self):
            if self.proxy_blocks():
                return
            if self.path == "/api/token" and args.simple_auth:
                length = int(self.headers.get("Content-Length") or 0)
                form = parse_qs(self.rfile.read(length).decode())
                user, _, pw = args.simple_auth.partition(":")
                if form.get("username") == [user] and form.get("password") == [pw]:
                    token = secrets.token_hex(16)
                    sessions[token] = time.time() + args.auth_ttl if args.auth_ttl else 0
                    print(f"fixture: login ok, session for {args.auth_ttl or 'ever'} s", flush=True)
                    return self.send_plain(200, b"OK", headers={"Set-Cookie": f"jwt={token}; Path=/; HttpOnly"})
                print("fixture: login rejected", flush=True)
                return self.send_plain(401, b"invalid credentials")
            self.send_plain(404 if self.path == "/api/token" else 405)

        def do_GET(self):
            if self.proxy_blocks():
                return
            path = self.path.split("?", 1)[0]
            if path == "/healthcheck":
                return self.send_plain(200)
            if path in ("/", "/login"):
                if args.forward_proxy and not self.headers.get("Remote-User"):
                    return self.send_plain(401, b"Unauthorized user\n")
                if not self.signed_in():
                    if path == "/":
                        return self.send_plain(307, headers={"Location": "/login?redirectUrl=%2F"})
                    providers = [{"name": "GitHub", "loginUrl": "/api/auth/github", "icon": "github"}] if args.oauth_only else []
                    return self.page({"base": "", "passwordLogin": not args.oauth_only, "oauthProviders": providers})
                if path == "/login":
                    return self.send_plain(307, headers={"Location": "/"})
                return self.page({"version": version, "authProvider": auth_provider, "mode": args.mode, "hosts": hosts})
            if self.path.startswith("/api/events/stream"):
                if args.auth or not self.signed_in():
                    return self.send_plain(401, b"unauthorized")
                return self.stream()
            self.send_plain(404)

        def emit(self, event, data):
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        def stream(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(b"retry: 3000\n\n")
            self.emit("server-version", {"version": version})
            self.emit("containers-changed", [{k: v for k, v in c.items() if k != "_cpu"} for c in containers])
            if args.demo:  # nextcloud died and came back twice in the last few minutes
                nc = next(c for c in containers if c["name"] == "nextcloud")
                for ago in (300, 120):
                    for action, dt in (("die", 0), ("start", 5)):
                        self.emit("container-event", {"name": action, "host": nc["host"], "actorId": nc["id"],
                                                      "time": rfc3339(time.time() - ago + dt)})
            start = time.time()
            n = 0
            try:
                while True:
                    if args.stall_after and time.time() - start > args.stall_after:
                        print("fixture: stalling (socket held open, no bytes)", flush=True)
                        time.sleep(3600)
                    if args.drop_after and time.time() - start > args.drop_after:
                        print("fixture: ending the stream", flush=True)
                        return
                    for c in containers:
                        if c["state"] != "running":
                            continue
                        mem = c["stats"]["memoryUsage"][0]
                        if args.demo:  # a gentle wander around each container's typical load
                            base = c["_cpu"]
                            cpu = max(0.1, base + random.uniform(-0.3, 0.3) * base + random.uniform(-0.5, 0.5))
                            pct = mem / mem_total[c["host"]] * 100
                        else:
                            cpu, pct = random.uniform(0, 60), 3.0
                        self.emit("container-stat", {"id": c["id"], "cpu": round(cpu, 2),
                                                     "memory": round(pct, 2), "memoryUsage": mem})
                    # Kubernetes nodes have no Docker host metrics, so Dozzle sends none.
                    if n % 10 == 0:
                        if args.mode != "k8s":
                            for h in hosts:
                                self.emit("host-metrics", {"id": h["id"], "metricsAvailable": True,
                                                           "load1": round(random.uniform(0.1, 0.25) * h["nCPU"], 2),
                                                           "diskFree": h.get("diskFree", 1e11),
                                                           "diskTotal": h.get("diskTotal", 2e11)})
                        self.emit("ping", {})
                    n += 1
                    time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                print("fixture: client disconnected", flush=True)

    return H


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9911)
    p.add_argument("--stall-after", type=float, default=0)
    p.add_argument("--drop-after", type=float, default=0)
    p.add_argument("--auth", action="store_true", help="event stream always answers 401")
    p.add_argument("--demo", action="store_true")
    p.add_argument("--mode", choices=["server", "swarm", "k8s"], default="server")
    p.add_argument("--simple-auth", metavar="USER:PASS")
    p.add_argument("--auth-ttl", type=float, default=0)
    p.add_argument("--oauth-only", action="store_true")
    p.add_argument("--basic", metavar="USER:PASS")
    p.add_argument("--require-header", metavar="'NAME: VALUE'")
    p.add_argument("--forward-proxy", action="store_true")
    p.add_argument("--portal", metavar="URL")
    p.add_argument("--tls", nargs=2, metavar=("CERT", "KEY"))
    args = p.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args))
    srv.daemon_threads = True
    scheme = "http"
    if args.tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(*args.tls)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = "https"
    print(f"fixture: listening on {scheme}://127.0.0.1:{args.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
