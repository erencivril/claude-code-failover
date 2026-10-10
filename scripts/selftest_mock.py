"""Local stand-in for the model API, used only by selftest.sh.

Listens on a free localhost port (written to the file given as argv[1]) and
answers every request with a policy-style error, appending one line per
request to argv[2]. No request ever leaves the machine.
"""
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, hits_file = sys.argv[1], sys.argv[2]
BODY = json.dumps({
    "type": "error",
    "error": {
        "type": "invalid_request_error",
        "message": "Self-test: unable to respond to this request, which appears to violate our Usage Policy.",
    },
}).encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        with open(hits_file, "a") as f:
            f.write(self.path + "\n")
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)


class Server(HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind looks up the host's FQDN, a reverse DNS query that
        # can hang for a long time on some machines. Nothing here needs the name.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


server = Server(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
