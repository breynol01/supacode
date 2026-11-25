"""Fake sign-in site for the bridge harness.

/login  sets `harness_session` (persistent, HttpOnly) and redirects to /home after a second.
/home   the signed-in page.
/whoami echoes the Cookie header the client sent.
"""

import http.server
import sys
import uuid


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/login"):
            body = b'<!doctype html><title>login</title><meta http-equiv="refresh" content="1;url=/home">signing in'
            self.send_response(200)
            self.send_header(
                "Set-Cookie",
                f"harness_session={uuid.uuid4().hex}; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax",
            )
        elif self.path.startswith("/whoami"):
            body = ("cookies:" + self.headers.get("Cookie", "")).encode()
            self.send_response(200)
        else:
            body = b"<!doctype html><title>home</title>signed in"
            self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
