#!/usr/bin/env python3
"""Disclosure boundaries and advisory failure behavior; no external requests."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "skills/feedback-triage/scripts/cluster.py"
spec = importlib.util.spec_from_file_location("cluster", SCRIPT)
cluster = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster)


def report(report_id, remote="repo-a"):
    return {"id": report_id, "family": "friction", "processed_at": None,
            "payload": {"summary": "broken flag", "details": "specific failure",
                        "context": {"git_remote": remote, "cwd": "PRIVATE_PATH"},
                        "machine_name": "PRIVATE_MACHINE"}}


def response(choice="same", confidence=0.9):
    return {"answers": {"mechanism": {
        "type": "choice", "choice": choice, "confidence": confidence,
        "probabilities": {key: 0.9 if key == choice else 0.05 for key in cluster.CRITERIA},
    }}}


def completed(choice="same", confidence=0.9):
    answer = response(choice, confidence)["answers"]["mechanism"]
    return {"status": "completed", **answer, "suggestion": choice if confidence >= 0.8 else "uncertain"}


class Clustering(unittest.TestCase):
    def invoke(self, rows, allowed, key="testkey", limit=200, preview=False):
        return cluster.run(rows, "digest-sha", set(allowed), key, limit, 1, preview)

    def test_no_implicit_disclosure(self):
        rows = [report(1), report(2), report(3, "repo-b")]
        with patch.object(cluster, "compare") as compare:
            for allowed, key, limit in [((), "key", 200), (("repo-a",), "", 200),
                                        (("repo-a", "repo-b"), "key", 1)]:
                result = self.invoke(rows, allowed, key, limit)
                self.assertEqual(result["status"], "skipped")
                self.assertEqual(result["groups"], [[1], [2], [3]])
            preview = self.invoke(rows, ("repo-a",), preview=True)
            self.assertEqual([row["id"] for row in preview["disclosure"]], [1, 2])
            self.assertNotIn("PRIVATE_", json.dumps(preview["disclosure"]))
            compare.assert_not_called()

    def test_cross_repository_pairs_require_both_approvals(self):
        rows = [report(1), report(2, "repo-b"), report(3, ""), report(4, "repo-a.git")]
        original = copy.deepcopy(rows)
        with patch.object(cluster, "compare", return_value=completed()) as compare:
            self.assertEqual(self.invoke(rows, ("repo-a",))["candidate_pairs"], 0)
            compare.assert_not_called()
            result = self.invoke(rows, ("repo-a", "repo-b"))
            self.assertEqual(result["groups"], [[1, 2], [3], [4]])
            self.assertEqual([(call.args[0]["id"], call.args[1]["id"]) for call in compare.call_args_list], [(1, 2)])
        self.assertEqual(rows, original)

    def test_bridge_is_not_transitive_consensus(self):
        with patch.object(cluster, "compare", side_effect=[completed(), completed("different"), completed()]):
            result = self.invoke([report(1), report(2), report(3)], ("repo-a",))
        self.assertEqual(result["groups"], [[1, 2], [3]])
        self.assertEqual(result["comparisons"][2]["suggestion"], "same")

    def test_partial_failure_keeps_all_reports_and_completed_advice(self):
        with patch.object(cluster, "compare", side_effect=[completed(), {"status": "unassessed", "reason": "transport_failed"}]) as compare:
            result = self.invoke([report(i) for i in range(1, 5)], ("repo-a",))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["evaluated_pairs"], 1)
        self.assertEqual(result["groups"], [[1, 2], [3], [4]])
        self.assertEqual(compare.call_count, 2)

    def test_transport_sends_only_allowlisted_fields_and_protects_key(self):
        with patch.object(cluster.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(response()).encode(), b"")) as transport:
            result = cluster.compare(report(1), report(2), "sensitive-key", 1)
        self.assertEqual(result["suggestion"], "same")
        args, kwargs = transport.call_args
        self.assertNotIn("sensitive-key", " ".join(args[0]))
        config = kwargs["input"].decode().splitlines()
        request = json.loads(json.loads(config[1].split(" = ", 1)[1]))
        self.assertEqual(request["state"]["reports"], [cluster.evidence(report(1)), cluster.evidence(report(2))])
        self.assertNotIn("PRIVATE_", json.dumps(request))

    def test_uncertain_and_invalid_answers_never_group(self):
        cases = [response("uncertain"), response(confidence=0.2)]
        invalid = []
        for field, value in [("confidence", True), ("confidence", float("nan")),
                             ("choice", []), ("type", "noul"), ("probabilities", {"same": 1})]:
            item = response()
            item["answers"]["mechanism"][field] = value
            invalid.append(item)
        for payload in cases + invalid + [{}, []]:
            with self.subTest(payload=payload), patch.object(cluster.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(payload).encode(), b"")):
                result = cluster.compare(report(1), report(2), "key", 1)
                self.assertNotEqual(result.get("suggestion"), "same")

    def test_failed_transport_does_not_echo_private_errors(self):
        outcomes = [subprocess.CompletedProcess([], 22, b"", b"PRIVATE_RESPONSE"),
                    subprocess.TimeoutExpired("curl", 1, output=b"PRIVATE_RESPONSE")]
        for outcome in outcomes:
            with patch.object(cluster.subprocess, "run", side_effect=[outcome]):
                result = cluster.compare(report(1), report(2), "key", 1)
            self.assertEqual(result["status"], "unassessed")
            self.assertNotIn("PRIVATE", json.dumps(result))

    def test_cli_rejects_contaminated_or_duplicate_digest_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "index.json"
            for rows in [[report(1), report(1)], [{**report(1), "processed_at": "already-done"}],
                         [{**report(1), "family": "event"}]]:
                path.write_text(json.dumps(rows))
                proc = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True,
                                      env={**os.environ, "TYPESAFE_API_KEY": ""})
                self.assertEqual(proc.returncode, 1)
                self.assertEqual(json.loads(proc.stdout)["status"], "error")


if __name__ == "__main__":
    unittest.main()
