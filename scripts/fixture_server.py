#!/usr/bin/env python3
"""Fake Dozzle for outage testing — never touches the real server.

  python3 scripts/fixture_server.py --port 9911                 # healthy stream
  python3 scripts/fixture_server.py --port 9911 --stall-after 8 # stream goes silent, socket stays open
  python3 scripts/fixture_server.py --port 9911 --auth          # stream returns 401
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


def make_handler(args):
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
                cfg = {"version": "v0-fixture", "authProvider": "none", "hosts": HOSTS}
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
            self.emit("server-version", {"version": "v0-fixture"})
            self.emit("containers-changed", CONTAINERS)
            start = time.time()
            n = 0
            try:
                while True:
                    if args.stall_after and time.time() - start > args.stall_after:
                        print("fixture: stalling (socket held open, no bytes)", flush=True)
                        time.sleep(3600)
                    for c in CONTAINERS:
                        self.emit("container-stat", {"id": c["id"], "cpu": round(random.uniform(0, 60), 2),
                                                     "memory": 3.0, "memoryUsage": c["stats"]["memoryUsage"][0]})
                    if n % 10 == 0:
                        for h in HOSTS:
                            self.emit("host-metrics", {"id": h["id"], "metricsAvailable": True,
                                                       "load1": round(random.uniform(0.1, 2), 2),
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
