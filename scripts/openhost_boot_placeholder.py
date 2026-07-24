#!/usr/bin/env python3
"""Minimal boot-time HTTP placeholder for the OpenHost app port.

The OpenHost router marks an app 'error' if nothing answers HTTP within its
readiness window (60s), and first boot (workspace seed + agent create) can
take longer. The entrypoint starts this server on the system_interface port
immediately; it answers 200 with a self-refreshing "starting" page until
scripts/openhost_stop_placeholder.sh kills it right before system_interface
binds the port (see supervisord.conf).
"""

import os
import sys
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer

PID_FILE = "/var/run/openhost-boot-placeholder.pid"

# Set on every placeholder response so the page below can tell "still the
# placeholder" from "system_interface has taken over".
MARKER_HEADER = "X-Openhost-Boot-Placeholder"

# The page polls rather than using <meta http-equiv="refresh">: nothing listens
# on the port between this server exiting and system_interface binding it
# (forward_port.py, then a Flask app that starts `mngr observe` before it
# listens -- seconds, not milliseconds), and a navigation that lands in that
# window gets the router's bare 502, which never retries. Polling keeps the
# browser on this page and reloads only once the real UI answers.
PAGE = b"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Starting...</title>
    <style>
      body { font-family: system-ui, sans-serif; display: flex; align-items: center;
             justify-content: center; height: 100vh; margin: 0; color: #444; }
      div { text-align: center; }
    </style>
  </head>
  <body><div><h1>Your mind is starting&hellip;</h1>
  <p>First boot can take a couple of minutes. This page loads automatically when it is ready.</p>
  </div>
  <script>
    const MARKER = "x-openhost-boot-placeholder";
    async function poll() {
      try {
        const response = await fetch(location.href, { cache: "no-store" });
        if (response.ok && !response.headers.has(MARKER)) {
          location.reload();
          return;
        }
      } catch (e) {
        // Port is mid-handover; fall through and retry.
      }
      setTimeout(poll, 1000);
    }
    setTimeout(poll, 1000);
  </script>
  </body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.send_header(MARKER_HEADER, "1")
        # Without this the post-handover reload can be served this page from cache.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(PAGE)

    do_HEAD = do_GET

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    host = os.environ.get("SYSTEM_INTERFACE_HOST", "0.0.0.0")
    port = int(os.environ.get("SYSTEM_INTERFACE_PORT", "8000"))
    server = ThreadingHTTPServer((host, port), Handler)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"openhost-boot-placeholder: not serving: {e}", file=sys.stderr)
