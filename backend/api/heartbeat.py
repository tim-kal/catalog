"""POST /api/heartbeat — Record a heartbeat from a registered device."""

from http.server import BaseHTTPRequestHandler
import json


class handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}
        except (json.JSONDecodeError, ValueError):
            self._json_response(400, {"error": "Invalid JSON body"})
            return

        device_id = body.get("device_id")
        if not device_id:
            self._json_response(400, {"error": "device_id is required"})
            return

        self._json_response(200, {
            "status": "ok",
            "device_id": device_id,
        })

    def _json_response(self, status_code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass
