#!/usr/bin/env python3
"""Fake Dozzle for outage testing — never touches the real server.

  python3 scripts/fixture_server.py --port 9911                 # healthy stream
  python3 scripts/fixture_server.py --port 9911 --stall-after 8 # stream goes silent, socket stays open
  python3 scripts/fixture_server.py --port 9911 --auth          # stream returns 401
  python3 scripts/fixture_server.py --port 9911 --demo          # a fuller, made-up homelab (README screenshots)
  kill the process                                             # simulates Dozzle going down

Point the app at it:  .build/debug/DozzleDesk --url http://127.0.0.1:9911 --grace 20 --stall 6
"""
import argparse
import json
import random
import time
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


def rfc3339(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def make_handler(args):
    hosts = DEMO_HOSTS if args.demo else HOSTS
    containers = DEMO_CONTAINERS if args.demo else CONTAINERS
    mem_total = {h["id"]: h["memTotal"] for h in hosts}

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            print("fixture:", fmt % a, flush=True)

        def send_plain(self, code, body=b"", ctype="text/plain"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/healthcheck":
                return self.send_plain(200)
            if self.path == "/":
                version = "demo" if args.demo else "v0-fixture"
                cfg = {"version": version, "authProvider": "none", "hosts": hosts}
                html = f'<html><head><script type="application/json" id="config__json">{json.dumps(cfg)}</script></head></html>'
                return self.send_plain(200, html.encode(), "text/html")
            if self.path.startswith("/api/events/stream"):
                if args.auth:
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
            self.emit("server-version", {"version": "demo" if args.demo else "v0-fixture"})
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
                    if n % 10 == 0:
                        for h in hosts:
                            self.emit("host-metrics", {"id": h["id"], "metricsAvailable": True,
                                                       "load1": round(random.uniform(0.1, 0.25) * h["nCPU"], 2),
                                                       "diskFree": h["diskFree"], "diskTotal": h["diskTotal"]})
                        self.emit("ping", {})
                    n += 1
                    time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError):
                print("fixture: client disconnected", flush=True)

    return H


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9911)
    p.add_argument("--stall-after", type=float, default=0)
    p.add_argument("--auth", action="store_true")
    p.add_argument("--demo", action="store_true")
    args = p.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args))
    srv.daemon_threads = True
    print(f"fixture: listening on 127.0.0.1:{args.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
