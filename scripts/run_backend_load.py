#!/usr/bin/env python3
"""Bounded, content-redacted Pakperk backend staging load gate."""

from __future__ import annotations

import argparse
from collections import Counter
import concurrent.futures
from dataclasses import dataclass, field
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import sys
import threading
import time
from typing import Any, Callable, Iterable
from urllib.parse import urlencode, urlparse
import uuid


SCENARIO_ORDER = (
    "feed",
    "metadata",
    "library",
    "comments",
    "library_mutation",
)
DEFAULT_WEIGHTS = {
    "feed": 1,
    "metadata": 4,
    "library": 1,
    "comments": 1,
    "library_mutation": 1,
}
DEFAULT_THRESHOLDS = {
    "feed": (250.0, 500.0, 1_000.0, 0.01),
    "metadata": (125.0, 250.0, 500.0, 0.01),
    "library": (250.0, 500.0, 1_000.0, 0.01),
    "comments": (350.0, 700.0, 1_400.0, 0.01),
    "library_mutation": (250.0, 500.0, 1_000.0, 0.01),
}
EVIDENCE_ID = re.compile(r"[A-Za-z0-9._:/-]{1,128}")
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
CATEGORY = re.compile(r"[A-Za-z0-9.-]{1,64}")


class ConfigurationError(RuntimeError):
    """A safe-to-print configuration failure."""


class LoadError(RuntimeError):
    """A safe-to-print bounded preflight failure."""


class ProtocolError(RuntimeError):
    """A response violated the expected bounded JSON envelope."""


@dataclass(frozen=True)
class Threshold:
    p50_ms: float
    p95_ms: float
    p99_ms: float
    maximum_error_rate: float


@dataclass(frozen=True)
class Config:
    origin: str
    scheme: str
    host: str
    port: int
    environment: str
    output: Path
    evidence_id: str
    source_revision: str
    duration_seconds: float
    concurrency: int
    maximum_requests: int
    request_timeout_seconds: float
    preflight_timeout_seconds: float
    simulated_network_delay_ms: float
    simulated_packet_loss_rate: float
    maximum_response_bytes: int
    minimum_paper_records: int
    feed_page_size: int
    maximum_bootstrap_pages: int
    minimum_samples_per_scenario: int
    warmup_per_worker: int
    category: str | None
    bearer_token: str | None = field(repr=False)
    include_library: bool = False
    comments_paper_id: str | None = None
    allow_library_mutations: bool = False
    library_mutation_paper_id: str | None = None
    maximum_library_mutation_requests: int = 0
    maximum_library_snapshot_pages: int = 0
    weights: dict[str, int] = field(default_factory=dict)
    thresholds: dict[str, Threshold] = field(default_factory=dict)

    @property
    def enabled_scenarios(self) -> tuple[str, ...]:
        enabled = ["feed", "metadata"]
        if self.include_library:
            enabled.append("library")
        if self.comments_paper_id is not None:
            enabled.append("comments")
        if self.allow_library_mutations:
            enabled.append("library_mutation")
        return tuple(enabled)


@dataclass(frozen=True)
class HttpResult:
    status: int | None
    body: bytes
    latency_us: int
    error_class: str | None
    content_type: str | None


@dataclass(frozen=True)
class Measurement:
    scenario: str
    latency_us: int
    success: bool
    error_class: str | None = None


def bounded_float(name: str, value: str, minimum: float, maximum: float) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{name} must be numeric") from error
    if not math.isfinite(parsed) or not minimum <= parsed <= maximum:
        raise argparse.ArgumentTypeError(
            f"{name} must be between {minimum:g} and {maximum:g}"
        )
    return parsed


def positive_int(name: str, value: str, maximum: int) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{name} must be an integer") from error
    if not 1 <= parsed <= maximum:
        raise argparse.ArgumentTypeError(f"{name} must be between 1 and {maximum}")
    return parsed


def parse_mapping(
    raw_values: Iterable[str],
    defaults: dict[str, Any],
    parser: Callable[[str, str], Any],
) -> dict[str, Any]:
    values = dict(defaults)
    for raw in raw_values:
        name, separator, value = raw.partition("=")
        if not separator or name not in SCENARIO_ORDER:
            raise ConfigurationError(
                "scenario overrides must use a known name followed by `=`"
            )
        values[name] = parser(name, value)
    return values


