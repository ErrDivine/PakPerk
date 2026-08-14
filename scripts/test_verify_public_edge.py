#!/usr/bin/env python3
"""Hermetic public-edge transport and verifier regressions."""

from __future__ import annotations

from dataclasses import replace
import gzip
import json
from pathlib import Path
import socket
import ssl
import time
import unittest
from unittest import mock

from public_edge_evidence import (
    SCENARIO_IDS,
    PublicEdgeBinding,
    build_evidence,
    validate_evidence,
)
from verify_public_edge import (
    DirectPublicTransport,
    EXPECTED_CONFIG_CACHE,
    EXPECTED_DEFAULT_CACHE,
    EXPECTED_DELETION_CACHE,
    EXPECTED_HSTS,
    EXPECTED_STATIC_SECURITY_HEADERS,
    HttpObservation,
    MAX_DECOMPRESSED_FEED_BYTES,
    SITE_HTML_ROUTES,
    SocketDeadlineGuard,
    VerificationError,
    _expected_csp,
    _reject_ambient_network_authority,
    run_verification,
)


SOURCE_REVISION = "a" * 40
CANDIDATE_ID = "sha256:" + "b" * 64
ANDROID_SHA256 = ":".join(f"{index:02X}" for index in range(32))


def binding() -> PublicEdgeBinding:
    return PublicEdgeBinding(
        source_revision=SOURCE_REVISION,
        target_environment="staging",
        requested_candidate_id=CANDIDATE_ID,
        site_origin="https://staging.pakperk.app",
        api_origin="https://api.staging.pakperk.app",
        telemetry_origin="https://telemetry.staging.pakperk.app",
        document_version="2026-08-01",
        oidc_issuer="https://identity.staging.pakperk.app/realms/pakperk",
        oidc_client_id="pakperk-web-deletion-staging",
        support_email="support@pakperk.app",
        android_package="app.pakperk.pakperk.staging",
        android_sha256=ANDROID_SHA256,
        apple_team_id="PKPRK2026A",
        apple_bundle_id="app.pakperk.pakperk.staging",
    ).validate()


def response(
    status: int,
    headers: list[tuple[str, str]],
    body: bytes = b"",
    *,
    secure: bool = True,
) -> HttpObservation:
    return HttpObservation(
        status=status,
        headers=tuple((name.lower(), value) for name, value in headers),
        body=body,
        tls_version="TLSv1.3" if secure else None,
    )


def site_headers(
    candidate: PublicEdgeBinding, cache: str, media: str
) -> list[tuple[str, str]]:
    headers = [
        ("strict-transport-security", EXPECTED_HSTS),
        ("cache-control", cache),
        ("content-security-policy", _expected_csp(candidate)),
        ("content-type", f"{media}; charset=utf-8"),
    ]
    headers.extend(EXPECTED_STATIC_SECURITY_HEADERS.items())
    return headers


class FixtureTransport:
    def __init__(self, responses: dict[tuple[bool, str, str], HttpObservation]):
        self.responses = responses
        self.calls: list[tuple[bool, str, str, int, dict[str, str]]] = []

    def request(
        self,
        origin: str,
        path: str,
        *,
        secure: bool,
        maximum_body_bytes: int,
        request_headers=None,
    ) -> HttpObservation:
        headers = dict(request_headers or {})
        self.calls.append((secure, origin, path, maximum_body_bytes, headers))
        result = self.responses[(secure, origin, path)]
        if len(result.body) > maximum_body_bytes:
            raise VerificationError("response_body_exceeds_boundary")
        return result


