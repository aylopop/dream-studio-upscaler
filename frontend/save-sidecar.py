#!/usr/bin/env python3
"""
Dream Studio Upscaler — config-save sidecar.

A 60-line HTTP server (stdlib only, no pip) that handles writes for the
two UI-editable JSON files on the NAS:

    /srv/config/config.json     ← site defaults (sliders, model_preferred, …)
    /srv/config/styles.json     ← saved prompt styles

For every write it snapshots the prior version into

    /srv/config/backups/<stem>-<YYYYmmdd-HHMMSS>.json

…then atomically replaces the live file (write-temp + rename). Read paths
go through nginx directly; this server is write-only.

Endpoints:
    PUT  /save/config.json   body = JSON object
    PUT  /save/styles.json   body = JSON array
    (every other path returns 404)

The sidecar deliberately stays stdlib so the container image is whatever
plain python:3-alpine ships — no pip install during pod startup.
"""
import http.server
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

CONFIG_DIR = Path("/srv/config")
BACKUPS = CONFIG_DIR / "backups"
ALLOWED = {"config.json", "styles.json"}
PORT = 8081
MAX_BODY = 2 * 1024 * 1024  # 2 MB; config + styles never come close


def _log(msg: str) -> None:
    print(f"[save] {msg}", flush=True, file=sys.stderr)


class Handler(http.server.BaseHTTPRequestHandler):
    # Don't echo every request to stderr — we log meaningful events ourselves.
    def log_message(self, *a, **kw):
        pass

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self) -> None:
        # Path shape: /save/<filename>
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "save":
            return self._json(404, {"ok": False, "error": "not found"})
        name = parts[1]
        if name not in ALLOWED:
            return self._json(403, {"ok": False, "error": f"only {sorted(ALLOWED)} allowed"})

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._json(413, {"ok": False, "error": "empty or oversize body"})
        body = self.rfile.read(length)
        try:
            json.loads(body)
        except Exception as e:
            return self._json(400, {"ok": False, "error": f"invalid json: {e}"})

        target = CONFIG_DIR / name
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            BACKUPS.mkdir(parents=True, exist_ok=True)
            if target.exists():
                ts = datetime.now().strftime("%Y%m%d-%H%M%S")
                backup = BACKUPS / f"{target.stem}-{ts}{target.suffix}"
                shutil.copy2(target, backup)
                _log(f"backed up {target.name} -> {backup.name}")
            tmp = target.with_suffix(target.suffix + ".tmp")
            tmp.write_bytes(body)
            tmp.replace(target)
            _log(f"wrote {target.name} ({len(body)} bytes)")
        except OSError as e:
            return self._json(500, {"ok": False, "error": f"io: {e}"})
        return self._json(200, {"ok": True, "wrote": name, "bytes": len(body)})

    def do_GET(self) -> None:
        # Health check only — actual config reads come through nginx.
        if self.path == "/healthz":
            return self._json(200, {"ok": True})
        return self._json(404, {"ok": False, "error": "not found"})


def main() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    BACKUPS.mkdir(parents=True, exist_ok=True)
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    _log(f"listening on :{PORT}, writing to {CONFIG_DIR}, backups to {BACKUPS}")
    server.serve_forever()


if __name__ == "__main__":
    main()
