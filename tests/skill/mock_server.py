#!/usr/bin/env python3
"""Scriptable mock of the agent-feedback service (API 1.1) for hermetic client tests.

Usage: mock_server.py <state_dir>

  <state_dir>/port            written once bound (ephemeral port)
  <state_dir>/mode            read per request: created | duplicate | reject400 |
                              error500 | replay200 | mismatch409 | collision200 |
                              friction_bad_created | friction_wrong_duplicate |
                              review_bad_created | review_wrong_type |
                              review_unparseable | event_bad_created |
                              event_unparseable | event_collision |
                              event_bad_id_foreign_key | event_two_docs |
                              pagination_bad | list_bad_shape |
                              processed_bad | processed_foreign_ids |
                              redirect |
                              export_no_terminator | export_bad_header |
                              export_filtered_header |
                              export_http_500 | export_empty
                              (missing file -> created)
  <state_dir>/list_rows       how many rows the list/export fixtures hold (default 1)
  <state_dir>/list_page_cap   optional hard cap on the rows returned per list
                              page, so pagination can be exercised with a
                              handful of rows (missing file -> no extra cap)
  <state_dir>/requests.jsonl  one JSON line per request received; each entry
                              carries both the parsed `body` and the exact
                              request bytes as `raw` (so byte-for-byte payload
                              forwarding can be asserted)

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
# Submissions the processed endpoint knows about, and their current mark.
KNOWN_IDS = set(range(1, 2001)) | {43, 44}
MARKED = {}


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

    def _record(self, body, raw=None):
        entry = {
            "method": self.command,
            "path": self.path,
            "auth": bool(self._auth_ok()),
            "body": body,
            "raw": raw,
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
        raw_bytes = self.rfile.read(n) if n else b""
        raw = raw_bytes.decode("utf-8", "replace")
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        self._record(body, raw)
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized", "message": "missing or invalid API key"})
            return
        if not isinstance(body, dict):
            body = {}
        m = mode()
        if m == "redirect":
            # A misconfigured URL answering with a redirect: the client must
            # reject it, never spool it for 30 days of retries.
            data = json.dumps({"error": "moved", "message": "see other"}).encode()
            self.send_response(302)
            self.send_header("Location", "https://example.invalid/api/v1")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/api/v1/frictions":
            self._frictions(m, body)
        elif self.path == "/api/v1/reviews":
            self._reviews(m, body)
        elif self.path == "/api/v1/events":
            self._events(m, body)
        elif self.path == "/api/v1/submissions/processed":
            if m == "processed_foreign_ids":
                # A 200 in the right shape that classifies a submission nobody
                # asked about: the mark it reports is not the mark performed.
                self._send(200, {"processed": bool(body.get("processed", True)),
                                 "updated": [999999], "unchanged": [], "not_found": []})
                return
            if m == "processed_bad":
                # A 200 that is not the documented classification shape.
                self._send(200, {"ok": True})
                return
            want = bool(body.get("processed", True))
            updated, unchanged, not_found = [], [], []
            for i in body.get("ids", []):
                if i not in KNOWN_IDS:
                    not_found.append(i)
                elif MARKED.get(i, False) == want:
                    unchanged.append(i)
                else:
                    MARKED[i] = want
                    updated.append(i)
            out = {
                "processed": want,
                "updated": updated,
                "unchanged": unchanged,
                "not_found": not_found,
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
        elif m == "review_wrong_type":
            # Right run, right family, but the record is filed under another
            # skill: the receipt does not prove OUR submission was stored.
            self._send(201, dict(echo, submission_type="some-other-skill"))
        elif m == "review_unparseable":
            self._send_raw(201, b"not json at all", "application/json")
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
                             "coordinator_model": "other-model",
                             "payload_hash": "hash-other"})
        elif m == "reject400":
            self._send(400, {"error": "create_review_failed",
                             "message": "invalid input: machine_name is required"})
        else:
            self._send(500, {"error": "internal", "message": "boom"})

    def _events(self, m, body):
        if m == "event_bad_created":
            self._send(201, {"id": "not-a-number", "family": "event",
                             "submission_type": body.get("kind"),
                             "run_id": body.get("key"),
                             "machine_name": body.get("machine_name")})
            return
        if m == "event_bad_id_foreign_key":
            # A receipt naming someone else's key, but with a string id: it is
            # NOT comparable, so it proves no collision — only that the body is
            # malformed and the event must be retried.
            self._send(201, {"id": "9", "family": "event",
                             "submission_type": body.get("kind"),
                             "run_id": "someone-elses-key",
                             "machine_name": "other-machine",
                             "coordinator_model": "other-model"})
            return
        if m == "event_two_docs":
            # Two concatenated JSON documents: jq would read the first and
            # ignore the second, so the body is not a receipt at all.
            one = json.dumps({"id": 601, "family": "event",
                              "submission_type": body.get("kind"),
                              "run_id": body.get("key"),
                              "machine_name": body.get("machine_name"),
                              "coordinator_model": body.get("coordinator_model")})
            self._send_raw(201, (one + "\n" + one + "\n").encode(), "application/json")
            return
        if m == "event_unparseable":
            self._send_raw(201, b"{not json", "application/json")
            return
        if m == "event_collision":
            self._send(200, {"id": 9, "family": "event",
                             "submission_type": body.get("kind"),
                             "run_id": "someone-elses-key",
                             "machine_name": "other-machine",
                             "coordinator_model": "other-model"})
            return
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
            if wanted not in KNOWN_IDS:
                self._send(404, {"error": "not_found",
                                 "message": "submission %d not found" % wanted})
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
        if mode() == "list_bad_shape":
            # A 200 that carries none of the paging contract. Reading it as an
            # empty last page would look exactly like an empty queue.
            self._send(200, {})
            return
        if mode() == "pagination_bad":
            # has_more with no usable cursor: following it would silently
            # truncate the queue.
            self._send(200, {"submissions": [full_row(i) if include_payload
                                             else summary_row(i) for i in page],
                             "limit": limit, "offset": offset, "total": total,
                             "has_more": True, "next_before_id": None})
            return
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
        m = mode()
        if m == "export_http_500":
            self._send(500, {"error": "internal", "message": "export blew up"})
            return
        total = 0 if m == "export_empty" else list_rows()
        family = q.get("family", [None])[0]
        since = q.get("since", [None])[0]
        if m == "export_bad_header":
            header = json.dumps({"submissions": "this is not an export header"})
        elif m == "export_filtered_header":
            # A well-formed header that reports a filter the caller never asked
            # for: the stream is a subset of the database.
            header = json.dumps({"export_format": 1, "family": "friction",
                                 "since": None,
                                 "exported_at": "2026-07-30T00:00:00.000000Z"})
        else:
            header = json.dumps({"export_format": 1, "family": family, "since": since,
                                 "exported_at": "2026-07-30T00:00:00.000000Z"})
        records = "".join(json.dumps(full_row(i)) + "\n" for i in range(1, total + 1))
        out = header + "\n" + records
        if m != "export_no_terminator":
            digest = hashlib.sha256(records.encode()).hexdigest()
            out += json.dumps({"export_complete": True, "count": total,
                               "sha256": digest}) + "\n"
        self._send_raw(200, out.encode(), "application/x-ndjson")


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