def valid_responses(
    candidate: PublicEdgeBinding,
) -> dict[tuple[bool, str, str], HttpObservation]:
    runtime = (
        "window.__PAKPERK_PUBLIC_CONFIG__ = Object.freeze({\n"
        f'  environment: "{candidate.target_environment}",\n'
        f'  publicOrigin: "{candidate.site_origin}",\n'
        f'  apiBaseUrl: "{candidate.api_origin}",\n'
        f'  oidcIssuer: "{candidate.oidc_issuer}",\n'
        f'  oidcClientId: "{candidate.oidc_client_id}",\n'
        f'  supportEmail: "{candidate.support_email}",\n'
        f'  documentVersion: "{candidate.document_version}"\n'
        "});\n"
    ).encode()
    values: dict[tuple[bool, str, str], HttpObservation] = {
        (True, candidate.site_origin, "/config.js"): response(
            200,
            site_headers(candidate, EXPECTED_CONFIG_CACHE, "application/javascript"),
            runtime,
        ),
        (False, candidate.site_origin, "/"): response(
            308, [("location", f"{candidate.site_origin}/")], secure=False
        ),
        (False, candidate.api_origin, "/health/ready"): response(
            308,
            [("location", f"{candidate.api_origin}/health/ready")],
            secure=False,
        ),
        (False, candidate.telemetry_origin, "/health/ready"): response(
            308,
            [("location", f"{candidate.telemetry_origin}/health/ready")],
            secure=False,
        ),
    }
    html_routes = (
        ("/", EXPECTED_DEFAULT_CACHE, "Pakperk — Guide, policies, and support"),
        ("/guide/", EXPECTED_DEFAULT_CACHE, "User guide — Pakperk"),
        ("/privacy/", EXPECTED_DEFAULT_CACHE, "Privacy notice — Pakperk"),
        ("/terms/", EXPECTED_DEFAULT_CACHE, "Terms of use — Pakperk"),
        (
            "/community-guidelines/",
            EXPECTED_DEFAULT_CACHE,
            "Community guidelines — Pakperk",
        ),
        ("/support/", EXPECTED_DEFAULT_CACHE, "Support and safety — Pakperk"),
        ("/account-deletion/", EXPECTED_DELETION_CACHE, "Delete account — Pakperk"),
        (
            "/open-source-licenses/",
            EXPECTED_DEFAULT_CACHE,
            "Open-source licenses — Pakperk",
        ),
    )
    for path, cache, title in html_routes:
        controls = (
            '<input id="confirm-deletion"><button id="start-deletion">'
            if path == "/account-deletion/"
            else ""
        )
        values[(True, candidate.site_origin, path)] = response(
            200,
            site_headers(candidate, cache, "text/html"),
            f"<!doctype html><title>{title}</title>{controls}".encode(),
        )
    inventory = (
        "Pakperk open-source dependency notices\n"
        "=======================================\n\n"
        f"Source revision: {candidate.source_revision}\n"
    ).encode()
    values[(True, candidate.site_origin, "/open-source-licenses/notices.txt")] = (
        response(
            206,
            site_headers(candidate, EXPECTED_DEFAULT_CACHE, "text/plain")
            + [("content-range", f"bytes 0-{len(inventory) - 1}/200000")],
            inventory,
        )
    )
    values[(True, candidate.site_origin, "/.well-known/assetlinks.json")] = response(
        200,
        site_headers(candidate, EXPECTED_DEFAULT_CACHE, "application/json"),
        json.dumps(
            [
                {
                    "relation": ["delegate_permission/common.handle_all_urls"],
                    "target": {
                        "namespace": "android_app",
                        "package_name": candidate.android_package,
                        "sha256_cert_fingerprints": [candidate.android_sha256],
                    },
                }
            ],
            separators=(",", ":"),
        ).encode(),
    )
    values[(True, candidate.site_origin, "/.well-known/apple-app-site-association")] = (
        response(
            200,
            site_headers(candidate, EXPECTED_DEFAULT_CACHE, "application/json"),
            json.dumps(
                {
                    "applinks": {
                        "details": [
                            {
                                "appIDs": [
                                    f"{candidate.apple_team_id}.{candidate.apple_bundle_id}"
                                ],
                                "components": [{"/": "/p/*"}, {"/": "/arxiv/*"}],
                            }
                        ]
                    }
                },
                separators=(",", ":"),
            ).encode(),
        )
    )
    values[(True, candidate.api_origin, "/health/ready")] = response(
        200,
        [
            ("strict-transport-security", EXPECTED_HSTS),
            ("cache-control", "no-store"),
            ("content-type", "application/json"),
        ],
        b'{"status":"ready"}',
    )
    values[(True, candidate.api_origin, "/v1/feed?limit=100")] = response(
        200,
        [
            ("strict-transport-security", EXPECTED_HSTS),
            ("cache-control", "public, max-age=60, stale-while-revalidate=300"),
            ("content-type", "application/json"),
            ("content-encoding", "gzip"),
            ("vary", "Accept-Encoding"),
        ],
        gzip.compress(
            b'{"items":['
            + b",".join(b'{"paper_id":"fixture"}' for _ in range(64))
            + b'],"next_cursor":null}'
        ),
    )
    values[(True, candidate.telemetry_origin, "/health/ready")] = response(
        200,
        [
            ("strict-transport-security", EXPECTED_HSTS),
            ("cache-control", "no-store"),
        ],
    )
    return values


