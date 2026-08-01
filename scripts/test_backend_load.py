#!/usr/bin/env python3
"""Deterministic local contract tests for the opt-in backend load gate."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import time
from typing import Any
import unittest
from urllib.parse import parse_qs, urlsplit
import uuid


SCRIPT = Path(__file__).with_name("run_backend_load.py")
PROJECT_DIRECTORY = SCRIPT.parent.parent
WORKFLOW = PROJECT_DIRECTORY / ".github/workflows/staging-backend-load.yml"
SPEC = importlib.util.spec_from_file_location("pakperk_backend_load", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load backend load module")
LOAD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LOAD
SPEC.loader.exec_module(LOAD)


TOKEN_SENTINEL = "opaque-load-token-that-must-never-be-recorded"
COMMENT_SENTINEL = "private comment content must never be recorded"
METADATA_SENTINEL = "private metadata title must never be recorded"
PAPER_IDS = tuple(str(uuid.UUID(int=index + 1)) for index in range(220))
COMMENTS_PAPER_ID = PAPER_IDS[0]
MUTATION_PAPER_ID = str(uuid.UUID(int=10_001))


class MockApiHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    saved = False
    mutation_requests = 0
    active_mutations = 0
    maximum_active_mutations = 0
    guest_authorization_seen = False
    slow_metadata_seconds = 0.0
    state_lock = threading.Lock()

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    @classmethod
    def reset(cls) -> None:
        with cls.state_lock:
            cls.saved = False
            cls.mutation_requests = 0
            cls.active_mutations = 0
            cls.maximum_active_mutations = 0
            cls.guest_authorization_seen = False
            cls.slow_metadata_seconds = 0.0

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _authorized(self) -> bool:
        if self.headers.get("Authorization") == f"Bearer {TOKEN_SENTINEL}":
            return True
        self._json(401, {"error": {"code": "UNAUTHENTICATED"}})
        return False

    def _record_guest_auth(self) -> None:
        if self.headers.get("Authorization") is not None:
            with type(self).state_lock:
                type(self).guest_authorization_seen = True

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract.
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/v1/feed":
            self._record_guest_auth()
            limit = int(query.get("limit", ["100"])[0])
            start = int(query.get("cursor", ["0"])[0])
            end = min(start + limit, len(PAPER_IDS))
            self._json(
                200,
                {
                    "items": [
                        {"paper_id": paper_id, "title": METADATA_SENTINEL}
                        for paper_id in PAPER_IDS[start:end]
                    ],
                    "next_cursor": str(end) if end < len(PAPER_IDS) else None,
                },
            )
            return
        if parsed.path.startswith("/v1/papers/") and parsed.path.endswith("/comments"):
            if self.headers.get("Authorization") is not None and not self._authorized():
                return
            self._json(
                200,
                {
                    "items": [{"body": COMMENT_SENTINEL}],
                    "next_cursor": None,
                },
            )
            return
        if parsed.path.startswith("/v1/papers/"):
            self._record_guest_auth()
            if type(self).slow_metadata_seconds:
                time.sleep(type(self).slow_metadata_seconds)
            self._json(
                200,
                {
                    "paper_id": parsed.path.rsplit("/", 1)[-1],
                    "title": METADATA_SENTINEL,
                },
            )
            return
        if parsed.path == "/v1/me/library":
            if not self._authorized():
                return
            with type(self).state_lock:
                saved = type(self).saved
            items = (
                [{"item": {"paper_id": MUTATION_PAPER_ID}, "paper": {}}]
                if saved
                else []
            )
            self._json(
                200,
                {"items": items, "next_cursor": None, "sync_revision": 0},
            )
            return
        self._json(404, {"error": {"code": "NOT_FOUND"}})

    def _mutation(self, removed: bool) -> None:
        if not self._authorized():
            return
        with type(self).state_lock:
            type(self).mutation_requests += 1
            type(self).active_mutations += 1
            type(self).maximum_active_mutations = max(
                type(self).maximum_active_mutations,
                type(self).active_mutations,
            )
        try:
            time.sleep(0.002)
            with type(self).state_lock:
                type(self).saved = not removed
            self._json(
                200,
                {
                    "item": {
                        "paper_id": MUTATION_PAPER_ID,
                        "removed": removed,
                    }
                },
            )
        finally:
            with type(self).state_lock:
                type(self).active_mutations -= 1

    def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract.
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": {"code": "INVALID_REQUEST"}})
            return
        if (
            self.path != f"/v1/me/library/{MUTATION_PAPER_ID}"
            or payload.get("state") != "to_read"
            or payload.get("operation_id") != self.headers.get("Idempotency-Key")
        ):
            self._json(400, {"error": {"code": "INVALID_REQUEST"}})
            return
        self._mutation(removed=False)

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract.
        if self.path != f"/v1/me/library/{MUTATION_PAPER_ID}":
            self._json(404, {"error": {"code": "NOT_FOUND"}})
            return
        self._mutation(removed=True)


class LoopbackThreadingHttpServer(ThreadingHTTPServer):
    """Avoid HTTPServer's reverse-DNS lookup in hermetic CI sandboxes."""

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class BackendLoadContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = LoopbackThreadingHttpServer(("127.0.0.1", 0), MockApiHandler)
        cls.server.daemon_threads = True
        cls.server_thread = threading.Thread(target=cls.server.serve_forever)
        cls.server_thread.start()
        host, port = cls.server.server_address
        cls.origin = f"http://{host}:{port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.server_thread.join(timeout=5)

    def setUp(self) -> None:
        MockApiHandler.reset()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)

    def base_arguments(self, output: Path) -> list[str]:
        return [
            "--api-origin",
            self.origin,
            "--environment",
            "development",
            "--allow-loopback-http",
            "--output",
            str(output),
            "--evidence-id",
            "contract/test",
            "--source-revision",
            "a" * 40,
            "--duration-seconds",
            "0.1",
            "--concurrency",
            "1",
            "--max-requests",
            "40",
            "--request-timeout-seconds",
            "1",
            "--minimum-paper-records",
            "200",
            "--minimum-samples-per-scenario",
            "2",
            "--warmup-per-worker",
            "1",
            "--threshold",
            "feed=60000,60000,60000,0",
            "--threshold",
            "metadata=60000,60000,60000,0",
        ]

    def run_main(self, arguments: list[str]) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = LOAD.main(arguments)
        return result, stdout.getvalue(), stderr.getvalue()

    def test_guest_gate_is_bounded_canonical_and_content_redacted(self) -> None:
        output = self.directory / "guest-evidence.json"
        result, stdout, stderr = self.run_main(self.base_arguments(output))

        self.assertEqual(result, 0, stderr)
        self.assertRegex(
            stdout,
            r"^PASS backend load gate \([0-9]+ measured requests, 2 scenarios\)\n$",
        )
        self.assertEqual(stderr, "")
        evidence = json.loads(output.read_text(encoding="utf-8"))
        self.assertTrue(evidence["gate"]["passed"])
        self.assertEqual(
            evidence["workload"]["enabled_scenarios"], ["feed", "metadata"]
        )
        self.assertGreaterEqual(evidence["workload"]["paper_records_discovered"], 200)
        self.assertLessEqual(evidence["measurements"]["overall"]["requests"], 40)
        serialized = output.read_text(encoding="utf-8")
        for secret in (
            self.origin,
            TOKEN_SENTINEL,
            COMMENT_SENTINEL,
            METADATA_SENTINEL,
            PAPER_IDS[0],
        ):
            self.assertNotIn(secret, serialized)
        self.assertFalse(MockApiHandler.guest_authorization_seen)
        self.assertEqual(output.stat().st_mode & 0o777, 0o400)
        with self.assertRaises(LOAD.LoadError):
            LOAD.write_evidence(output, evidence)

    def test_authenticated_reads_and_capped_mutations_leave_target_absent(self) -> None:
        token_file = self.directory / "token"
        token_file.write_text(TOKEN_SENTINEL + "\n", encoding="utf-8")
        token_file.chmod(0o600)
        output = self.directory / "authenticated-evidence.json"
        arguments = self.base_arguments(output) + [
            "--concurrency",
            "4",
            "--bearer-token-file",
            str(token_file),
            "--include-library",
            "--comments-paper-id",
            COMMENTS_PAPER_ID,
            "--allow-library-mutations",
            "--library-mutation-paper-id",
            MUTATION_PAPER_ID,
            "--max-library-mutation-requests",
            "4",
            "--scenario-weight",
            "metadata=1",
            "--threshold",
            "library=60000,60000,60000,0",
            "--threshold",
            "comments=60000,60000,60000,0",
            "--threshold",
            "library_mutation=60000,60000,60000,0",
        ]

        result, stdout, stderr = self.run_main(arguments)

        self.assertEqual(result, 0, stderr)
        self.assertIn("5 scenarios", stdout)
        evidence = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(
            evidence["workload"]["authenticated_scenarios"],
            ["library", "comments", "library_mutation"],
        )
        self.assertEqual(evidence["workload"]["library_mutation_request_cap"], 4)
        mutation_measurement = evidence["measurements"]["scenarios"]["library_mutation"]
        self.assertGreaterEqual(mutation_measurement["requests"], 2)
        self.assertLessEqual(mutation_measurement["requests"], 4)
        self.assertEqual(mutation_measurement["errors"], 0)
        self.assertNotIn(
            "mutation_single_flight_busy",
            mutation_measurement["errors_by_class"],
        )
        self.assertFalse(MockApiHandler.saved)
        self.assertEqual(
            MockApiHandler.mutation_requests,
            mutation_measurement["requests"] + 1,
        )
        self.assertLessEqual(MockApiHandler.maximum_active_mutations, 1)
        serialized = output.read_text(encoding="utf-8")
        for secret in (
            self.origin,
            TOKEN_SENTINEL,
            COMMENT_SENTINEL,
            METADATA_SENTINEL,
            COMMENTS_PAPER_ID,
            MUTATION_PAPER_ID,
        ):
            self.assertNotIn(secret, serialized)

    def test_threshold_failure_is_written_without_response_content(self) -> None:
        output = self.directory / "failed-evidence.json"
        arguments = self.base_arguments(output) + [
            "--simulated-network-delay-ms",
            "10",
            "--threshold",
            "metadata=1,1,1,0",
        ]

        result, stdout, stderr = self.run_main(arguments)

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertRegex(stderr, r"^FAIL backend load gate \(")
        evidence = json.loads(output.read_text(encoding="utf-8"))
        self.assertFalse(evidence["gate"]["passed"])
        self.assertIn("metadata:p50", evidence["gate"]["failures"])
        self.assertIn("metadata:p95", evidence["gate"]["failures"])
        self.assertIn("metadata:p99", evidence["gate"]["failures"])
        self.assertEqual(
            evidence["workload"]["simulated_network"],
            {
                "fixed_delay_ms": 10.0,
                "loss_selection": "deterministic_sha256",
                "packet_loss_rate": 0.0,
            },
        )
        self.assertNotIn(METADATA_SENTINEL, output.read_text(encoding="utf-8"))

    def test_unsafe_token_permissions_are_rejected_before_network_use(self) -> None:
        token_file = self.directory / "token"
        token_file.write_text(TOKEN_SENTINEL, encoding="utf-8")
        token_file.chmod(0o644)
        output = self.directory / "unsafe-token-evidence.json"

        with self.assertRaisesRegex(LOAD.ConfigurationError, "owner-only"):
            LOAD.parse_config(
                self.base_arguments(output)
                + ["--bearer-token-file", str(token_file), "--include-library"]
            )
        self.assertFalse(output.exists())

    def test_staging_rejects_plain_http_and_development_http_is_loopback_only(
        self,
    ) -> None:
        with self.assertRaisesRegex(LOAD.ConfigurationError, "require an HTTPS"):
            LOAD.validated_origin("http://127.0.0.1:8080", "staging", True)
        with self.assertRaisesRegex(LOAD.ConfigurationError, "loopback"):
            LOAD.validated_origin("http://staging.example.org", "development", True)
        self.assertEqual(
            LOAD.validated_origin("https://api.staging.example.org", "staging", False),
            ("https", "api.staging.example.org", 443),
        )

    def test_nearest_rank_percentiles_are_stable(self) -> None:
        samples = [
            10_000,
            1_000,
            9_000,
            2_000,
            8_000,
            3_000,
            7_000,
            4_000,
            6_000,
            5_000,
        ]
        self.assertEqual(LOAD.nearest_rank(samples, 0.50), 5_000)
        self.assertEqual(LOAD.nearest_rank(samples, 0.95), 10_000)
        self.assertEqual(LOAD.nearest_rank(samples, 0.99), 10_000)

    def test_resource_validators_reject_a_different_uuid(self) -> None:
        with self.assertRaises(LOAD.ProtocolError):
            LOAD.validate_metadata(
                {"paper_id": PAPER_IDS[1]},
                PAPER_IDS[0],
            )
        with self.assertRaises(LOAD.ProtocolError):
            LOAD.validate_mutation(
                {"item": {"paper_id": PAPER_IDS[1], "removed": False}},
                False,
                PAPER_IDS[0],
            )

    def test_packet_loss_selection_is_repeatable(self) -> None:
        output = self.directory / "packet-loss-evidence.json"
        config = LOAD.parse_config(
            self.base_arguments(output) + ["--simulated-packet-loss-rate", "0.25"]
        )
        first = LOAD.Workload(config, ["/v1/feed?limit=100"], list(PAPER_IDS))
        second = LOAD.Workload(config, ["/v1/feed?limit=100"], list(PAPER_IDS))
        first_pattern = [
            first._simulates_packet_loss("metadata", index) for index in range(100)
        ]
        second_pattern = [
            second._simulates_packet_loss("metadata", index) for index in range(100)
        ]
        self.assertEqual(first_pattern, second_pattern)
        self.assertGreater(sum(first_pattern), 0)
        self.assertLess(sum(first_pattern), len(first_pattern))

    def test_live_workflow_is_manual_protected_bounded_and_not_in_ci(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("\n  push:", workflow)
        self.assertNotIn("\n  pull_request:", workflow)
        self.assertNotIn("\n  schedule:", workflow)
        self.assertIn("environment: staging", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("timeout-minutes: 15", workflow)
        self.assertIn('options: ["1", "4", "8", "16"]', workflow)
        self.assertIn('options: ["1000", "5000", "10000", "25000"]', workflow)
        self.assertIn("--environment staging", workflow)
        self.assertIn('--max-requests "$MAX_REQUESTS"', workflow)
        self.assertIn("--allow-library-mutations", workflow)
        self.assertIn("environment staging", workflow)
        self.assertIn("PAKPERK_STAGING_API_ORIGIN", workflow)
        self.assertIn("PAKPERK_STAGING_LOAD_TOKEN", workflow)
        self.assertEqual(
            workflow.count(
                "STAGING_LOAD_TOKEN: ${{ secrets.PAKPERK_STAGING_LOAD_TOKEN }}"
            ),
            1,
        )
        self.assertNotIn("add-mask::$STAGING_LOAD_TOKEN", workflow)
        self.assertNotIn('echo "$STAGING_LOAD_TOKEN"', workflow)
        self.assertIn("continue-on-error: true", workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", workflow)
        self.assertIn(
            'chmod 0400 "$RUNNER_TEMP/pakperk-backend-load-evidence.tar"', workflow
        )
        self.assertIn("if-no-files-found: error", workflow)
        self.assertNotIn("if-no-files-found: warn", workflow)

        ci = (PROJECT_DIRECTORY / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        check = (PROJECT_DIRECTORY / "scripts/check.sh").read_text(encoding="utf-8")
        self.assertIn("python3 scripts/test_backend_load.py", ci)
        self.assertNotIn("run_backend_load.py", ci)
        self.assertIn('python3 "$project_dir/scripts/test_backend_load.py"', check)
        self.assertNotIn("run_backend_load.py", check)


if __name__ == "__main__":
    unittest.main(verbosity=2)
