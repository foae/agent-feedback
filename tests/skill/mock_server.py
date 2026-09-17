#!/usr/bin/env python3
"""Scriptable mock of the agent-feedback service (API 1.1) for hermetic client tests.

Usage: mock_server.py <state_dir>

  <state_dir>/port            written once bound (ephemeral port)
  <state_dir>/mode            read per request: created | duplicate | reject400 |
                              error500 | replay200 | mismatch409 | collision200 |
                              friction_bad_created | friction_wrong_duplicate |
                              review_bad_created | export_no_terminator
                              (missing file -> created)
  <state_dir>/list_rows       how many rows the list/export fixtures hold (default 1)
  <state_dir>/list_page_cap   optional hard cap on the rows returned per list
                              page, so pagination can be exercised with a
                              handful of rows (missing file -> no extra cap)
  <state_dir>/requests.jsonl  one JSON line per request received

Contract notes this mock reproduces:
  * every record carries `family` and `payload_hash`
  * `run_id`, `processed_at` and `resolution` are OMITTED when unset, never null
  * list paging is keyset (`before_id`/`has_more`/`next_before_id`) with `total`
  * events are idempotent on (kind, key): identical replay 200, different 409
  * export is header line + record lines + terminator with count and sha256

Auth: expects the key "testkey" via Authorization: Bearer or X-Api-Key.
"""

import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE = sys.argv[1]
EVENTS = {}
NEXT_EVENT_ID = [500]


def mode():
    try:
        with open(os.path.join(STATE, "mode")) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "created"


def list_rows():
    try:
        with open(os.path.join(STATE, "list_rows")) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 1


def list_page_cap():
    try:
        with open(os.path.join(STATE, "list_page_cap")) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


def summary_row(i):
    return {
        "id": i,
        "family": "friction",
        "submission_type": "friction",
        "machine_name": "testmach",
        "coordinator_model": "m",
        "payload_hash": "hash-%d" % i,
        "created_at": "2026-07-30T00:00:00.000000Z",
        "category": "tooling",
        "summary": "fixture summary %d" % i,
        "project": "proj",
        "harness": "claude-code",
    }


