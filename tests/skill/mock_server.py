#!/usr/bin/env python3
"""Scriptable mock of the agent-feedback service for hermetic client tests.

Usage: mock_server.py <state_dir>

  <state_dir>/port            written once bound (ephemeral port)
  <state_dir>/mode            read per request: created | duplicate | reject400 |
                              error500 | replay200 | mismatch409 | collision200 |
                              friction_bad_created | friction_wrong_duplicate
                              (missing file -> created)
  <state_dir>/requests.jsonl  one JSON line per request received

Auth: expects the key "testkey" via Authorization: Bearer or X-Api-Key.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[1]


def mode():
    try:
        with open(os.path.join(STATE, "mode")) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "created"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 — base class signature
        pass

    def _auth_ok(self):
        return (
            self.headers.get("Authorization") == "Bearer testkey"
            or self.headers.get("X-Api-Key") == "testkey"
        )

    def _record(self, body):
        entry = {
            "method": self.command,
            "path": self.path,
            "auth": bool(self._auth_ok()),
            "body": body,
        }
        with open(os.path.join(STATE, "requests.jsonl"), "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        self._record(body)
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized", "message": "missing or invalid API key"})
            return
        if not isinstance(body, dict):
            body = {}
        m = mode()
        if self.path == "/api/v1/frictions":
            if m == "created":
                self._send(201, {
                    "id": 101, "submission_type": "friction",
                    "machine_name": body.get("machine_name"),
                    "coordinator_model": body.get("coordinator_model"),
                    "payload": body, "created_at": "2026-07-30T00:00:00Z",
                })
            elif m == "duplicate":
                self._send(200, {
                    "id": 55, "submission_type": "friction",
                    "machine_name": body.get("machine_name"),
                    "payload": body, "created_at": "2026-07-29T00:00:00Z",
                })
            elif m == "friction_bad_created":
                self._send(201, {
                    "id": "101", "submission_type": "friction",
                    "machine_name": body.get("machine_name"), "payload": body,
                })
            elif m == "friction_wrong_duplicate":
                self._send(200, {
                    "id": 55, "submission_type": "multi-llm-review",
                    "machine_name": body.get("machine_name"), "payload": body,
                })
            elif m == "reject400":
                self._send(400, {"error": "create_friction_failed",
                                 "message": "invalid input: summary exceeds 2000 bytes"})
            else:
                self._send(500, {"error": "internal", "message": "boom"})
        elif self.path == "/api/v1/reviews":
            echo = {
                "id": 102, "submission_type": body.get("skill"),
                "machine_name": body.get("machine_name"),
                "coordinator_model": body.get("coordinator_model"),
                "run_id": body.get("run_id"),
                "payload": {"reviewers": body.get("reviewers")},
                "created_at": "2026-07-30T00:00:00Z",
            }
            if m == "created":
                self._send(201, echo)
            elif m == "replay200":
                self._send(200, echo)
            elif m == "mismatch409":
                self._send(409, {"error": "replay_mismatch",
                                 "message": "replay mismatch: run_id already stored as submission 7 "
                                            "with different content; submit the correction as a new "
                                            "submission (new run_id)"})
            elif m == "collision200":
                self._send(200, {"id": 9, "run_id": "other-run", "machine_name": "other-machine"})
            elif m == "reject400":
                self._send(400, {"error": "create_review_failed",
                                 "message": "invalid input: machine_name is required"})
            else:
                self._send(500, {"error": "internal", "message": "boom"})
        elif self.path == "/api/v1/submissions/processed":
            self._send(200, {
                "processed": body.get("processed", True),
                "updated": body.get("ids", []),
                "unchanged": [], "not_found": [],
            })
        else:
            self._send(404, {"error": "not_found", "message": "no route"})

    def do_GET(self):
        self._record(None)
        if self.path in ("/health", "/ready"):
            self._send(200, {})
            return
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized", "message": "missing or invalid API key"})
            return
        if self.path.startswith("/api/v1/submissions/"):
            self._send(200, {
                "id": 43, "submission_type": "friction", "machine_name": "testmach",
                "coordinator_model": "m",
                "payload": {"category": "tooling", "summary": "s"},
                "created_at": "2026-07-30T00:00:00Z",
            })
        elif self.path.startswith("/api/v1/submissions"):
            self._send(200, {
                "submissions": [{
                    "id": 43, "submission_type": "friction", "machine_name": "testmach",
                    "coordinator_model": "m", "created_at": "2026-07-30T00:00:00Z",
                    "category": "tooling", "summary": "fixture summary",
                    "project": "proj", "harness": "claude-code",
                }],
                "limit": 50, "offset": 0,
            })
        else:
            self._send(404, {"error": "not_found", "message": "no route"})


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