def parse_weight(name: str, value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise ConfigurationError(f"{name} weight must be an integer") from error
    if not 1 <= parsed <= 100:
        raise ConfigurationError(f"{name} weight must be between 1 and 100")
    return parsed


def parse_threshold(name: str, value: str) -> Threshold:
    parts = value.split(",")
    if len(parts) != 4:
        raise ConfigurationError(
            f"{name} threshold must be p50_ms,p95_ms,p99_ms,error_rate"
        )
    try:
        p50, p95, p99, error_rate = map(float, parts)
    except ValueError as error:
        raise ConfigurationError(f"{name} threshold values must be numeric") from error
    if (
        not all(math.isfinite(value) for value in (p50, p95, p99, error_rate))
        or not 1.0 <= p50 <= p95 <= p99 <= 60_000.0
        or not 0.0 <= error_rate <= 1.0
    ):
        raise ConfigurationError(
            f"{name} threshold must have 1 <= p50 <= p95 <= p99 <= 60000 and 0 <= error_rate <= 1"
        )
    return Threshold(p50, p95, p99, error_rate)


def validated_origin(
    value: str, environment: str, allow_loopback_http: bool
) -> tuple[str, str, int]:
    parsed = urlparse(value)
    if (
        parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
        or parsed.hostname is None
    ):
        raise ConfigurationError(
            "API origin must be a credential-free origin without a path"
        )
    is_loopback = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if environment == "staging" and parsed.scheme != "https":
        raise ConfigurationError("staging load tests require an HTTPS API origin")
    if parsed.scheme == "http" and not (
        environment == "development" and allow_loopback_http and is_loopback
    ):
        raise ConfigurationError(
            "HTTP is allowed only for an explicit development loopback test"
        )
    if parsed.scheme not in {"http", "https"}:
        raise ConfigurationError("API origin must use HTTP or HTTPS")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as error:
        raise ConfigurationError("API origin has an invalid port") from error
    return parsed.scheme, parsed.hostname, port


def read_bearer_token(path: Path | None) -> str | None:
    if path is None:
        return None
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        raise ConfigurationError("bearer-token file is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_mode & 0o077
        or (hasattr(os, "geteuid") and metadata.st_uid != os.geteuid())
    ):
        os.close(descriptor)
        raise ConfigurationError("bearer-token file must be a regular owner-only file")
    if not 16 <= metadata.st_size <= 64 * 1024:
        os.close(descriptor)
        raise ConfigurationError("bearer-token file has an invalid size")
    try:
        with os.fdopen(descriptor, "r", encoding="utf-8") as token_file:
            descriptor = None
            raw = token_file.read(64 * 1024 + 1)
    except (OSError, UnicodeError) as error:
        raise ConfigurationError("bearer-token file is not valid UTF-8") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    token = raw.rstrip("\r\n")
    try:
        token_bytes = token.encode("ascii")
    except UnicodeEncodeError as error:
        raise ConfigurationError(
            "bearer-token file contains invalid token bytes"
        ) from error
    if (
        raw not in {token, token + "\n", token + "\r\n"}
        or not 16 <= len(token_bytes) <= 64 * 1024
        or any(byte < 0x21 or byte > 0x7E for byte in token_bytes)
    ):
        raise ConfigurationError("bearer-token file contains invalid token bytes")
    return token


def parse_config(argv: list[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-origin", required=True)
    parser.add_argument(
        "--environment", choices=("staging", "development"), default="staging"
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-id", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--duration-seconds", default="60")
    parser.add_argument("--concurrency", default="8")
    parser.add_argument("--max-requests", default="10000")
    parser.add_argument("--request-timeout-seconds", default="5")
    parser.add_argument("--preflight-timeout-seconds", default="60")
    parser.add_argument("--simulated-network-delay-ms", default="0")
    parser.add_argument("--simulated-packet-loss-rate", default="0")
    parser.add_argument("--max-response-bytes", default=str(2 * 1024 * 1024))
    parser.add_argument("--minimum-paper-records", default="200")
    parser.add_argument("--feed-page-size", default="100")
    parser.add_argument("--max-bootstrap-pages", default="100")
    parser.add_argument("--minimum-samples-per-scenario", default="20")
    parser.add_argument("--warmup-per-worker", default="1")
    parser.add_argument("--category")
    parser.add_argument("--bearer-token-file", type=Path)
    parser.add_argument("--include-library", action="store_true")
    parser.add_argument("--comments-paper-id")
    parser.add_argument("--allow-library-mutations", action="store_true")
    parser.add_argument("--library-mutation-paper-id")
    parser.add_argument("--max-library-mutation-requests", default="20")
    parser.add_argument("--max-library-snapshot-pages", default="100")
    parser.add_argument(
        "--scenario-weight",
        action="append",
        default=[],
        metavar="NAME=WEIGHT",
    )
    parser.add_argument(
        "--threshold",
        action="append",
        default=[],
        metavar="NAME=P50_MS,P95_MS,P99_MS,ERROR_RATE",
    )
    parser.add_argument(
        "--allow-loopback-http",
        action="store_true",
        help="Allow only a development loopback mock/local target; never valid for staging evidence.",
    )
    arguments = parser.parse_args(argv)

    if not EVIDENCE_ID.fullmatch(arguments.evidence_id):
        raise ConfigurationError("evidence ID is invalid")
    if not SOURCE_REVISION.fullmatch(arguments.source_revision):
        raise ConfigurationError("source revision must be a full lowercase commit SHA")
    if arguments.category is not None and not CATEGORY.fullmatch(arguments.category):
        raise ConfigurationError("category is invalid")
    scheme, host, port = validated_origin(
        arguments.api_origin, arguments.environment, arguments.allow_loopback_http
    )
    bearer_token = read_bearer_token(arguments.bearer_token_file)
    if arguments.include_library and bearer_token is None:
        raise ConfigurationError("library load requires a bearer-token file")
    comments_paper_id = (
        checked_uuid(arguments.comments_paper_id, "comments paper ID")
        if arguments.comments_paper_id
        else None
    )
    mutation_paper_id = (
        checked_uuid(arguments.library_mutation_paper_id, "library mutation paper ID")
        if arguments.library_mutation_paper_id
        else None
    )
    if arguments.allow_library_mutations != (mutation_paper_id is not None):
        raise ConfigurationError(
            "library mutations require both --allow-library-mutations and --library-mutation-paper-id"
        )
    if arguments.allow_library_mutations and bearer_token is None:
        raise ConfigurationError("library mutations require a bearer-token file")

    weights = parse_mapping(arguments.scenario_weight, DEFAULT_WEIGHTS, parse_weight)
    default_thresholds = {
        name: Threshold(*values) for name, values in DEFAULT_THRESHOLDS.items()
    }
    thresholds = parse_mapping(arguments.threshold, default_thresholds, parse_threshold)
    duration = bounded_float("duration", arguments.duration_seconds, 0.1, 3_600.0)
    concurrency = positive_int("concurrency", arguments.concurrency, 64)
    maximum_requests = positive_int("max requests", arguments.max_requests, 100_000)
    timeout = bounded_float(
        "request timeout", arguments.request_timeout_seconds, 0.1, 30.0
    )
    preflight_timeout = bounded_float(
        "preflight timeout", arguments.preflight_timeout_seconds, 1.0, 300.0
    )
    simulated_network_delay_ms = bounded_float(
        "simulated network delay",
        arguments.simulated_network_delay_ms,
        0.0,
        5_000.0,
    )
    simulated_packet_loss_rate = bounded_float(
        "simulated packet loss rate",
        arguments.simulated_packet_loss_rate,
        0.0,
        1.0,
    )
    maximum_response_bytes = positive_int(
        "max response bytes", arguments.max_response_bytes, 8 * 1024 * 1024
    )
    if maximum_response_bytes < 1_024:
        raise ConfigurationError("max response bytes must be at least 1024")
    minimum_records = positive_int(
        "minimum paper records", arguments.minimum_paper_records, 10_000
    )
    feed_page_size = positive_int("feed page size", arguments.feed_page_size, 100)
    bootstrap_pages = positive_int(
        "max bootstrap pages", arguments.max_bootstrap_pages, 1_000
    )
    minimum_samples = positive_int(
        "minimum samples per scenario",
        arguments.minimum_samples_per_scenario,
        100_000,
    )
    warmup_per_worker = positive_int(
        "warmup per worker", arguments.warmup_per_worker, 10
    )
    maximum_mutations = positive_int(
        "max library mutation requests",
        arguments.max_library_mutation_requests,
        100,
    )
    snapshot_pages = positive_int(
        "max library snapshot pages", arguments.max_library_snapshot_pages, 1_000
    )

    enabled_count = (
        2
        + int(arguments.include_library)
        + int(comments_paper_id is not None)
        + int(arguments.allow_library_mutations)
    )
    if maximum_requests < enabled_count * minimum_samples:
        raise ConfigurationError(
            "max requests is smaller than the enabled-scenario sample floor"
        )
    if arguments.allow_library_mutations and maximum_mutations < minimum_samples:
        raise ConfigurationError(
            "max library mutation requests is smaller than the scenario sample floor"
        )
    if os.path.lexists(arguments.output):
        raise ConfigurationError("evidence output already exists")
    if not arguments.output.parent.is_dir():
        raise ConfigurationError("evidence output parent directory is unavailable")

    return Config(
        origin=arguments.api_origin.rstrip("/"),
        scheme=scheme,
        host=host,
        port=port,
        environment=arguments.environment,
        output=arguments.output,
        evidence_id=arguments.evidence_id,
        source_revision=arguments.source_revision,
        duration_seconds=duration,
        concurrency=concurrency,
        maximum_requests=maximum_requests,
        request_timeout_seconds=timeout,
        preflight_timeout_seconds=preflight_timeout,
        simulated_network_delay_ms=simulated_network_delay_ms,
        simulated_packet_loss_rate=simulated_packet_loss_rate,
        maximum_response_bytes=maximum_response_bytes,
        minimum_paper_records=minimum_records,
        feed_page_size=feed_page_size,
        maximum_bootstrap_pages=bootstrap_pages,
        minimum_samples_per_scenario=minimum_samples,
        warmup_per_worker=warmup_per_worker,
        category=arguments.category,
        bearer_token=bearer_token,
        include_library=arguments.include_library,
        comments_paper_id=comments_paper_id,
        allow_library_mutations=arguments.allow_library_mutations,
        library_mutation_paper_id=mutation_paper_id,
        maximum_library_mutation_requests=maximum_mutations,
        maximum_library_snapshot_pages=snapshot_pages,
        weights=weights,
        thresholds=thresholds,
    )


def checked_uuid(value: str, name: str) -> str:
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise ConfigurationError(f"{name} must be a UUID") from error


class HttpClient:
    def __init__(self, config: Config):
        self.config = config
        self.local = threading.local()
        self.ssl_context = ssl.create_default_context()

    def _connection(self) -> http.client.HTTPConnection:
        connection = getattr(self.local, "connection", None)
        if connection is None:
            if self.config.scheme == "https":
                connection = http.client.HTTPSConnection(
                    self.config.host,
                    self.config.port,
                    timeout=self.config.request_timeout_seconds,
                    context=self.ssl_context,
                )
            else:
                connection = http.client.HTTPConnection(
                    self.config.host,
                    self.config.port,
                    timeout=self.config.request_timeout_seconds,
                )
            self.local.connection = connection
        return connection

    def close_thread(self) -> None:
        connection = getattr(self.local, "connection", None)
        if connection is not None:
            connection.close()
            self.local.connection = None

    def request(
        self,
        method: str,
        path: str,
        token: str | None = None,
        json_body: dict[str, Any] | None = None,
        extra_headers: dict[str, str] | None = None,
    ) -> HttpResult:
        if not path.startswith("/") or "\r" in path or "\n" in path:
            return HttpResult(None, b"", 0, "client_protocol", None)
        body = None
        headers = {
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "User-Agent": "PakperkStagingLoad/0.1",
        }
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if json_body is not None:
            body = json.dumps(json_body, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
            headers["Content-Type"] = "application/json"
        if extra_headers:
            headers.update(extra_headers)
        started = time.perf_counter_ns()
        try:
            connection = self._connection()
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            content_type = response.getheader("Content-Type")
            content_length = response.getheader("Content-Length")
            if content_length is not None:
                try:
                    declared_length = int(content_length)
                except ValueError:
                    self.close_thread()
                    return HttpResult(
                        response.status,
                        b"",
                        elapsed_us(started),
                        "protocol",
                        content_type,
                    )
                if (
                    declared_length < 0
                    or declared_length > self.config.maximum_response_bytes
                ):
                    self.close_thread()
                    return HttpResult(
                        response.status,
                        b"",
                        elapsed_us(started),
                        "oversized",
                        content_type,
                    )
            response_body = response.read(self.config.maximum_response_bytes + 1)
            if len(response_body) > self.config.maximum_response_bytes:
                self.close_thread()
                return HttpResult(
                    response.status,
                    b"",
                    elapsed_us(started),
                    "oversized",
                    content_type,
                )
            if response.will_close:
                self.close_thread()
            return HttpResult(
                response.status,
                response_body,
                elapsed_us(started),
                None,
                content_type,
            )
        except (TimeoutError, socket.timeout):
            self.close_thread()
            return HttpResult(None, b"", elapsed_us(started), "timeout", None)
        except ssl.SSLError:
            self.close_thread()
            return HttpResult(None, b"", elapsed_us(started), "tls", None)
        except (http.client.HTTPException, OSError):
            self.close_thread()
            return HttpResult(None, b"", elapsed_us(started), "network", None)


def elapsed_us(started_ns: int) -> int:
    return max(0, (time.perf_counter_ns() - started_ns) // 1_000)


def error_for_status(status: int) -> str:
    if 300 <= status < 400:
        return "http_3xx"
    if 400 <= status < 500:
        return "http_4xx"
    if 500 <= status < 600:
        return "http_5xx"
    return "unexpected_status"


def json_object(body: bytes) -> dict[str, Any]:
    try:
        value = json.loads(body)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ProtocolError("response was not a JSON object") from error
    if not isinstance(value, dict):
        raise ProtocolError("response was not a JSON object")
    return value


def require_json_content_type(content_type: str | None) -> None:
    if (
        content_type is None
        or content_type.split(";", 1)[0].strip().lower() != "application/json"
    ):
        raise ProtocolError("response did not use application/json")


def validate_feed(value: dict[str, Any]) -> None:
    items = value.get("items")
    cursor = value.get("next_cursor")
    if (
        not isinstance(items, list)
        or not (cursor is None or isinstance(cursor, str) and 1 <= len(cursor) <= 512)
        or any(
            not isinstance(item, dict) or not isinstance(item.get("paper_id"), str)
            for item in items
        )
    ):
        raise ProtocolError("feed response shape was invalid")
    try:
        for item in items:
            uuid.UUID(item["paper_id"])
    except ValueError as error:
        raise ProtocolError("feed response shape was invalid") from error


def validate_metadata(value: dict[str, Any], expected_paper_id: str) -> None:
    paper_id = value.get("paper_id")
    if not isinstance(paper_id, str) or paper_id != expected_paper_id:
        raise ProtocolError("metadata response shape was invalid")
    try:
        uuid.UUID(paper_id)
    except ValueError as error:
        raise ProtocolError("metadata response shape was invalid") from error


def validate_library(value: dict[str, Any]) -> None:
    items = value.get("items")
    cursor = value.get("next_cursor")
    if (
        not isinstance(items, list)
        or any(not isinstance(item, dict) for item in items)
        or not (cursor is None or isinstance(cursor, str) and 1 <= len(cursor) <= 512)
    ):
        raise ProtocolError("library response shape was invalid")


def validate_comments(value: dict[str, Any]) -> None:
    items = value.get("items")
    cursor = value.get("next_cursor")
    if (
        not isinstance(items, list)
        or any(not isinstance(item, dict) for item in items)
        or not (cursor is None or isinstance(cursor, str) and 1 <= len(cursor) <= 512)
    ):
        raise ProtocolError("comments response shape was invalid")


def validate_mutation(
    value: dict[str, Any], expected_removed: bool, expected_paper_id: str
) -> None:
    item = value.get("item")
    if (
        not isinstance(item, dict)
        or item.get("removed") is not expected_removed
        or not isinstance(item.get("paper_id"), str)
        or item.get("paper_id") != expected_paper_id
    ):
        raise ProtocolError("library mutation response shape was invalid")
    try:
        uuid.UUID(item["paper_id"])
    except ValueError as error:
        raise ProtocolError("library mutation response shape was invalid") from error


def measure(
    client: HttpClient,
    scenario: str,
    method: str,
    path: str,
    token: str | None,
    validator: Callable[[dict[str, Any]], None],
    json_body: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
) -> Measurement:
    result = client.request(method, path, token, json_body, extra_headers)
    if result.error_class is not None:
        return Measurement(scenario, result.latency_us, False, result.error_class)
    if result.status != 200:
        return Measurement(
            scenario,
            result.latency_us,
            False,
            error_for_status(result.status or 0),
        )
    try:
        require_json_content_type(result.content_type)
        validator(json_object(result.body))
    except ProtocolError:
        return Measurement(scenario, result.latency_us, False, "protocol")
    return Measurement(scenario, result.latency_us, True)


def feed_path(config: Config, cursor: str | None = None) -> str:
    query: dict[str, str | int] = {"limit": config.feed_page_size}
    if config.category is not None:
        query["category"] = config.category
    if cursor is not None:
        query["cursor"] = cursor
    return "/v1/feed?" + urlencode(query)


def preflight_json(
    client: HttpClient,
    method: str,
    path: str,
    operation: str,
    token: str | None = None,
    json_body: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
    deadline: float | None = None,
) -> dict[str, Any]:
    if deadline is not None and time.monotonic() >= deadline:
        raise LoadError(f"{operation} exceeded the preflight deadline")
    result = client.request(method, path, token, json_body, extra_headers)
    if result.error_class is not None or result.status != 200:
        raise LoadError(f"{operation} failed")
    try:
        require_json_content_type(result.content_type)
        return json_object(result.body)
    except ProtocolError as error:
        raise LoadError(f"{operation} returned an invalid response") from error


def bootstrap_feed(
    config: Config, client: HttpClient, deadline: float
) -> tuple[list[str], list[str]]:
    paths: list[str] = []
    paper_ids: list[str] = []
    known_papers: set[str] = set()
    known_cursors: set[str] = set()
    cursor = None
    for _ in range(config.maximum_bootstrap_pages):
        path = feed_path(config, cursor)
        page = preflight_json(client, "GET", path, "feed bootstrap", deadline=deadline)
        try:
            validate_feed(page)
        except ProtocolError as error:
            raise LoadError("feed bootstrap returned an invalid response") from error
        paths.append(path)
        for item in page["items"]:
            if not isinstance(item, dict) or not isinstance(item.get("paper_id"), str):
                raise LoadError("feed bootstrap returned an invalid paper summary")
            try:
                paper_id = str(uuid.UUID(item["paper_id"]))
            except ValueError as error:
                raise LoadError(
                    "feed bootstrap returned an invalid paper identifier"
                ) from error
            if paper_id not in known_papers:
                known_papers.add(paper_id)
                paper_ids.append(paper_id)
        if len(paper_ids) >= config.minimum_paper_records:
            break
        next_cursor = page.get("next_cursor")
        if next_cursor is None:
            break
        if (
            not isinstance(next_cursor, str)
            or not 1 <= len(next_cursor) <= 512
            or next_cursor in known_cursors
        ):
            raise LoadError("feed bootstrap cursor was invalid or repeated")
        known_cursors.add(next_cursor)
        cursor = next_cursor
    if len(paper_ids) < config.minimum_paper_records:
        raise LoadError("feed bootstrap found fewer papers than the configured minimum")
    return paths, paper_ids


def assert_mutation_target_absent(
    config: Config, client: HttpClient, deadline: float
) -> None:
    target = config.library_mutation_paper_id
    if target is None or config.bearer_token is None:
        return
    cursor = None
    seen: set[str] = set()
    for _ in range(config.maximum_library_snapshot_pages):
        query: dict[str, str | int] = {"state": "to_read", "limit": 100}
        if cursor is not None:
            query["cursor"] = cursor
        page = preflight_json(
            client,
            "GET",
            "/v1/me/library?" + urlencode(query),
            "library mutation preflight",
            config.bearer_token,
            deadline=deadline,
        )
        try:
            validate_library(page)
        except ProtocolError as error:
            raise LoadError(
                "library mutation preflight returned an invalid response"
            ) from error
        for entry in page["items"]:
            item = entry.get("item") if isinstance(entry, dict) else None
            if isinstance(item, dict) and item.get("paper_id") == target:
                raise LoadError(
                    "library mutation target is already saved; use a dedicated absent staging fixture"
                )
        next_cursor = page.get("next_cursor")
        if next_cursor is None:
            return
        if (
            not isinstance(next_cursor, str)
            or not 1 <= len(next_cursor) <= 512
            or next_cursor in seen
        ):
            raise LoadError("library mutation preflight cursor was invalid or repeated")
        seen.add(next_cursor)
        cursor = next_cursor
    raise LoadError(
        "library mutation preflight did not exhaust the bounded account library"
    )


class Workload:
    def __init__(self, config: Config, feed_paths: list[str], paper_ids: list[str]):
        self.config = config
        self.feed_paths = feed_paths
        self.paper_ids = paper_ids
        self.mutation_lock = threading.Lock()
        self.mutation_saved = False

    @property
    def weighted_scenarios(self) -> tuple[str, ...]:
        values: list[str] = []
        enabled = set(self.config.enabled_scenarios)
        for name in SCENARIO_ORDER:
            if name in enabled:
                values.extend([name] * self.config.weights[name])
        return tuple(values)

    @property
    def warmup_scenarios(self) -> tuple[str, ...]:
        return tuple(
            name for name in self.config.enabled_scenarios if name != "library_mutation"
        )

    def try_acquire_mutation_slot(self) -> bool:
        return self.mutation_lock.acquire(blocking=False)

    def execute(
        self,
        client: HttpClient,
        scenario: str,
        sequence: int,
        mutation_slot: bool = False,
    ) -> Measurement:
        try:
            delay_us = round(self.config.simulated_network_delay_ms * 1_000)
            if delay_us:
                time.sleep(delay_us / 1_000_000)
            if self._simulates_packet_loss(scenario, sequence):
                result = Measurement(
                    scenario,
                    0,
                    False,
                    "simulated_packet_loss",
                )
            else:
                try:
                    result = self._execute_http(
                        client, scenario, sequence, mutation_slot
                    )
                except (
                    Exception
                ):  # noqa: BLE001 - never serialize request/response details.
                    result = Measurement(scenario, 0, False, "client_failure")
            return Measurement(
                result.scenario,
                result.latency_us + delay_us,
                result.success,
                result.error_class,
            )
        finally:
            if mutation_slot:
                self.mutation_lock.release()

    def _simulates_packet_loss(self, scenario: str, sequence: int) -> bool:
        rate = self.config.simulated_packet_loss_rate
        if rate <= 0:
            return False
        material = (
            f"{self.config.source_revision}\0{self.config.evidence_id}"
            f"\0{scenario}\0{sequence}"
        ).encode("utf-8")
        sample = int.from_bytes(hashlib.sha256(material).digest()[:8], "big")
        return sample / 2**64 < rate

    def _execute_http(
        self,
        client: HttpClient,
        scenario: str,
        sequence: int,
        mutation_slot: bool,
    ) -> Measurement:
        if scenario == "feed":
            return measure(
                client,
                scenario,
                "GET",
                self.feed_paths[sequence % len(self.feed_paths)],
                None,
                validate_feed,
            )
        paper_id = self.paper_ids[sequence % len(self.paper_ids)]
        if scenario == "metadata":
            return measure(
                client,
                scenario,
                "GET",
                f"/v1/papers/{paper_id}",
                None,
                lambda value: validate_metadata(value, paper_id),
            )
        if scenario == "library":
            return measure(
                client,
                scenario,
                "GET",
                "/v1/me/library?state=to_read&limit=100",
                self.config.bearer_token,
                validate_library,
            )
        if scenario == "comments":
            return measure(
                client,
                scenario,
                "GET",
                f"/v1/papers/{self.config.comments_paper_id}/comments?limit=50",
                self.config.bearer_token,
                validate_comments,
            )
        if scenario == "library_mutation":
            if not mutation_slot:
                return Measurement("library_mutation", 0, False, "client_protocol")
            return self._mutate_library(client)
        return Measurement(scenario, 0, False, "client_protocol")

    def _mutate_library(self, client: HttpClient) -> Measurement:
        paper_id = self.config.library_mutation_paper_id
        token = self.config.bearer_token
        if paper_id is None or token is None:
            return Measurement("library_mutation", 0, False, "client_protocol")
        operation_id = str(uuid.uuid4())
        headers = {"Idempotency-Key": operation_id}
        if self.mutation_saved:
            result = measure(
                client,
                "library_mutation",
                "DELETE",
                f"/v1/me/library/{paper_id}",
                token,
                lambda value: validate_mutation(value, True, paper_id),
                extra_headers=headers,
            )
        else:
            result = measure(
                client,
                "library_mutation",
                "PUT",
                f"/v1/me/library/{paper_id}",
                token,
                lambda value: validate_mutation(value, False, paper_id),
                json_body={"operation_id": operation_id, "state": "to_read"},
                extra_headers=headers,
            )
        if result.success:
            self.mutation_saved = not self.mutation_saved
        return result

    def cleanup_mutation(self, client: HttpClient) -> bool:
        if not self.config.allow_library_mutations:
            return True
        with self.mutation_lock:
            paper_id = self.config.library_mutation_paper_id
            token = self.config.bearer_token
            if paper_id is None or token is None:
                return False
            operation_id = str(uuid.uuid4())
            result = measure(
                client,
                "library_mutation",
                "DELETE",
                f"/v1/me/library/{paper_id}",
                token,
                lambda value: validate_mutation(value, True, paper_id),
                extra_headers={"Idempotency-Key": operation_id},
            )
            if result.success:
                self.mutation_saved = False
            return result.success


class LoadRunner:
    def __init__(self, config: Config, workload: Workload):
        self.config = config
        self.workload = workload
        self.measurements: list[Measurement] = []
        self.warmups: list[Measurement] = []
        self.lock = threading.Lock()
        self.condition = threading.Condition(self.lock)
        self.start_event = threading.Event()
        self.ready_workers = 0
        self.next_sequence = 0
        self.scheduled_requests = 0
        self.scheduled_mutations = 0
        self.scheduled_by_scenario: Counter[str] = Counter()
        self.deadline = 0.0
        self.runner_timeout = False

    def reserve(self) -> tuple[int, str, bool] | None:
        with self.condition:
            while True:
                now = time.monotonic()
                if (
                    self.scheduled_requests >= self.config.maximum_requests
                    or now >= self.deadline
                ):
                    return None
                deficits = {
                    scenario: max(
                        0,
                        self.config.minimum_samples_per_scenario
                        - self.scheduled_by_scenario[scenario],
                    )
                    for scenario in self.config.enabled_scenarios
                }
                remaining_budget = (
                    self.config.maximum_requests - self.scheduled_requests
                )
                reserve_for_sample_floor = remaining_budget <= sum(deficits.values())
                weighted = self.workload.weighted_scenarios
                for _ in range(len(weighted) + 1):
                    sequence = self.next_sequence
                    scenario = weighted[sequence % len(weighted)]
                    self.next_sequence += 1
                    if reserve_for_sample_floor and deficits[scenario] == 0:
                        continue
                    mutation_slot = False
                    if scenario == "library_mutation":
                        if (
                            self.scheduled_mutations
                            >= self.config.maximum_library_mutation_requests
                        ):
                            continue
                        if not self.workload.try_acquire_mutation_slot():
                            continue
                        mutation_slot = True
                        self.scheduled_mutations += 1
                    self.scheduled_requests += 1
                    self.scheduled_by_scenario[scenario] += 1
                    return sequence, scenario, mutation_slot
                mutation_deficit = deficits.get("library_mutation", 0)
                if reserve_for_sample_floor and mutation_deficit > 0:
                    self.condition.wait(timeout=max(0.0, self.deadline - now))
                    continue
                return None

    def worker(self, worker_index: int) -> None:
        client = HttpClient(self.config)
        try:
            warmup_scenarios = self.workload.warmup_scenarios
            local_warmups = [
                self.workload.execute(
                    client,
                    scenario,
                    (
                        worker_index
                        * self.config.warmup_per_worker
                        * len(warmup_scenarios)
                        + repetition * len(warmup_scenarios)
                        + scenario_index
                    ),
                )
                for repetition in range(self.config.warmup_per_worker)
                for scenario_index, scenario in enumerate(warmup_scenarios)
            ]
            with self.condition:
                self.warmups.extend(local_warmups)
                self.ready_workers += 1
                self.condition.notify_all()
            self.start_event.wait()
            while True:
                reservation = self.reserve()
                if reservation is None:
                    return
                sequence, scenario, mutation_slot = reservation
                result = self.workload.execute(
                    client, scenario, sequence, mutation_slot
                )
                with self.condition:
                    self.measurements.append(result)
                    self.condition.notify_all()
        except Exception:  # noqa: BLE001 - contain worker failure without data.
            with self.condition:
                if not self.start_event.is_set():
                    self.warmups.append(
                        Measurement("runner", 0, False, "worker_failure")
                    )
                    self.ready_workers += 1
                    self.condition.notify_all()
                else:
                    self.measurements.append(
                        Measurement("runner", 0, False, "worker_failure")
                    )
        finally:
            client.close_thread()

    def run(self) -> tuple[list[Measurement], list[Measurement], int, bool]:
        started = 0.0
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=self.config.concurrency,
            thread_name_prefix="pakperk-load",
        ) as executor:
            futures = [
                executor.submit(self.worker, index)
                for index in range(self.config.concurrency)
            ]
            ready_timeout = (
                self.config.request_timeout_seconds
                + self.config.simulated_network_delay_ms / 1_000
            ) * self.config.warmup_per_worker * len(
                self.workload.warmup_scenarios
            ) + 5.0
            with self.condition:
                ready = self.condition.wait_for(
                    lambda: self.ready_workers == self.config.concurrency,
                    timeout=ready_timeout,
                )
                if not ready:
                    self.runner_timeout = True
                started = time.monotonic()
                self.deadline = started + self.config.duration_seconds
                self.start_event.set()
            _, unfinished = concurrent.futures.wait(
                futures,
                timeout=self.config.duration_seconds
                + self.config.request_timeout_seconds
                + self.config.simulated_network_delay_ms / 1_000
                + 5.0,
            )
            if unfinished:
                self.runner_timeout = True
        elapsed = max(0, round((time.monotonic() - started) * 1_000))
        return self.measurements, self.warmups, elapsed, self.runner_timeout


def nearest_rank(values: list[int], quantile: float) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(quantile * len(ordered)) - 1)
    return ordered[index]


def rounded_ms(value_us: int | None) -> float | None:
    return None if value_us is None else round(value_us / 1_000.0, 3)


def aggregate(measurements: list[Measurement]) -> tuple[dict[str, Any], dict[str, int]]:
    successful = [item.latency_us for item in measurements if item.success]
    errors = Counter(
        item.error_class or "unknown" for item in measurements if not item.success
    )
    total = len(measurements)
    failed = total - len(successful)
    payload = {
        "requests": total,
        "successful_requests": len(successful),
        "errors": failed,
        "error_rate": round(failed / total, 6) if total else 1.0,
        "successful_latency_ms": {
            "p50": rounded_ms(nearest_rank(successful, 0.50)),
            "p95": rounded_ms(nearest_rank(successful, 0.95)),
            "p99": rounded_ms(nearest_rank(successful, 0.99)),
        },
        "errors_by_class": dict(sorted(errors.items())),
    }
    raw = {
        "p50": nearest_rank(successful, 0.50) or 0,
        "p95": nearest_rank(successful, 0.95) or 0,
        "p99": nearest_rank(successful, 0.99) or 0,
    }
    return payload, raw


def build_evidence(
    config: Config,
    feed_pages: int,
    paper_records: int,
    measurements: list[Measurement],
    warmups: list[Measurement],
    elapsed_ms: int,
    runner_timeout: bool,
    mutation_cleanup_ok: bool,
) -> dict[str, Any]:
    enabled = config.enabled_scenarios
    scenario_payload: dict[str, Any] = {}
    failures: list[str] = []
    for scenario in enabled:
        selected = [item for item in measurements if item.scenario == scenario]
        payload, raw = aggregate(selected)
        threshold = config.thresholds[scenario]
        scenario_payload[scenario] = {
            **payload,
            "threshold": {
                "p50_ms": threshold.p50_ms,
                "p95_ms": threshold.p95_ms,
                "p99_ms": threshold.p99_ms,
                "maximum_error_rate": threshold.maximum_error_rate,
            },
        }
        if payload["requests"] < config.minimum_samples_per_scenario:
            failures.append(f"{scenario}:minimum_samples")
        raw_error_rate = (
            payload["errors"] / payload["requests"] if payload["requests"] else 1.0
        )
        if raw_error_rate > threshold.maximum_error_rate:
            failures.append(f"{scenario}:error_rate")
        if payload["successful_requests"] == 0:
            failures.append(f"{scenario}:latency_unavailable")
        else:
            for percentile, maximum in (
                ("p50", threshold.p50_ms),
                ("p95", threshold.p95_ms),
                ("p99", threshold.p99_ms),
            ):
                if raw[percentile] > maximum * 1_000:
                    failures.append(f"{scenario}:{percentile}")
    warmup_payload, _ = aggregate(warmups)
    if warmup_payload["errors"]:
        failures.append("warmup:errors")
    if runner_timeout:
        failures.append("runner:timeout")
    if any(item.scenario == "runner" for item in measurements):
        failures.append("runner:worker_failure")
    if not mutation_cleanup_ok:
        failures.append("library_mutation:cleanup")
    overall, _ = aggregate(measurements)
    origin_hash = hashlib.sha256(config.origin.encode("utf-8")).hexdigest()
    return {
        "schema_version": 1,
        "evidence_id": config.evidence_id,
        "source_revision": config.source_revision,
        "environment": config.environment,
        "target_origin_sha256": f"sha256:{origin_hash}",
        "classification": (
            "staging synthetic backend HTTP load evidence"
            if config.environment == "staging"
            else "development/mock contract evidence; not a staging release gate"
        ),
        "workload": {
            "requested_duration_seconds": config.duration_seconds,
            "elapsed_ms": elapsed_ms,
            "concurrency": config.concurrency,
            "maximum_requests": config.maximum_requests,
            "request_timeout_seconds": config.request_timeout_seconds,
            "preflight_timeout_seconds": config.preflight_timeout_seconds,
            "simulated_network": {
                "fixed_delay_ms": config.simulated_network_delay_ms,
                "packet_loss_rate": config.simulated_packet_loss_rate,
                "loss_selection": "deterministic_sha256",
            },
            "maximum_response_bytes": config.maximum_response_bytes,
            "minimum_samples_per_scenario": config.minimum_samples_per_scenario,
            "warmup_per_worker": config.warmup_per_worker,
            "feed_pages_discovered": feed_pages,
            "paper_records_discovered": paper_records,
            "category_filter_present": config.category is not None,
            "enabled_scenarios": list(enabled),
            "authenticated_scenarios": [
                name
                for name in enabled
                if name in {"library", "library_mutation"}
                or (name == "comments" and config.bearer_token is not None)
            ],
            "library_mutation_request_cap": (
                config.maximum_library_mutation_requests
                if config.allow_library_mutations
                else 0
            ),
        },
        "warmup": warmup_payload,
        "measurements": {
            "overall": overall,
            "scenarios": scenario_payload,
        },
        "gate": {
            "passed": not failures,
            "failures": failures,
        },
        "limitations": [
            "measures backend HTTP response latency, not mobile frame/build/raster time",
            "does not measure mobile SQLite size/query latency, cache retention, or lifecycle behavior",
            "comment workload is read-only and never creates or serializes user content into evidence",
            "results require separately recorded staging topology, database saturation, and telemetry context",
        ],
    }


def write_evidence(path: Path, evidence: dict[str, Any]) -> None:
    if os.path.lexists(path):
        raise LoadError("evidence output already exists")
    encoded = (
        json.dumps(evidence, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fchmod(output.fileno(), 0o400)
            os.fsync(output.fileno())
        os.link(temporary, path)
        temporary.unlink()
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def run(config: Config) -> dict[str, Any]:
    preflight_client = HttpClient(config)
    preflight_deadline = time.monotonic() + config.preflight_timeout_seconds
    try:
        feed_paths, paper_ids = bootstrap_feed(
            config, preflight_client, preflight_deadline
        )
        if config.allow_library_mutations:
            assert_mutation_target_absent(config, preflight_client, preflight_deadline)
    finally:
        preflight_client.close_thread()
    workload = Workload(config, feed_paths, paper_ids)
    runner = LoadRunner(config, workload)
    try:
        measurements, warmups, elapsed_ms, runner_timeout = runner.run()
    finally:
        cleanup_client = HttpClient(config)
        try:
            mutation_cleanup_ok = workload.cleanup_mutation(cleanup_client)
        finally:
            cleanup_client.close_thread()
    return build_evidence(
        config,
        len(feed_paths),
        len(paper_ids),
        measurements,
        warmups,
        elapsed_ms,
        runner_timeout,
        mutation_cleanup_ok,
    )


def main(argv: list[str] | None = None) -> int:
    try:
        config = parse_config(argv)
    except (ConfigurationError, argparse.ArgumentTypeError) as error:
        print(f"backend load configuration failed: {error}", file=sys.stderr)
        return 2
    try:
        evidence = run(config)
        write_evidence(config.output, evidence)
    except LoadError as error:
        print(f"backend load preflight failed: {error}", file=sys.stderr)
        return 1
    except (
        Exception
    ) as error:  # noqa: BLE001 - never expose request/token/content details.
        print(f"backend load failed with {type(error).__name__}", file=sys.stderr)
        return 1
    request_count = evidence["measurements"]["overall"]["requests"]
    scenario_count = len(evidence["measurements"]["scenarios"])
    if evidence["gate"]["passed"]:
        print(
            f"PASS backend load gate ({request_count} measured requests, {scenario_count} scenarios)"
        )
        return 0
    print(
        f"FAIL backend load gate ({request_count} measured requests, {scenario_count} scenarios)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