def full_row(i):
    r = summary_row(i)
    for k in ("category", "summary", "project", "harness"):
        r.pop(k)
    r["payload"] = {"category": "tooling", "summary": "fixture summary %d" % i}
    return r


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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

    def _send_raw(self, code, data, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # ── writes ──────────────────────────────────────────────────────────────

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
            self._frictions(m, body)
        elif self.path == "/api/v1/reviews":
            self._reviews(m, body)
        elif self.path == "/api/v1/events":
            self._events(m, body)
        elif self.path == "/api/v1/submissions/processed":
            out = {
                "processed": body.get("processed", True),
                "updated": body.get("ids", []),
                "unchanged": [],
                "not_found": [],
            }
            if "resolution" in body:
                out["resolution"] = body["resolution"]
            self._send(200, out)
        else:
            self._send(404, {"error": "not_found", "message": "no route"})

    def _frictions(self, m, body):
        base = {
            "family": "friction",
            "submission_type": "friction",
            "machine_name": body.get("machine_name"),
            "coordinator_model": body.get("coordinator_model"),
            "payload": body,
            "payload_hash": "hash-friction",
            "created_at": "2026-07-30T00:00:00.000000Z",
        }
        if m == "created":
            self._send(201, dict(base, id=101))
        elif m == "duplicate":
            self._send(200, dict(base, id=55, created_at="2026-07-29T00:00:00.000000Z"))
        elif m == "friction_bad_created":
            self._send(201, dict(base, id="101"))
        elif m == "friction_wrong_duplicate":
            self._send(200, dict(base, id=55, family="review",
                                 submission_type="review-panel"))
        elif m == "reject400":
            self._send(400, {"error": "create_friction_failed",
                             "message": "invalid input: summary exceeds 2000 bytes"})
        else:
            self._send(500, {"error": "internal", "message": "boom"})

    def _reviews(self, m, body):
        echo = {
            "id": 102,
            "family": "review",
            "submission_type": body.get("skill"),
            "machine_name": body.get("machine_name"),
            "coordinator_model": body.get("coordinator_model"),
            "run_id": body.get("run_id"),
            "payload": {"reviewers": body.get("reviewers")},
            "payload_hash": "hash-review",
            "created_at": "2026-07-30T00:00:00.000000Z",
        }
        if m == "created":
            self._send(201, echo)
        elif m == "review_bad_created":
            # A 201 that proves nothing: the id is not a positive integer.
            self._send(201, dict(echo, id="102"))
        elif m == "replay200":
            self._send(200, echo)
        elif m == "mismatch409":
            self._send(409, {"error": "replay_mismatch",
                             "message": "replay mismatch: run_id already stored as submission 7 "
                                        "with different content; submit the correction as a new "
                                        "submission (new run_id)"})
        elif m == "collision200":
            self._send(200, {"id": 9, "family": "review", "submission_type": "review-panel",
                             "run_id": "other-run", "machine_name": "other-machine",
                             "payload_hash": "hash-other"})
        elif m == "reject400":
            self._send(400, {"error": "create_review_failed",
                             "message": "invalid input: machine_name is required"})
        else:
            self._send(500, {"error": "internal", "message": "boom"})

    def _events(self, m, body):
        if m == "reject400":
            self._send(400, {"error": "create_event_failed",
                             "message": "invalid input: kind is required"})
            return
        if m in ("error500", "", None):
            self._send(500, {"error": "internal", "message": "boom"})
            return
        kind, key = body.get("kind"), body.get("key")
        canon = json.dumps({"machine_name": body.get("machine_name"),
                            "coordinator_model": body.get("coordinator_model"),
                            "payload": body.get("payload")}, sort_keys=True)
        digest = hashlib.sha256(canon.encode()).hexdigest()
        rec = {
            "family": "event",
            "submission_type": kind,
            "machine_name": body.get("machine_name"),
            "coordinator_model": body.get("coordinator_model"),
            "run_id": key,
            "payload": body.get("payload"),
            "payload_hash": digest,
            "created_at": "2026-07-30T00:00:00.000000Z",
        }
        prior = EVENTS.get((kind, key))
        if prior is None:
            NEXT_EVENT_ID[0] += 1
            EVENTS[(kind, key)] = (NEXT_EVENT_ID[0], digest)
            self._send(201, dict(rec, id=NEXT_EVENT_ID[0]))
        elif prior[1] == digest:
            self._send(200, dict(rec, id=prior[0]))
        else:
            self._send(409, {"error": "replay_mismatch",
                             "message": "replay mismatch: key already stored as submission %d "
                                        "with different content" % prior[0]})

    # ── reads ───────────────────────────────────────────────────────────────

    def do_GET(self):
        self._record(None)
        parsed = urlparse(self.path)
        if parsed.path in ("/health", "/ready"):
            self._send(200, {})
            return
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized", "message": "missing or invalid API key"})
            return
        if parsed.path == "/api/v1/export":
            self._export(parse_qs(parsed.query))
            return
        if parsed.path.startswith("/api/v1/submissions/"):
            tail = parsed.path.rsplit("/", 1)[1]
            try:
                wanted = int(tail)
            except ValueError:
                self._send(400, {"error": "bad_request", "message": "id must be numeric"})
                return
            self._send(200, full_row(wanted))
        elif parsed.path == "/api/v1/submissions":
            self._list(parse_qs(parsed.query))
        else:
            self._send(404, {"error": "not_found", "message": "no route"})

    def _list(self, q):
        total = list_rows()
        try:
            limit = int(q.get("limit", ["50"])[0])
        except ValueError:
            limit = 50
        if limit <= 0:
            limit = 50
        include_payload = q.get("include", [""])[0] == "payload"
        limit = min(limit, 100 if include_payload else 500)
        cap = list_page_cap()
        if cap > 0:
            limit = min(limit, cap)
        before_id = q.get("before_id", [None])[0]
        if "before_id" in q and "offset" in q:
            self._send(400, {"error": "bad_request",
                             "message": "before_id cannot be combined with offset"})
            return
        try:
            offset = int(q.get("offset", ["0"])[0])
        except ValueError:
            offset = 0
        offset = max(offset, 0)
        ids = list(range(total, 0, -1))
        if before_id is not None:
            try:
                ids = [i for i in ids if i < int(before_id)]
            except ValueError:
                self._send(400, {"error": "bad_request",
                                 "message": "before_id must be a positive integer"})
                return
        elif offset:
            ids = ids[offset:]
        page = ids[:limit]
        has_more = len(ids) > len(page)
        rows = [full_row(i) if include_payload else summary_row(i) for i in page]
        self._send(200, {
            "submissions": rows,
            "limit": limit,
            "offset": offset,
            "total": total,
            "has_more": has_more,
            "next_before_id": page[-1] if (has_more and page) else None,
        })

    def _export(self, q):
        total = list_rows()
        family = q.get("family", [None])[0]
        since = q.get("since", [None])[0]
        header = json.dumps({"export_format": 1, "family": family, "since": since,
                             "exported_at": "2026-07-30T00:00:00.000000Z"})
        records = "".join(json.dumps(full_row(i)) + "\n" for i in range(1, total + 1))
        out = header + "\n" + records
        if mode() != "export_no_terminator":
            digest = hashlib.sha256(records.encode()).hexdigest()
            out += json.dumps({"export_complete": True, "count": total,
                               "sha256": digest}) + "\n"
        self._send_raw(200, out.encode(), "application/x-ndjson")


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