class VerifyPublicEdgeTest(unittest.TestCase):
    def test_complete_matrix_passes_and_never_requests_credentials(self) -> None:
        candidate = binding()
        transport = FixtureTransport(valid_responses(candidate))
        outcome, state, failure = run_verification(candidate, transport)
        self.assertEqual(outcome, "passed")
        self.assertIsNone(failure)
        self.assertEqual(tuple(state), SCENARIO_IDS)
        self.assertTrue(all(value["outcome"] == "passed" for value in state.values()))
        evidence = build_evidence(candidate, state, outcome)
        validate_evidence(
            evidence, expected_binding=candidate, expected_outcome="passed"
        )
        self.assertEqual(len(transport.calls), len(SCENARIO_IDS))
        for _secure, _origin, _path, maximum, headers in transport.calls:
            self.assertGreater(maximum, 0)
            self.assertFalse(
                {name.lower() for name in headers}
                & {"authorization", "cookie", "proxy-authorization"}
            )
        inventory_call = next(
            call
            for call in transport.calls
            if call[2] == "/open-source-licenses/notices.txt"
        )
        self.assertEqual(inventory_call[4], {"Range": "bytes=0-16383"})
        feed_call = next(
            call for call in transport.calls if call[2] == "/v1/feed?limit=100"
        )
        self.assertEqual(feed_call[4], {"Accept-Encoding": "gzip"})

    def test_failures_are_one_safe_category_and_leave_suffix_not_run(self) -> None:
        candidate = binding()
        mutations = {
            "config mismatch": (
                (True, candidate.site_origin, "/config.js"),
                lambda value: replace(
                    value, body=value.body.replace(b"support@", b"other@")
                ),
            ),
            "hostile redirect": (
                (False, candidate.site_origin, "/"),
                lambda value: replace(
                    value,
                    headers=(
                        ("location", "https://attacker.invalid/private?token=secret"),
                    ),
                ),
            ),
            "duplicate hsts": (
                (True, candidate.site_origin, "/privacy/"),
                lambda value: replace(
                    value,
                    headers=value.headers
                    + (("strict-transport-security", EXPECTED_HSTS),),
                ),
            ),
            "generic html": (
                (True, candidate.site_origin, "/terms/"),
                lambda value: replace(
                    value,
                    body=b"<!doctype html><title>Generic success</title>",
                ),
            ),
            "deletion cache": (
                (True, candidate.site_origin, "/account-deletion/"),
                lambda value: replace(
                    value,
                    headers=tuple(
                        (
                            name,
                            (
                                EXPECTED_DEFAULT_CACHE
                                if name == "cache-control"
                                else header
                            ),
                        )
                        for name, header in value.headers
                    ),
                ),
            ),
            "source mismatch": (
                (True, candidate.site_origin, "/open-source-licenses/notices.txt"),
                lambda value: replace(
                    value, body=value.body.replace(b"a" * 40, b"c" * 40)
                ),
            ),
            "notices header mismatch": (
                (
                    True,
                    candidate.site_origin,
                    "/open-source-licenses/notices.txt",
                ),
                lambda value: replace(
                    value,
                    body=value.body.replace(
                        b"Pakperk open-source dependency notices",
                        b"Unrelated generated dependency notices",
                    ),
                ),
            ),
            "android mismatch": (
                (True, candidate.site_origin, "/.well-known/assetlinks.json"),
                lambda value: replace(
                    value,
                    body=value.body.replace(b"pakperk.staging", b"wrongid.staging"),
                ),
            ),
            "apple mismatch": (
                (
                    True,
                    candidate.site_origin,
                    "/.well-known/apple-app-site-association",
                ),
                lambda value: replace(
                    value, body=value.body.replace(b"PKPRK2026A", b"WRONG2026A")
                ),
            ),
            "feed compression missing": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    headers=tuple(
                        item for item in value.headers if item[0] != "content-encoding"
                    ),
                ),
            ),
            "feed vary missing": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    headers=tuple(item for item in value.headers if item[0] != "vary"),
                ),
            ),
            "feed body not gzip": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(value, body=b'{"items":[]}'),
            ),
            "feed body is only gzip-shaped bytes": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(value, body=b"\x1f\x8b" + (b"\x00" * 16)),
            ),
            "feed body truncated gzip": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(value, body=value.body[:-8]),
            ),
            "feed body corrupt gzip": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    body=value.body[:-1] + bytes([value.body[-1] ^ 0xFF]),
                ),
            ),
            "feed body invalid json": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    body=gzip.compress(b'{"items":[],"next_cursor":null'),
                ),
            ),
            "feed body wrong envelope": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    body=gzip.compress(
                        b'{"items":[],"next_cursor":null,"extra":true}'
                    ),
                ),
            ),
            "feed decompressed body exceeds boundary": (
                (True, candidate.api_origin, "/v1/feed?limit=100"),
                lambda value: replace(
                    value,
                    body=gzip.compress(b" " * (MAX_DECOMPRESSED_FEED_BYTES + 1)),
                ),
            ),
            "api cache": (
                (True, candidate.api_origin, "/health/ready"),
                lambda value: replace(
                    value,
                    headers=tuple(
                        item for item in value.headers if item[0] != "cache-control"
                    ),
                ),
            ),
            "api duplicate json key": (
                (True, candidate.api_origin, "/health/ready"),
                lambda value: replace(
                    value,
                    body=b'{"status":"ready","status":"ready"}',
                ),
            ),
            "telemetry not empty": (
                (True, candidate.telemetry_origin, "/health/ready"),
                lambda value: replace(value, body=b"collector is fine"),
            ),
        }
        forbidden_log_values = ("attacker.invalid", "token=secret", "collector is fine")
        for label, (key, mutate) in mutations.items():
            with self.subTest(label=label):
                responses = valid_responses(candidate)
                responses[key] = mutate(responses[key])
                outcome, state, failure = run_verification(
                    candidate, FixtureTransport(responses)
                )
                self.assertEqual(outcome, "failed")
                self.assertIsNotNone(failure)
                self.assertFalse(
                    any(value in (failure or "") for value in forbidden_log_values)
                )
                outcomes = [state[scenario]["outcome"] for scenario in SCENARIO_IDS]
                self.assertEqual(outcomes.count("failed"), 1)
                failure_index = outcomes.index("failed")
                self.assertTrue(
                    all(value == "passed" for value in outcomes[:failure_index])
                )
                self.assertTrue(
                    all(value == "not_run" for value in outcomes[failure_index + 1 :])
                )
                evidence = build_evidence(candidate, state, outcome)
                validate_evidence(
                    evidence, expected_binding=candidate, expected_outcome="failed"
                )

    def test_deployed_route_markers_match_the_checked_in_site(self) -> None:
        project = Path(__file__).resolve().parents[1]
        for _scenario, path, _cache, title in SITE_HTML_ROUTES:
            relative = "index.html" if path == "/" else f"{path.strip('/')}/index.html"
            html = (project / "site" / relative).read_text(encoding="utf-8")
            self.assertEqual(html.count(title), 1, path)
            self.assertEqual(html.count("<title>"), 1, path)
            self.assertEqual(html.count("</title>"), 1, path)
            for (
                _other_scenario,
                _other_path,
                _other_cache,
                other_title,
            ) in SITE_HTML_ROUTES:
                if other_title != title:
                    self.assertNotIn(other_title, html, path)
            if path == "/account-deletion/":
                self.assertEqual(html.count('id="confirm-deletion"'), 1)
                self.assertEqual(html.count('id="start-deletion"'), 1)

    def test_html_route_markers_are_exclusive_to_each_route(self) -> None:
        candidate = binding()
        responses = valid_responses(candidate)
        omnibus_body = (
            "<!doctype html>"
            + "".join(title for _scenario, _path, _cache, title in SITE_HTML_ROUTES)
            + '<input id="confirm-deletion"><button id="start-deletion">'
        ).encode()
        for _scenario, path, _cache, _title in SITE_HTML_ROUTES:
            key = (True, candidate.site_origin, path)
            responses[key] = replace(responses[key], body=omnibus_body)

        outcome, state, failure = run_verification(
            candidate, FixtureTransport(responses)
        )

        self.assertEqual(outcome, "failed")
        self.assertEqual(failure, "public_site_route_marker_mismatch")
        self.assertEqual(
            sum(value["outcome"] == "failed" for value in state.values()), 1
        )

    def test_android_association_rejects_extra_or_stale_fingerprints(self) -> None:
        candidate = binding()
        responses = valid_responses(candidate)
        key = (True, candidate.site_origin, "/.well-known/assetlinks.json")
        document = json.loads(responses[key].body)
        document[0]["target"]["sha256_cert_fingerprints"].append(
            "12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:"
            "12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF"
        )
        responses[key] = replace(responses[key], body=json.dumps(document).encode())

        outcome, state, failure = run_verification(
            candidate, FixtureTransport(responses)
        )

        self.assertEqual(outcome, "failed")
        self.assertEqual(failure, "android_association_fingerprints_mismatch")
        self.assertEqual(
            sum(value["outcome"] == "failed" for value in state.values()), 1
        )

    def test_malformed_json_and_unhashable_fingerprint_fail_with_fixed_categories(
        self,
    ) -> None:
        candidate = binding()
        cases = []
        duplicate_api = valid_responses(candidate)
        api_key = (True, candidate.api_origin, "/health/ready")
        duplicate_api[api_key] = replace(
            duplicate_api[api_key], body=b'{"status":"ready","status":"ready"}'
        )
        cases.append(duplicate_api)

        object_fingerprint = valid_responses(candidate)
        android_key = (
            True,
            candidate.site_origin,
            "/.well-known/assetlinks.json",
        )
        android_document = json.loads(object_fingerprint[android_key].body)
        android_document[0]["target"]["sha256_cert_fingerprints"] = [{}]
        object_fingerprint[android_key] = replace(
            object_fingerprint[android_key], body=json.dumps(android_document).encode()
        )
        cases.append(object_fingerprint)

        deep_json = valid_responses(candidate)
        deep_json[android_key] = replace(
            deep_json[android_key], body=(b"[" * 1100) + (b"]" * 1100)
        )
        cases.append(deep_json)

        for responses in cases:
            outcome, state, failure = run_verification(
                candidate, FixtureTransport(responses)
            )
            self.assertEqual(outcome, "failed")
            self.assertIsInstance(failure, str)
            self.assertEqual(
                sum(value["outcome"] == "failed" for value in state.values()), 1
            )

    def test_body_limit_fails_before_invalid_response_can_be_retained(self) -> None:
        candidate = binding()
        responses = valid_responses(candidate)
        config_key = (True, candidate.site_origin, "/config.js")
        responses[config_key] = replace(
            responses[config_key], body=b"x" * (64 * 1024 + 1)
        )
        outcome, state, failure = run_verification(
            candidate, FixtureTransport(responses)
        )
        self.assertEqual(outcome, "failed")
        self.assertEqual(failure, "response_body_exceeds_boundary")
        self.assertEqual(state[SCENARIO_IDS[0]]["observation_id"], "not_observed")

    def test_direct_transport_rejects_any_non_public_dns_answer_and_caches_public_set(
        self,
    ) -> None:
        unsafe_addresses = (
            (socket.AF_INET, "10.0.0.1"),
            (socket.AF_INET, "0.0.0.0"),
            (socket.AF_INET, "224.0.0.1"),
            (socket.AF_INET6, "fe80::1"),
            (socket.AF_INET6, "fec0::1"),
            (socket.AF_INET6, "::ffff:10.0.0.1"),
            (socket.AF_INET6, "2002:7f00:1::"),
            (socket.AF_INET6, "2002:a00:1::"),
            (socket.AF_INET6, "2001:0000:4136:e378:8000:63bf:3fff:fdd2"),
        )
        for family, address in unsafe_addresses:
            transport = DirectPublicTransport()
            answer = [
                (
                    family,
                    socket.SOCK_STREAM,
                    socket.IPPROTO_TCP,
                    "",
                    (address, 0),
                )
            ]
            with self.subTest(address=address), mock.patch.object(
                transport, "_resolve_in_daemon", return_value=answer
            ):
                with self.assertRaisesRegex(VerificationError, "non_public"):
                    transport._resolve_public("api.pakperk.app")

        transport = DirectPublicTransport()
        public_answers = [
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                socket.IPPROTO_TCP,
                "",
                ("8.8.8.8", 0),
            )
        ]
        with mock.patch.object(
            transport, "_resolve_in_daemon", return_value=public_answers
        ) as resolve:
            self.assertEqual(
                transport._resolve_public("api.pakperk.app"),
                ((socket.AF_INET, "8.8.8.8"),),
            )
            transport._resolve_public("api.pakperk.app")
            resolve.assert_called_once()

    def test_direct_transport_bounds_body_and_malformed_content_length_without_network(
        self,
    ) -> None:
        class FakeSocket:
            def settimeout(self, _timeout):
                pass

            def shutdown(self, _how):
                pass

            def close(self):
                pass

        class FakeResponse:
            status = 200

            def __init__(self, body: bytes, headers=()):
                self.body = body
                self.position = 0
                self.headers = headers

            def getheaders(self):
                return list(self.headers)

            def read(self, amount):
                chunk = self.body[self.position : self.position + amount]
                self.position += len(chunk)
                return chunk

        class FakeConnection:
            def __init__(self, result):
                self.sock = None
                self.result = result

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return self.result

            def close(self):
                pass

        transport = DirectPublicTransport()
        cases = (
            FakeResponse(b"12345"),
            FakeResponse(b"", (("Content-Length", "9" * 5000),)),
            FakeResponse(
                b"",
                (("Content-Length", "0"), ("Transfer-Encoding", "chunked")),
            ),
        )
        for result in cases:
            fake_socket = FakeSocket()
            deadline_guard = SocketDeadlineGuard(time.monotonic() + 1.0, fake_socket)
            connection = FakeConnection(result)
            with self.subTest(headers=result.headers), mock.patch.object(
                transport,
                "_connected_socket",
                return_value=(fake_socket, "TLSv1.3", deadline_guard),
            ), mock.patch(
                "verify_public_edge.http.client.HTTPSConnection",
                return_value=connection,
            ):
                with self.assertRaises(VerificationError):
                    transport.request(
                        "https://api.pakperk.app",
                        "/health/ready",
                        secure=True,
                        maximum_body_bytes=4,
                    )

    def test_absolute_watchdog_stops_a_slow_drip(self) -> None:
        class DripSocket:
            def __init__(self):
                self.closed = False

            def settimeout(self, _timeout):
                pass

            def shutdown(self, _how):
                self.closed = True

            def close(self):
                self.closed = True

        class SlowResponse:
            status = 200

            def __init__(self, active_socket):
                self.active_socket = active_socket

            def getheaders(self):
                return []

            def read(self, _amount):
                time.sleep(0.005)
                if self.active_socket.closed:
                    raise OSError("closed by absolute deadline")
                return b"x"

        class FakeConnection:
            def __init__(self, result):
                self.sock = None
                self.result = result

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return self.result

            def close(self):
                pass

        transport = DirectPublicTransport()
        active_socket = DripSocket()
        guard = SocketDeadlineGuard(time.monotonic() + 0.04, active_socket)
        connection = FakeConnection(SlowResponse(active_socket))
        started = time.monotonic()
        with mock.patch.object(
            transport,
            "_connected_socket",
            return_value=(active_socket, "TLSv1.3", guard),
        ), mock.patch(
            "verify_public_edge.http.client.HTTPSConnection",
            return_value=connection,
        ):
            with self.assertRaisesRegex(VerificationError, "request_deadline_exceeded"):
                transport.request(
                    "https://api.pakperk.app",
                    "/health/ready",
                    secure=True,
                    maximum_body_bytes=1024 * 1024,
                )
        self.assertLess(time.monotonic() - started, 0.5)

    def test_tls_context_and_wrapper_are_fail_closed(self) -> None:
        transport = DirectPublicTransport()
        self.assertTrue(transport._tls_context.check_hostname)
        self.assertEqual(transport._tls_context.verify_mode, ssl.CERT_REQUIRED)
        self.assertGreaterEqual(
            transport._tls_context.minimum_version, ssl.TLSVersion.TLSv1_2
        )
        wrapper = (
            Path(__file__)
            .with_name("verify_public_edge.sh")
            .read_text(encoding="utf-8")
        )
        self.assertIn("set -euo pipefail", wrapper)
        self.assertIn('exec python3 "$script_dir/verify_public_edge.py" "$@"', wrapper)
        self.assertNotIn("curl", wrapper)
        verifier = (
            Path(__file__)
            .with_name("verify_public_edge.py")
            .read_text(encoding="utf-8")
        )
        self.assertIn("do_handshake_on_connect=False", verifier)
        self.assertIn("tls_socket.do_handshake()", verifier)

    def test_ambient_proxy_or_network_credentials_are_rejected_without_values(
        self,
    ) -> None:
        for name in (
            "HTTPS_PROXY",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "SSLKEYLOGFILE",
            "REQUESTS_CA_BUNDLE",
            "CURL_CA_BUNDLE",
        ):
            with self.subTest(name=name), mock.patch.dict(
                "os.environ",
                {name: "https://user:secret@proxy.invalid"},
                clear=True,
            ):
                with self.assertRaisesRegex(
                    Exception,
                    "ambient proxy or network-credential configuration is forbidden",
                ) as raised:
                    _reject_ambient_network_authority()
            self.assertNotIn("user:secret", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
