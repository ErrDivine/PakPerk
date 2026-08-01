#!/usr/bin/env python3
"""Verify Pakperk's public HTTPS edge and emit bounded technical evidence."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import socket
import ssl
import sys
import threading
import time
from typing import Mapping, Protocol, Sequence
import urllib.parse

from public_edge_evidence import (
    ENVIRONMENTS,
    SCENARIO_IDS,
    EvidenceError,
    PublicEdgeBinding,
    build_evidence,
    initial_scenario_state,
    observation_id,
    validate_oidc_issuer,
    write_evidence,
)


EXPECTED_HSTS = "max-age=63072000; includeSubDomains; preload"
EXPECTED_DEFAULT_CACHE = "no-cache, max-age=0, must-revalidate"
EXPECTED_CONFIG_CACHE = "no-store, max-age=0"
EXPECTED_DELETION_CACHE = "private, no-store, max-age=0"
EXPECTED_STATIC_SECURITY_HEADERS = {
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-resource-policy": "same-origin",
    "permissions-policy": "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
}

TOTAL_REQUEST_SECONDS = 10.0
DNS_SECONDS = 2.0
CONNECT_SECONDS = 4.0
MAX_HEADER_BYTES = 32 * 1024
MAX_HEADER_FIELDS = 64
MAX_HTML_BYTES = 256 * 1024
MAX_CONFIG_BYTES = 64 * 1024
MAX_ASSOCIATION_BYTES = 64 * 1024
MAX_HEALTH_BYTES = 16 * 1024
MAX_REDIRECT_BODY_BYTES = 16 * 1024
NOTICES_PREFIX_BYTES = 16 * 1024

SITE_HTML_ROUTES = (
    (
        "site_root_direct_https_headers_and_cache",
        "/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Pakperk — Policies and support</title>",
    ),
    (
        "privacy_route_direct_https_headers_and_cache",
        "/privacy/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Privacy notice — Pakperk</title>",
    ),
    (
        "terms_route_direct_https_headers_and_cache",
        "/terms/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Terms of use — Pakperk</title>",
    ),
    (
        "community_guidelines_route_direct_https_headers_and_cache",
        "/community-guidelines/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Community guidelines — Pakperk</title>",
    ),
    (
        "support_route_direct_https_headers_and_cache",
        "/support/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Support and safety — Pakperk</title>",
    ),
    (
        "account_deletion_route_direct_https_private_cache",
        "/account-deletion/",
        EXPECTED_DELETION_CACHE,
        "<title>Delete account — Pakperk</title>",
    ),
    (
        "open_source_licenses_route_direct_https_headers_and_cache",
        "/open-source-licenses/",
        EXPECTED_DEFAULT_CACHE,
        "<title>Open-source licenses — Pakperk</title>",
    ),
)

CONFIG_KEYS = (
    "environment",
    "publicOrigin",
    "apiBaseUrl",
    "oidcIssuer",
    "oidcClientId",
    "supportEmail",
    "documentVersion",
)
CONFIG_WRAPPER_RE = re.compile(
    r"\A\s*window\.__PAKPERK_PUBLIC_CONFIG__\s*=\s*Object\.freeze\(\{\s*"
    r"(?P<body>.*?)\s*\}\);\s*\Z",
    re.DOTALL,
)
CONFIG_LINE_RE = re.compile(
    r'^\s*([A-Za-z][A-Za-z0-9]*)\s*:\s*("(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*")\s*(,?)\s*$'
)
CONTENT_RANGE_RE = re.compile(r"bytes 0-([0-9]{1,5})/([1-9][0-9]{0,7})")
CONTENT_LENGTH_RE = re.compile(r"(?:0|[1-9][0-9]{0,7})")
MAX_NOTICES_TOTAL_BYTES = 16 * 1024 * 1024
MAX_RESPONSE_JSON_NESTING = 16
MAX_DNS_RESULTS = 64
MAX_PUBLIC_ADDRESSES = 16


class VerificationError(RuntimeError):
    """A fixed-category verification failure safe for logs and evidence."""

    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


@dataclass(frozen=True)
class HttpObservation:
    status: int
    headers: tuple[tuple[str, str], ...]
    body: bytes
    tls_version: str | None


class SocketDeadlineGuard:
    """Close an active socket at one absolute monotonic deadline."""

    def __init__(self, deadline: float, active_socket: socket.socket) -> None:
        self._lock = threading.Lock()
        self._active_socket: socket.socket | None = active_socket
        self._expired = False
        self._finished = False
        self._timer = threading.Timer(
            max(0.0, deadline - time.monotonic()), self._expire
        )
        self._timer.daemon = True
        self._timer.start()

    def _expire(self) -> None:
        active_socket: socket.socket | None
        with self._lock:
            if self._finished:
                return
            self._expired = True
            active_socket = self._active_socket
        if active_socket is not None:
            try:
                active_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                active_socket.close()
            except OSError:
                pass

    def attach(self, active_socket: socket.socket) -> None:
        close_immediately = False
        with self._lock:
            if self._expired or self._finished:
                close_immediately = True
            else:
                self._active_socket = active_socket
        if close_immediately:
            try:
                active_socket.close()
            finally:
                raise VerificationError("request_deadline_exceeded")

    @property
    def expired(self) -> bool:
        with self._lock:
            return self._expired

    def finish(self) -> bool:
        with self._lock:
            if self._expired:
                return False
            self._finished = True
            self._active_socket = None
        self._timer.cancel()
        return True


class Transport(Protocol):
    def request(
        self,
        origin: str,
        path: str,
        *,
        secure: bool,
        maximum_body_bytes: int,
        request_headers: Mapping[str, str] | None = None,
    ) -> HttpObservation: ...


class DirectPublicTransport:
    """Proxy-free, public-address-pinned HTTP transport with bounded reads."""

    def __init__(self) -> None:
        self._addresses: dict[str, tuple[tuple[int, str], ...]] = {}
        self._tls_context = ssl.create_default_context(purpose=ssl.Purpose.SERVER_AUTH)
        self._tls_context.check_hostname = True
        self._tls_context.verify_mode = ssl.CERT_REQUIRED
        self._tls_context.minimum_version = ssl.TLSVersion.TLSv1_2

    @staticmethod
    def _resolve_in_daemon(host: str) -> Sequence[tuple[int, int, int, str, tuple]]:
        result: queue.Queue[object] = queue.Queue(maxsize=1)

        def resolve() -> None:
            try:
                value: object = socket.getaddrinfo(
                    host,
                    None,
                    family=socket.AF_UNSPEC,
                    type=socket.SOCK_STREAM,
                    proto=socket.IPPROTO_TCP,
                )
            except Exception:
                value = None
            try:
                result.put_nowait(value)
            except queue.Full:
                pass

        threading.Thread(target=resolve, name="pakperk-public-dns", daemon=True).start()
        try:
            resolved = result.get(timeout=DNS_SECONDS)
        except queue.Empty as error:
            raise VerificationError("dns_timeout") from error
        if not isinstance(resolved, list) or len(resolved) > MAX_DNS_RESULTS:
            raise VerificationError("dns_resolution_failed")
        return resolved

    def _resolve_public(self, host: str) -> tuple[tuple[int, str], ...]:
        cached = self._addresses.get(host)
        if cached is not None:
            return cached
        addresses: list[tuple[int, str]] = []
        for (
            family,
            socket_type,
            protocol,
            _canonical,
            socket_address,
        ) in self._resolve_in_daemon(host):
            if socket_type != socket.SOCK_STREAM or protocol not in (
                0,
                socket.IPPROTO_TCP,
            ):
                continue
            if family not in (socket.AF_INET, socket.AF_INET6):
                continue
            address = socket_address[0]
            try:
                parsed = ipaddress.ip_address(address)
            except ValueError as error:
                raise VerificationError("dns_returned_invalid_address") from error
            mapped = (
                parsed.ipv4_mapped
                if isinstance(parsed, ipaddress.IPv6Address)
                else None
            )
            if (
                not parsed.is_global
                or parsed.is_multicast
                or parsed.is_unspecified
                or parsed.is_loopback
                or parsed.is_link_local
                or parsed.is_private
                or parsed.is_reserved
                or isinstance(parsed, ipaddress.IPv6Address)
                and parsed.is_site_local
                or isinstance(parsed, ipaddress.IPv6Address)
                and (
                    mapped is not None
                    or parsed.sixtofour is not None
                    or parsed.teredo is not None
                )
            ):
                raise VerificationError("dns_returned_non_public_address")
            item = (family, parsed.compressed)
            if item not in addresses:
                addresses.append(item)
                if len(addresses) > MAX_PUBLIC_ADDRESSES:
                    raise VerificationError("dns_returned_too_many_public_addresses")
        if not addresses:
            raise VerificationError("dns_returned_no_public_addresses")
        cached = tuple(addresses)
        self._addresses[host] = cached
        return cached

    @staticmethod
    def _remaining(deadline: float, maximum: float | None = None) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise VerificationError("request_deadline_exceeded")
        return remaining if maximum is None else min(remaining, maximum)

    def _connected_socket(
        self,
        host: str,
        port: int,
        secure: bool,
        deadline: float,
    ) -> tuple[socket.socket, str | None, SocketDeadlineGuard]:
        addresses = self._resolve_public(host)
        for family, address in addresses:
            raw_socket: socket.socket | None = None
            active_socket: socket.socket | None = None
            deadline_guard: SocketDeadlineGuard | None = None
            try:
                raw_socket = socket.socket(
                    family, socket.SOCK_STREAM, socket.IPPROTO_TCP
                )
                active_socket = raw_socket
                deadline_guard = SocketDeadlineGuard(deadline, raw_socket)
                raw_socket.settimeout(self._remaining(deadline, CONNECT_SECONDS))
                destination: tuple[object, ...]
                if family == socket.AF_INET6:
                    destination = (address, port, 0, 0)
                else:
                    destination = (address, port)
                raw_socket.connect(destination)
                if not secure:
                    return raw_socket, None, deadline_guard
                raw_socket.settimeout(self._remaining(deadline))
                tls_socket = self._tls_context.wrap_socket(
                    raw_socket,
                    server_hostname=host,
                    do_handshake_on_connect=False,
                )
                active_socket = tls_socket
                deadline_guard.attach(tls_socket)
                tls_socket.settimeout(self._remaining(deadline))
                tls_socket.do_handshake()
                negotiated = tls_socket.version()
                if negotiated not in {"TLSv1.2", "TLSv1.3"}:
                    tls_socket.close()
                    raise VerificationError("tls_version_below_boundary")
                return tls_socket, negotiated, deadline_guard
            except VerificationError:
                if deadline_guard is not None:
                    deadline_guard.finish()
                if active_socket is not None:
                    try:
                        active_socket.close()
                    except OSError:
                        pass
                raise
            except Exception:
                expired = deadline_guard is not None and deadline_guard.expired
                if deadline_guard is not None:
                    deadline_guard.finish()
                if active_socket is not None:
                    try:
                        active_socket.close()
                    except OSError:
                        pass
                if expired:
                    raise VerificationError("request_deadline_exceeded")
                if time.monotonic() >= deadline:
                    break
        raise VerificationError("connection_or_tls_failure")

    def request(
        self,
        origin: str,
        path: str,
        *,
        secure: bool,
        maximum_body_bytes: int,
        request_headers: Mapping[str, str] | None = None,
    ) -> HttpObservation:
        if not path.startswith("/") or "\r" in path or "\n" in path:
            raise VerificationError("unsafe_request_path")
        parsed = urllib.parse.urlsplit(origin)
        host = parsed.hostname
        if host is None:
            raise VerificationError("invalid_target_origin")
        port = 443 if secure else 80
        deadline = time.monotonic() + TOTAL_REQUEST_SECONDS
        connection: http.client.HTTPConnection | None = None
        network_socket: socket.socket | None = None
        deadline_guard: SocketDeadlineGuard | None = None
        try:
            network_socket, tls_version, deadline_guard = self._connected_socket(
                host, port, secure, deadline
            )
            network_socket.settimeout(self._remaining(deadline))
            connection_type = (
                http.client.HTTPSConnection if secure else http.client.HTTPConnection
            )
            if secure:
                connection = connection_type(
                    host,
                    port,
                    timeout=self._remaining(deadline),
                    context=self._tls_context,
                )
            else:
                connection = connection_type(
                    host,
                    port,
                    timeout=self._remaining(deadline),
                )
            connection.sock = network_socket
            headers = {
                "Accept": "*/*",
                "Accept-Encoding": "identity",
                "Cache-Control": "no-cache",
                "User-Agent": "Pakperk-Public-Edge-Verifier/1",
            }
            if request_headers:
                for name, value in request_headers.items():
                    if name.lower() in {
                        "authorization",
                        "cookie",
                        "proxy-authorization",
                    }:
                        raise VerificationError("ambient_auth_header_forbidden")
                    headers[name] = value
            connection.request("GET", path, headers=headers)
            network_socket.settimeout(self._remaining(deadline))
            response = connection.getresponse()
            raw_headers = tuple(
                (name.lower(), value) for name, value in response.getheaders()
            )
            header_size = sum(len(name) + len(value) + 4 for name, value in raw_headers)
            if len(raw_headers) > MAX_HEADER_FIELDS or header_size > MAX_HEADER_BYTES:
                raise VerificationError("response_headers_exceed_boundary")
            content_lengths = [
                value.strip() for name, value in raw_headers if name == "content-length"
            ]
            transfer_encodings = [
                value.strip().lower()
                for name, value in raw_headers
                if name == "transfer-encoding"
            ]
            if len(content_lengths) > 1:
                raise VerificationError("duplicate_content_length")
            if transfer_encodings and (
                transfer_encodings != ["chunked"] or content_lengths
            ):
                raise VerificationError("invalid_transfer_encoding_boundary")
            if content_lengths:
                if CONTENT_LENGTH_RE.fullmatch(content_lengths[0]) is None:
                    raise VerificationError("invalid_content_length")
                if int(content_lengths[0]) > maximum_body_bytes:
                    raise VerificationError("response_body_exceeds_boundary")
            body_parts: list[bytes] = []
            body_size = 0
            while True:
                network_socket.settimeout(self._remaining(deadline))
                chunk = response.read(min(8192, maximum_body_bytes + 1 - body_size))
                if not chunk:
                    break
                body_parts.append(chunk)
                body_size += len(chunk)
                if body_size > maximum_body_bytes:
                    raise VerificationError("response_body_exceeds_boundary")
            body = b"".join(body_parts)
            if content_lengths and int(content_lengths[0]) != len(body):
                raise VerificationError("response_body_length_mismatch")
            if time.monotonic() >= deadline or not deadline_guard.finish():
                raise VerificationError("request_deadline_exceeded")
            return HttpObservation(response.status, raw_headers, body, tls_version)
        except VerificationError:
            raise
        except Exception as error:
            if deadline_guard is not None and deadline_guard.expired:
                raise VerificationError("request_deadline_exceeded") from error
            raise VerificationError("http_transport_failure") from error
        finally:
            if deadline_guard is not None:
                deadline_guard.finish()
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass
            elif network_socket is not None:
                try:
                    network_socket.close()
                except OSError:
                    pass


def _header_values(response: HttpObservation, name: str) -> list[str]:
    return [
        value.strip() for header, value in response.headers if header.lower() == name
    ]


def _exact_header(response: HttpObservation, name: str, expected: str) -> None:
    if _header_values(response, name) != [expected]:
        raise VerificationError(f"invalid_{name.replace('-', '_')}_header")


def _absent_header(response: HttpObservation, name: str) -> None:
    if _header_values(response, name):
        raise VerificationError(f"forbidden_{name.replace('-', '_')}_header")


def _media_type(response: HttpObservation, expected: str) -> None:
    values = _header_values(response, "content-type")
    if len(values) != 1 or values[0].split(";", 1)[0].strip().lower() != expected:
        raise VerificationError("invalid_content_type_header")


def _common_direct_https(response: HttpObservation) -> None:
    if response.tls_version not in {"TLSv1.2", "TLSv1.3"}:
        raise VerificationError("tls_boundary_not_verified")
    _exact_header(response, "strict-transport-security", EXPECTED_HSTS)
    _absent_header(response, "location")
    _absent_header(response, "set-cookie")
    encodings = _header_values(response, "content-encoding")
    if encodings and encodings != ["identity"]:
        raise VerificationError("compressed_response_forbidden")


def _expected_csp(binding: PublicEdgeBinding) -> str:
    oidc_origin = urllib.parse.urlunsplit(
        ("https", urllib.parse.urlsplit(binding.oidc_issuer).hostname or "", "", "", "")
    )
    return (
        "default-src 'self'; base-uri 'none'; connect-src 'self' "
        f"{binding.api_origin} {oidc_origin}; font-src 'self'; form-action 'none'; "
        "frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; "
        "script-src 'self'; style-src 'self'; upgrade-insecure-requests"
    )


def _site_headers(
    response: HttpObservation,
    binding: PublicEdgeBinding,
    *,
    cache_control: str,
) -> None:
    _common_direct_https(response)
    _exact_header(response, "cache-control", cache_control)
    _exact_header(response, "content-security-policy", _expected_csp(binding))
    for name, expected in EXPECTED_STATIC_SECURITY_HEADERS.items():
        _exact_header(response, name, expected)


def _observation(
    scenario_id: str,
    path: str,
    response: HttpObservation,
    selected_headers: Sequence[str],
) -> str:
    headers = {name: _header_values(response, name) for name in selected_headers}
    return observation_id(
        {
            "scenario": scenario_id,
            "path": path,
            "status": response.status,
            "tls": response.tls_version or "cleartext",
            "headers": headers,
            "body_sha256": hashlib.sha256(response.body).hexdigest(),
        }
    )


def _parse_runtime_config(body: bytes) -> dict[str, str]:
    try:
        source = body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise VerificationError("runtime_config_not_utf8") from error
    wrapper = CONFIG_WRAPPER_RE.fullmatch(source)
    if wrapper is None:
        raise VerificationError("runtime_config_wrapper_invalid")
    parsed: dict[str, str] = {}
    lines = [line for line in wrapper.group("body").splitlines() if line.strip()]
    if len(lines) != len(CONFIG_KEYS):
        raise VerificationError("runtime_config_field_count_invalid")
    for index, (line, expected_key) in enumerate(zip(lines, CONFIG_KEYS, strict=True)):
        match = CONFIG_LINE_RE.fullmatch(line)
        if match is None or match.group(1) != expected_key:
            raise VerificationError("runtime_config_fields_invalid")
        if (index < len(CONFIG_KEYS) - 1) != (match.group(3) == ","):
            raise VerificationError("runtime_config_punctuation_invalid")
        try:
            value = json.loads(match.group(2))
        except json.JSONDecodeError as error:
            raise VerificationError("runtime_config_string_invalid") from error
        if not isinstance(value, str):
            raise VerificationError("runtime_config_value_invalid")
        parsed[expected_key] = value
    return parsed


def _verify_runtime_config(transport: Transport, binding: PublicEdgeBinding) -> str:
    path = "/config.js"
    response = transport.request(
        binding.site_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_CONFIG_BYTES,
    )
    if response.status != 200:
        raise VerificationError("runtime_config_not_direct_200")
    _site_headers(response, binding, cache_control=EXPECTED_CONFIG_CACHE)
    _media_type(response, "application/javascript")
    parsed = _parse_runtime_config(response.body)
    expected = {
        "environment": binding.target_environment,
        "publicOrigin": binding.site_origin,
        "apiBaseUrl": binding.api_origin,
        "oidcIssuer": binding.oidc_issuer,
        "oidcClientId": binding.oidc_client_id,
        "supportEmail": binding.support_email,
        "documentVersion": binding.document_version,
    }
    if parsed != expected:
        raise VerificationError("runtime_config_does_not_match_expected_binding")
    validate_oidc_issuer(parsed["oidcIssuer"])
    return _observation(
        SCENARIO_IDS[0],
        path,
        response,
        (
            "strict-transport-security",
            "cache-control",
            "content-security-policy",
            "content-type",
        ),
    )


def _verify_redirect(
    transport: Transport,
    binding: PublicEdgeBinding,
    scenario_id: str,
    origin: str,
    path: str,
) -> str:
    response = transport.request(
        origin,
        path,
        secure=False,
        maximum_body_bytes=MAX_REDIRECT_BODY_BYTES,
    )
    if response.status not in {301, 302, 307, 308}:
        raise VerificationError("http_endpoint_did_not_redirect")
    _exact_header(response, "location", f"{origin}{path}")
    _absent_header(response, "set-cookie")
    return _observation(scenario_id, path, response, ("location",))


def _verify_html_route(
    transport: Transport,
    binding: PublicEdgeBinding,
    scenario_id: str,
    path: str,
    cache_control: str,
    exact_title: str,
) -> str:
    response = transport.request(
        binding.site_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_HTML_BYTES,
    )
    if response.status != 200:
        raise VerificationError("public_site_route_not_direct_200")
    _site_headers(response, binding, cache_control=cache_control)
    _media_type(response, "text/html")
    try:
        html = response.body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise VerificationError("public_site_route_not_utf8") from error
    other_titles = {
        route_title
        for _route_scenario, _route_path, _route_cache, route_title in SITE_HTML_ROUTES
        if route_title != exact_title
    }
    if (
        html.count("<title>") != 1
        or html.count("</title>") != 1
        or html.count(exact_title) != 1
        or any(route_title in html for route_title in other_titles)
    ):
        raise VerificationError("public_site_route_marker_mismatch")
    if path == "/account-deletion/" and (
        html.count('id="confirm-deletion"') != 1
        or html.count('id="start-deletion"') != 1
    ):
        raise VerificationError("account_deletion_controls_missing")
    return _observation(
        scenario_id,
        path,
        response,
        (
            "strict-transport-security",
            "cache-control",
            "content-security-policy",
            "content-type",
        ),
    )


def _verify_notices_source_revision(
    transport: Transport, binding: PublicEdgeBinding
) -> str:
    scenario_id = "site_notices_source_revision_matches"
    path = "/open-source-licenses/notices.txt"
    response = transport.request(
        binding.site_origin,
        path,
        secure=True,
        maximum_body_bytes=NOTICES_PREFIX_BYTES,
        request_headers={"Range": f"bytes=0-{NOTICES_PREFIX_BYTES - 1}"},
    )
    if response.status not in {200, 206}:
        raise VerificationError("site_notices_prefix_not_direct_success")
    _site_headers(response, binding, cache_control=EXPECTED_DEFAULT_CACHE)
    _media_type(response, "text/plain")
    if response.status == 206:
        ranges = _header_values(response, "content-range")
        if len(ranges) != 1:
            raise VerificationError("site_notices_content_range_invalid")
        match = CONTENT_RANGE_RE.fullmatch(ranges[0])
        if (
            match is None
            or int(match.group(1)) != len(response.body) - 1
            or int(match.group(2)) <= len(response.body)
            or int(match.group(2)) > MAX_NOTICES_TOTAL_BYTES
        ):
            raise VerificationError("site_notices_content_range_invalid")
    elif _header_values(response, "content-range"):
        raise VerificationError("site_notices_unexpected_content_range")
    try:
        prefix = response.body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise VerificationError("site_notices_prefix_not_utf8") from error
    expected_header = (
        "Pakperk open-source dependency notices\n"
        "=======================================\n\n"
        f"Source revision: {binding.source_revision}\n"
    )
    revisions = re.findall(r"(?m)^Source revision: ([0-9a-f]{40})$", prefix)
    if not prefix.startswith(expected_header) or revisions != [binding.source_revision]:
        raise VerificationError("site_notices_source_revision_mismatch")
    return _observation(
        scenario_id,
        path,
        response,
        (
            "strict-transport-security",
            "cache-control",
            "content-type",
            "content-range",
        ),
    )


def _load_json_object(body: bytes, category: str) -> object:
    depth = 0
    in_string = False
    escaped = False
    for byte in body:
        if in_string:
            if escaped:
                escaped = False
            elif byte == ord("\\"):
                escaped = True
            elif byte == ord('"'):
                in_string = False
            continue
        if byte == ord('"'):
            in_string = True
        elif byte in (ord("{"), ord("[")):
            depth += 1
            if depth > MAX_RESPONSE_JSON_NESTING:
                raise VerificationError(category)
        elif byte in (ord("}"), ord("]")):
            depth -= 1

    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise VerificationError(category)
            result[key] = value
        return result

    def reject_constant(_value: str) -> object:
        raise VerificationError(category)

    try:
        return json.loads(
            body.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except VerificationError:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise VerificationError(category) from error


def _verify_android_association(
    transport: Transport, binding: PublicEdgeBinding
) -> str:
    scenario_id = "android_association_matches_release_identity"
    path = "/.well-known/assetlinks.json"
    response = transport.request(
        binding.site_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_ASSOCIATION_BYTES,
    )
    if response.status != 200:
        raise VerificationError("android_association_not_direct_200")
    _site_headers(response, binding, cache_control=EXPECTED_DEFAULT_CACHE)
    _media_type(response, "application/json")
    document = _load_json_object(response.body, "android_association_invalid_json")
    if not isinstance(document, list) or len(document) != 1:
        raise VerificationError("android_association_schema_invalid")
    statement = document[0]
    if not isinstance(statement, dict) or set(statement) != {"relation", "target"}:
        raise VerificationError("android_association_schema_invalid")
    target = statement.get("target")
    if (
        statement.get("relation") != ["delegate_permission/common.handle_all_urls"]
        or not isinstance(target, dict)
        or set(target) != {"namespace", "package_name", "sha256_cert_fingerprints"}
        or target.get("namespace") != "android_app"
        or target.get("package_name") != binding.android_package
    ):
        raise VerificationError("android_association_identity_mismatch")
    fingerprints = target.get("sha256_cert_fingerprints")
    if fingerprints != [binding.android_sha256]:
        raise VerificationError("android_association_fingerprints_mismatch")
    return _observation(
        scenario_id,
        path,
        response,
        (
            "strict-transport-security",
            "cache-control",
            "content-type",
        ),
    )


def _verify_apple_association(transport: Transport, binding: PublicEdgeBinding) -> str:
    scenario_id = "apple_association_matches_release_identity"
    path = "/.well-known/apple-app-site-association"
    response = transport.request(
        binding.site_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_ASSOCIATION_BYTES,
    )
    if response.status != 200:
        raise VerificationError("apple_association_not_direct_200")
    _site_headers(response, binding, cache_control=EXPECTED_DEFAULT_CACHE)
    _media_type(response, "application/json")
    document = _load_json_object(response.body, "apple_association_invalid_json")
    expected = {
        "applinks": {
            "details": [
                {
                    "appIDs": [f"{binding.apple_team_id}.{binding.apple_bundle_id}"],
                    "components": [{"/": "/p/*"}, {"/": "/arxiv/*"}],
                }
            ]
        }
    }
    if document != expected:
        raise VerificationError("apple_association_identity_mismatch")
    return _observation(
        scenario_id,
        path,
        response,
        (
            "strict-transport-security",
            "cache-control",
            "content-type",
        ),
    )


def _verify_api_readiness(transport: Transport, binding: PublicEdgeBinding) -> str:
    scenario_id = "api_readiness_contract_direct_https"
    path = "/health/ready"
    response = transport.request(
        binding.api_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_HEALTH_BYTES,
    )
    if response.status != 200:
        raise VerificationError("api_readiness_not_direct_200")
    _common_direct_https(response)
    _exact_header(response, "cache-control", "no-store")
    _media_type(response, "application/json")
    if _load_json_object(response.body, "api_readiness_invalid_json") != {
        "status": "ready"
    }:
        raise VerificationError("api_readiness_body_invalid")
    return _observation(
        scenario_id,
        path,
        response,
        ("strict-transport-security", "cache-control", "content-type"),
    )


def _verify_telemetry_readiness(
    transport: Transport, binding: PublicEdgeBinding
) -> str:
    scenario_id = "telemetry_process_readiness_direct_https"
    path = "/health/ready"
    response = transport.request(
        binding.telemetry_origin,
        path,
        secure=True,
        maximum_body_bytes=MAX_HEALTH_BYTES,
    )
    if response.status != 200:
        raise VerificationError("telemetry_process_readiness_not_direct_200")
    _common_direct_https(response)
    _exact_header(response, "cache-control", "no-store")
    _absent_header(response, "content-type")
    if response.body:
        raise VerificationError("telemetry_process_readiness_body_not_empty")
    return _observation(
        scenario_id,
        path,
        response,
        ("strict-transport-security", "cache-control", "content-type"),
    )


def run_verification(
    binding: PublicEdgeBinding,
    transport: Transport,
) -> tuple[str, dict[str, dict[str, str]], str | None]:
    binding.validate()
    state = initial_scenario_state()
    checks = [
        (
            "runtime_config_exact_public_binding",
            lambda: _verify_runtime_config(transport, binding),
        ),
        (
            "site_http_redirects_exactly_to_https",
            lambda: _verify_redirect(
                transport,
                binding,
                "site_http_redirects_exactly_to_https",
                binding.site_origin,
                "/",
            ),
        ),
        (
            "api_http_redirects_exactly_to_https",
            lambda: _verify_redirect(
                transport,
                binding,
                "api_http_redirects_exactly_to_https",
                binding.api_origin,
                "/health/ready",
            ),
        ),
        (
            "telemetry_http_redirects_exactly_to_https",
            lambda: _verify_redirect(
                transport,
                binding,
                "telemetry_http_redirects_exactly_to_https",
                binding.telemetry_origin,
                "/health/ready",
            ),
        ),
    ]
    checks.extend(
        (
            scenario_id,
            lambda scenario_id=scenario_id, path=path, cache=cache, title=title: _verify_html_route(
                transport, binding, scenario_id, path, cache, title
            ),
        )
        for scenario_id, path, cache, title in SITE_HTML_ROUTES
    )
    checks.extend(
        [
            (
                "site_notices_source_revision_matches",
                lambda: _verify_notices_source_revision(transport, binding),
            ),
            (
                "android_association_matches_release_identity",
                lambda: _verify_android_association(transport, binding),
            ),
            (
                "apple_association_matches_release_identity",
                lambda: _verify_apple_association(transport, binding),
            ),
            (
                "api_readiness_contract_direct_https",
                lambda: _verify_api_readiness(transport, binding),
            ),
            (
                "telemetry_process_readiness_direct_https",
                lambda: _verify_telemetry_readiness(transport, binding),
            ),
        ]
    )
    if tuple(scenario_id for scenario_id, _check in checks) != SCENARIO_IDS:
        raise EvidenceError(
            "verifier scenario implementation does not match evidence schema"
        )

    for scenario_id, check in checks:
        try:
            digest = check()
        except VerificationError as error:
            state[scenario_id] = {"outcome": "failed", "observation_id": "not_observed"}
            return "failed", state, error.category
        state[scenario_id] = {"outcome": "passed", "observation_id": digest}
    return "passed", state, None


def _binding_from_args(arguments: argparse.Namespace) -> PublicEdgeBinding:
    return PublicEdgeBinding(
        source_revision=arguments.source_revision,
        target_environment=arguments.environment,
        requested_candidate_id=arguments.candidate_id,
        site_origin=arguments.site_origin,
        api_origin=arguments.api_origin,
        telemetry_origin=arguments.telemetry_origin,
        document_version=arguments.document_version,
        oidc_issuer=arguments.oidc_issuer,
        oidc_client_id=arguments.oidc_client_id,
        support_email=arguments.support_email,
        android_package=arguments.android_package,
        android_sha256=arguments.android_sha256,
        apple_team_id=arguments.apple_team_id,
        apple_bundle_id=arguments.apple_bundle_id,
    ).validate()


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site_origin", metavar="SITE_ORIGIN")
    parser.add_argument("api_origin", metavar="API_ORIGIN")
    parser.add_argument("telemetry_origin", metavar="TELEMETRY_ORIGIN")
    parser.add_argument("--evidence-output", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--environment", required=True, choices=ENVIRONMENTS)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--document-version", required=True)
    parser.add_argument("--oidc-issuer", required=True)
    parser.add_argument("--oidc-client-id", required=True)
    parser.add_argument("--support-email", required=True)
    parser.add_argument("--android-package", required=True)
    parser.add_argument("--android-sha256", required=True)
    parser.add_argument("--apple-team-id", required=True)
    parser.add_argument("--apple-bundle-id", required=True)
    return parser.parse_args(argv)


def _reject_ambient_network_authority() -> None:
    forbidden = {
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
        "curl_home",
        "netrc",
        "ssl_cert_file",
        "ssl_cert_dir",
        "sslkeylogfile",
        "requests_ca_bundle",
        "curl_ca_bundle",
    }
    present = sorted(name for name in os.environ if name.lower() in forbidden)
    if present:
        # Names and values are deliberately omitted: proxy URLs can contain
        # credentials, and environment capitalization is immaterial.
        raise EvidenceError(
            "ambient proxy or network-credential configuration is forbidden"
        )


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        binding = _binding_from_args(arguments)
        if not arguments.evidence_output.is_absolute():
            raise EvidenceError("evidence output path must be absolute")
        _reject_ambient_network_authority()
    except EvidenceError as error:
        print(f"public-edge verifier configuration failed: {error}", file=sys.stderr)
        return 2

    outcome, state, failure_category = run_verification(
        binding, DirectPublicTransport()
    )
    try:
        evidence = build_evidence(binding, state, outcome)
        write_evidence(arguments.evidence_output, evidence, binding)
    except EvidenceError as error:
        print(f"public-edge evidence emission failed: {error}", file=sys.stderr)
        return 2
    if outcome == "failed":
        print(
            "Public-edge technical verification failed "
            f"({failure_category or 'closed_failure'}); sanitized evidence was emitted.",
            file=sys.stderr,
        )
        return 1
    print(
        f"Verified {len(SCENARIO_IDS)} bounded public-edge technical scenarios; "
        "sanitized evidence was emitted."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
