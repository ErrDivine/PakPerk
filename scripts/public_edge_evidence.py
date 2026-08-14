#!/usr/bin/env python3
"""Closed evidence contract for Pakperk public-edge technical verification.

Only reviewed public coordinates, fixed outcomes, and one-way observation
digests are retained. Response bodies, response headers, transport errors,
credentials, cookies, and operator identity never enter the artifact.
"""

from __future__ import annotations

from dataclasses import dataclass
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
from typing import Any, Mapping
import urllib.parse


EVIDENCE_SCHEMA_VERSION = 3
MAX_EVIDENCE_BYTES = 64 * 1024
MAX_JSON_NESTING = 16

ENVIRONMENTS = ("staging", "production")
CLASSIFICATION = "sanitized public-edge technical verification only"
REQUESTED_CANDIDATE_OBSERVATION = "operator_binding_not_observed_at_edge"
SOURCE_OBSERVATION = "site_notices_source_revision_exact_match"

SOURCE_REVISION_RE = re.compile(r"[0-9a-f]{40}")
SAFE_IDENTIFIER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}")
PACKAGE_RE = re.compile(r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+")
BUNDLE_RE = re.compile(r"[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+")
APPLE_TEAM_RE = re.compile(r"[A-Z0-9]{10}")
ANDROID_FINGERPRINT_RE = re.compile(r"(?:[A-F0-9]{2}:){31}[A-F0-9]{2}")
SHA256_ID_RE = re.compile(r"sha256:[0-9a-f]{64}")
OBSERVATION_ID_RE = re.compile(r"observation-sha256:[0-9a-f]{64}")
CONTENT_ID_RE = re.compile(r"public-edge-sha256:[0-9a-f]{64}")
DNS_LABEL_RE = re.compile(r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?")
DNS_TLD_RE = re.compile(r"[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?")
OIDC_PATH_RE = re.compile(r"(?:/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)+")
EMAIL_RE = re.compile(r"[^@\s]{1,64}@[^@\s]{1,189}")
UUID_RE = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
    r"[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"
)

SCENARIO_IDS = (
    "runtime_config_exact_public_binding",
    "site_http_redirects_exactly_to_https",
    "api_http_redirects_exactly_to_https",
    "telemetry_http_redirects_exactly_to_https",
    "site_root_direct_https_headers_and_cache",
    "guide_route_direct_https_headers_and_cache",
    "privacy_route_direct_https_headers_and_cache",
    "terms_route_direct_https_headers_and_cache",
    "community_guidelines_route_direct_https_headers_and_cache",
    "support_route_direct_https_headers_and_cache",
    "account_deletion_route_direct_https_private_cache",
    "open_source_licenses_route_direct_https_headers_and_cache",
    "site_notices_source_revision_matches",
    "android_association_matches_release_identity",
    "apple_association_matches_release_identity",
    "api_feed_is_gzip_compressed_at_public_edge",
    "api_readiness_contract_direct_https",
    "telemetry_process_readiness_direct_https",
)
SCENARIO_OUTCOMES = {"passed", "failed", "not_run"}

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "binding",
    "run",
    "scenarios",
    "scope",
    "sanitization",
}
BINDING_KEYS = {
    "source_revision",
    "target_environment",
    "requested_candidate_id",
    "origins",
    "runtime_config",
    "mobile_candidate",
}
ORIGIN_KEYS = {"site", "api", "telemetry"}
RUNTIME_KEYS = {
    "document_version",
    "oidc_issuer",
    "oidc_client_id",
    "support_contact_sha256",
}
MOBILE_KEYS = {
    "android_package",
    "android_play_signing_sha256",
    "apple_team_id",
    "apple_bundle_id",
}
RUN_KEYS = {"outcome"}
SCENARIO_KEYS = {"id", "outcome", "observation_id"}
SCOPE_KEYS = {
    "classification",
    "requested_candidate_identity",
    "source_revision_observation",
    "github_environment_protection",
    "deployment_provenance",
    "legal_or_policy_approval",
    "signed_candidate_custody",
    "physical_deep_link_qa",
    "authenticated_account_deletion_completion",
    "api_readiness_scope",
    "telemetry_readiness_scope",
}
SANITIZATION_KEYS = {
    "artifact_contract",
    "response_bodies",
    "response_headers",
    "transport_errors",
    "credentials_and_cookies",
    "operator_identity",
    "support_contact",
}

SCOPE = {
    "classification": CLASSIFICATION,
    "requested_candidate_identity": REQUESTED_CANDIDATE_OBSERVATION,
    "source_revision_observation": SOURCE_OBSERVATION,
    "github_environment_protection": "not_attested",
    "deployment_provenance": "not_attested",
    "legal_or_policy_approval": "not_attested",
    "signed_candidate_custody": "not_attested",
    "physical_deep_link_qa": "not_attested",
    "authenticated_account_deletion_completion": "not_attested",
    "api_readiness_scope": "ready_response_contract_only_not_deployment_provenance",
    "telemetry_readiness_scope": "gateway_process_only_not_collector_sink_or_export_delivery",
}
SANITIZATION = {
    "artifact_contract": "closed_allowlist_v3",
    "response_bodies": "excluded_digest_only",
    "response_headers": "excluded_digest_only",
    "transport_errors": "excluded_category_only",
    "credentials_and_cookies": "excluded",
    "operator_identity": "excluded",
    "support_contact": "excluded_sha256_only",
}

PRODUCTION_FORBIDDEN_TEAM_IDS = {
    "AAAAAAAAAA",
    "XXXXXXXXXX",
    "ZZZZZZZZZZ",
    "0000000000",
    "TEAMID1234",
}
PRODUCTION_FORBIDDEN_FINGERPRINTS = {
    "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF",
    "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
    "AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA",
}


class EvidenceError(RuntimeError):
    """A bounded contract error which never includes untrusted artifact data."""


@dataclass(frozen=True)
class PublicEdgeBinding:
    source_revision: str
    target_environment: str
    requested_candidate_id: str
    site_origin: str
    api_origin: str
    telemetry_origin: str
    document_version: str
    oidc_issuer: str
    oidc_client_id: str
    support_email: str
    android_package: str
    android_sha256: str
    apple_team_id: str
    apple_bundle_id: str

    def validate(self) -> "PublicEdgeBinding":
        validate_binding(self)
        return self

    def evidence_value(self) -> dict[str, Any]:
        self.validate()
        return {
            "source_revision": self.source_revision,
            "target_environment": self.target_environment,
            "requested_candidate_id": self.requested_candidate_id,
            "origins": {
                "site": self.site_origin,
                "api": self.api_origin,
                "telemetry": self.telemetry_origin,
            },
            "runtime_config": {
                "document_version": self.document_version,
                "oidc_issuer": self.oidc_issuer,
                "oidc_client_id": self.oidc_client_id,
                "support_contact_sha256": support_contact_id(self.support_email),
            },
            "mobile_candidate": {
                "android_package": self.android_package,
                "android_play_signing_sha256": self.android_sha256,
                "apple_team_id": self.apple_team_id,
                "apple_bundle_id": self.apple_bundle_id,
            },
        }


def _canonical_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def support_contact_id(value: str) -> str:
    return f"sha256:{hashlib.sha256(value.encode('utf-8')).hexdigest()}"


def observation_id(value: Mapping[str, Any]) -> str:
    """Hash a closed, caller-constructed observation without retaining it."""
    return f"observation-sha256:{hashlib.sha256(_canonical_bytes(value)).hexdigest()}"


def _content_id(value: Mapping[str, Any]) -> str:
    # This domain is intentionally not accepted by Helm's `sha256:<hex>`
    # release-approval fields.
    return f"public-edge-sha256:{hashlib.sha256(_canonical_bytes(value)).hexdigest()}"


def validate_origin(value: str) -> str:
    if not isinstance(value, str) or len(value) > 253 + len("https://"):
        raise EvidenceError("a public origin is not a bounded exact HTTPS origin")
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise EvidenceError(
            "a public origin is not a bounded exact HTTPS origin"
        ) from error
    host = parsed.hostname
    if (
        parsed.scheme != "https"
        or host is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
        or port is not None
        or value != f"https://{host}"
        or not host.isascii()
        or len(host) > 253
    ):
        raise EvidenceError("a public origin is not a bounded exact HTTPS origin")
    labels = host.split(".")
    if (
        len(labels) < 2
        or any(not DNS_LABEL_RE.fullmatch(label) for label in labels)
        or DNS_TLD_RE.fullmatch(labels[-1]) is None
    ):
        raise EvidenceError("a public origin host is not a canonical DNS name")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise EvidenceError("public origin IP literals are forbidden")
    reserved = (
        host == "localhost"
        or host.endswith(".localhost")
        or host.endswith(".local")
        or host.endswith(".test")
        or host.endswith(".invalid")
        or host.endswith(".example")
        or host in {"example.com", "example.org", "example.net"}
        or host.endswith(".example.com")
        or host.endswith(".example.org")
        or host.endswith(".example.net")
    )
    if reserved:
        raise EvidenceError("reserved or local public origin hosts are forbidden")
    return value


def validate_oidc_issuer(value: str) -> str:
    if not isinstance(value, str) or not value.isascii() or len(value) > 2048:
        raise EvidenceError("OIDC issuer is not a bounded HTTPS URL")
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise EvidenceError("OIDC issuer is not a bounded HTTPS URL") from error
    decoded_path = urllib.parse.unquote(parsed.path)
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or not parsed.path.startswith("/")
        or parsed.path in {"", "/"}
        or OIDC_PATH_RE.fullmatch(parsed.path) is None
        or re.search(r"%(?![0-9A-Fa-f]{2})", parsed.path) is not None
        or parsed.query
        or parsed.fragment
        or value
        != urllib.parse.urlunsplit(("https", parsed.hostname, parsed.path, "", ""))
        or any(
            character.isspace() or ord(character) < 0x21 for character in parsed.path
        )
        or any(
            character.isspace() or ord(character) < 0x21 for character in decoded_path
        )
        or ".." in decoded_path.split("/")
        or "\\" in decoded_path
    ):
        raise EvidenceError("OIDC issuer is not a bounded exact HTTPS URL")
    validate_origin(f"https://{parsed.hostname}")
    return value


def validate_support_email(value: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) > 254
        or not value.isascii()
        or EMAIL_RE.fullmatch(value) is None
        or value != value.strip()
    ):
        raise EvidenceError("support contact is not a bounded email address")
    domain = value.rsplit("@", 1)[1].lower()
    validate_origin(f"https://{domain}")
    return value


def validate_binding(binding: PublicEdgeBinding) -> None:
    if (
        not isinstance(binding.source_revision, str)
        or SOURCE_REVISION_RE.fullmatch(binding.source_revision) is None
    ):
        raise EvidenceError("source revision must be a full lowercase Git SHA")
    if binding.target_environment not in ENVIRONMENTS:
        raise EvidenceError("target environment must be staging or production")
    if (
        not isinstance(binding.requested_candidate_id, str)
        or SHA256_ID_RE.fullmatch(binding.requested_candidate_id) is None
    ):
        raise EvidenceError("requested candidate ID must be an exact SHA-256 ID")

    origins = [
        validate_origin(binding.site_origin),
        validate_origin(binding.api_origin),
        validate_origin(binding.telemetry_origin),
    ]
    hosts = [urllib.parse.urlsplit(origin).hostname for origin in origins]
    if len(set(hosts)) != len(hosts):
        raise EvidenceError("site, API, and telemetry origins must use distinct hosts")

    if (
        not isinstance(binding.document_version, str)
        or len(binding.document_version) != 10
    ):
        raise EvidenceError("document version must be a canonical ISO calendar date")
    try:
        parsed_date = dt.date.fromisoformat(binding.document_version)
    except (TypeError, ValueError) as error:
        raise EvidenceError(
            "document version must be a real ISO calendar date"
        ) from error
    if parsed_date.isoformat() != binding.document_version:
        raise EvidenceError("document version must be a canonical ISO calendar date")
    validate_oidc_issuer(binding.oidc_issuer)
    oidc_host = urllib.parse.urlsplit(binding.oidc_issuer).hostname
    if oidc_host in hosts:
        raise EvidenceError("OIDC and public service origins must use distinct hosts")
    if (
        not isinstance(binding.oidc_client_id, str)
        or SAFE_IDENTIFIER_RE.fullmatch(binding.oidc_client_id) is None
    ):
        raise EvidenceError("OIDC web client ID is not a bounded safe identifier")
    validate_support_email(binding.support_email)

    expected_app_id = (
        "app.pakperk.pakperk"
        if binding.target_environment == "production"
        else "app.pakperk.pakperk.staging"
    )
    if (
        not isinstance(binding.android_package, str)
        or not isinstance(binding.apple_bundle_id, str)
        or len(binding.android_package) > 255
        or len(binding.apple_bundle_id) > 255
        or PACKAGE_RE.fullmatch(binding.android_package) is None
        or BUNDLE_RE.fullmatch(binding.apple_bundle_id) is None
        or binding.android_package != expected_app_id
        or binding.apple_bundle_id != expected_app_id
    ):
        raise EvidenceError(
            "mobile application IDs do not match the target environment"
        )
    if (
        not isinstance(binding.android_sha256, str)
        or ANDROID_FINGERPRINT_RE.fullmatch(binding.android_sha256) is None
    ):
        raise EvidenceError("Android signing fingerprint is not canonical SHA-256")
    if (
        not isinstance(binding.apple_team_id, str)
        or APPLE_TEAM_RE.fullmatch(binding.apple_team_id) is None
    ):
        raise EvidenceError("Apple team ID is not canonical")
    if binding.target_environment == "production":
        if binding.apple_team_id in PRODUCTION_FORBIDDEN_TEAM_IDS:
            raise EvidenceError("production Apple team ID is a known fixture")
        if binding.android_sha256 in PRODUCTION_FORBIDDEN_FINGERPRINTS:
            raise EvidenceError("production Android fingerprint is a known fixture")


def _exact_keys(value: Any, expected: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise EvidenceError(f"{label} does not use the closed evidence schema")
    return value


def _binding_from_evidence(value: Any, support_email: str) -> PublicEdgeBinding:
    binding = _exact_keys(value, BINDING_KEYS, "binding")
    origins = _exact_keys(binding["origins"], ORIGIN_KEYS, "origins")
    runtime = _exact_keys(binding["runtime_config"], RUNTIME_KEYS, "runtime config")
    mobile = _exact_keys(binding["mobile_candidate"], MOBILE_KEYS, "mobile candidate")
    if runtime["support_contact_sha256"] != support_contact_id(support_email):
        raise EvidenceError("support contact binding does not match")
    return PublicEdgeBinding(
        source_revision=binding["source_revision"],
        target_environment=binding["target_environment"],
        requested_candidate_id=binding["requested_candidate_id"],
        site_origin=origins["site"],
        api_origin=origins["api"],
        telemetry_origin=origins["telemetry"],
        document_version=runtime["document_version"],
        oidc_issuer=runtime["oidc_issuer"],
        oidc_client_id=runtime["oidc_client_id"],
        support_email=support_email,
        android_package=mobile["android_package"],
        android_sha256=mobile["android_play_signing_sha256"],
        apple_team_id=mobile["apple_team_id"],
        apple_bundle_id=mobile["apple_bundle_id"],
    ).validate()


def _validate_scenario_sequence(scenarios: list[dict[str, Any]], outcome: str) -> None:
    outcomes = [scenario["outcome"] for scenario in scenarios]
    if outcome == "passed":
        if any(value != "passed" for value in outcomes):
            raise EvidenceError("a passed run must pass every public-edge scenario")
        return
    if outcome != "failed" or outcomes.count("failed") != 1:
        raise EvidenceError("a failed run must identify exactly one failed scenario")
    failure_index = outcomes.index("failed")
    if any(value != "passed" for value in outcomes[:failure_index]):
        raise EvidenceError("failed-run scenario prefix is invalid")
    if any(value != "not_run" for value in outcomes[failure_index + 1 :]):
        raise EvidenceError("failed-run scenario suffix is invalid")


def validate_evidence(
    evidence: Any,
    *,
    expected_binding: PublicEdgeBinding,
    expected_outcome: str | None = None,
) -> dict[str, Any]:
    expected_binding.validate()
    root = _exact_keys(evidence, ROOT_KEYS, "root")
    if (
        type(root["schema_version"]) is not int
        or root["schema_version"] != EVIDENCE_SCHEMA_VERSION
    ):
        raise EvidenceError("evidence schema version is invalid")
    actual_binding = _binding_from_evidence(
        root["binding"], expected_binding.support_email
    )
    if actual_binding != expected_binding:
        raise EvidenceError(
            "evidence does not match the exact expected public-edge binding"
        )

    run = _exact_keys(root["run"], RUN_KEYS, "run")
    outcome = run["outcome"]
    if not isinstance(outcome, str) or outcome not in {"passed", "failed"}:
        raise EvidenceError("public-edge run outcome is invalid")
    if expected_outcome is not None and outcome != expected_outcome:
        raise EvidenceError("public-edge evidence outcome does not match")

    raw_scenarios = root["scenarios"]
    if not isinstance(raw_scenarios, list) or len(raw_scenarios) != len(SCENARIO_IDS):
        raise EvidenceError(
            "evidence does not contain the exact public-edge scenario matrix"
        )
    scenarios: list[dict[str, Any]] = []
    for expected_id, raw_scenario in zip(SCENARIO_IDS, raw_scenarios, strict=True):
        scenario = dict(_exact_keys(raw_scenario, SCENARIO_KEYS, "scenario"))
        if (
            scenario["id"] != expected_id
            or not isinstance(scenario["outcome"], str)
            or scenario["outcome"] not in SCENARIO_OUTCOMES
        ):
            raise EvidenceError("scenario identity or outcome is invalid")
        observation = scenario["observation_id"]
        if scenario["outcome"] == "passed":
            if (
                not isinstance(observation, str)
                or OBSERVATION_ID_RE.fullmatch(observation) is None
            ):
                raise EvidenceError("passed scenario is missing its observation digest")
        elif observation != "not_observed":
            raise EvidenceError("unpassed scenarios must not retain observations")
        scenarios.append(scenario)
    _validate_scenario_sequence(scenarios, outcome)

    if dict(_exact_keys(root["scope"], SCOPE_KEYS, "scope")) != SCOPE:
        raise EvidenceError("public-edge evidence scope is invalid")
    if (
        dict(_exact_keys(root["sanitization"], SANITIZATION_KEYS, "sanitization"))
        != SANITIZATION
    ):
        raise EvidenceError("public-edge evidence sanitization declaration is invalid")

    content_id = root["content_id"]
    if not isinstance(content_id, str) or CONTENT_ID_RE.fullmatch(content_id) is None:
        raise EvidenceError("public-edge content ID is invalid")
    statement = dict(root)
    del statement["content_id"]
    if _content_id(statement) != content_id:
        raise EvidenceError(
            "public-edge content ID does not match its canonical statement"
        )

    encoded = _canonical_bytes(root)
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("public-edge evidence exceeds its maximum size")
    decoded = encoded.decode("ascii")
    if expected_binding.support_email in decoded or EMAIL_RE.search(decoded):
        raise EvidenceError("public-edge evidence contains an email address")
    if UUID_RE.search(decoded) or JWT_RE.search(decoded):
        raise EvidenceError(
            "public-edge evidence contains forbidden identity or token material"
        )
    return dict(root)


def build_evidence(
    binding: PublicEdgeBinding,
    scenario_state: Mapping[str, Mapping[str, str]],
    outcome: str,
) -> dict[str, Any]:
    binding.validate()
    if set(scenario_state) != set(SCENARIO_IDS):
        raise EvidenceError(
            "scenario state does not contain the exact public-edge matrix"
        )
    scenarios = []
    for scenario_id in SCENARIO_IDS:
        state = scenario_state[scenario_id]
        if not isinstance(state, Mapping) or set(state) != {
            "outcome",
            "observation_id",
        }:
            raise EvidenceError("scenario state is not closed")
        scenarios.append(
            {
                "id": scenario_id,
                "outcome": state["outcome"],
                "observation_id": state["observation_id"],
            }
        )
    statement: dict[str, Any] = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "binding": binding.evidence_value(),
        "run": {"outcome": outcome},
        "scenarios": scenarios,
        "scope": dict(SCOPE),
        "sanitization": dict(SANITIZATION),
    }
    evidence = dict(statement)
    evidence["content_id"] = _content_id(statement)
    return validate_evidence(
        evidence,
        expected_binding=binding,
        expected_outcome=outcome,
    )


def initial_scenario_state() -> dict[str, dict[str, str]]:
    return {
        scenario_id: {"outcome": "not_run", "observation_id": "not_observed"}
        for scenario_id in SCENARIO_IDS
    }


def write_evidence(
    path: Path, evidence: Mapping[str, Any], binding: PublicEdgeBinding
) -> None:
    validate_evidence(evidence, expected_binding=binding)
    if not path.is_absolute():
        raise EvidenceError("evidence output path must be absolute")
    parent = path.parent
    try:
        if not parent.is_dir() or parent.is_symlink():
            raise EvidenceError(
                "evidence output parent must be a non-symlink directory"
            )
        parent_mode = stat.S_IMODE(parent.stat().st_mode)
        if parent_mode & 0o022:
            raise EvidenceError(
                "evidence output parent must not be group/other writable"
            )
        destination_exists = path.exists() or path.is_symlink()
    except EvidenceError:
        raise
    except OSError as error:
        raise EvidenceError("could not inspect public-edge evidence output") from error
    encoded = json.dumps(evidence, indent=2, sort_keys=True).encode("ascii") + b"\n"
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("serialized public-edge evidence exceeds its maximum size")
    if destination_exists:
        raise EvidenceError("public-edge evidence output already exists")
    temporary_path = parent / f".{path.name}.{secrets.token_hex(12)}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    published = False
    try:
        descriptor = os.open(temporary_path, flags, 0o600)
    except OSError as error:
        raise EvidenceError(
            "could not create exclusive public-edge evidence output"
        ) from error
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        # A same-directory hard-link is an atomic, no-overwrite publication:
        # unlike os.replace(), it cannot silently replace an existing artifact.
        os.link(temporary_path, path, follow_symlinks=False)
        published = True
        temporary_path.unlink()
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            directory_flags |= os.O_NOFOLLOW
        directory_descriptor = os.open(parent, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception as error:
        try:
            temporary_path.unlink(missing_ok=True)
            if published:
                path.unlink(missing_ok=True)
        finally:
            raise EvidenceError(
                "could not atomically publish public-edge evidence"
            ) from error


def read_evidence(path: Path) -> Any:
    if not path.is_absolute():
        raise EvidenceError(
            "evidence input must be an absolute non-symlink regular file"
        )
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            os.close(descriptor)
            raise EvidenceError("evidence input must be a regular file")
        if metadata.st_size <= 0 or metadata.st_size > MAX_EVIDENCE_BYTES:
            os.close(descriptor)
            raise EvidenceError("evidence input size is invalid")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            os.close(descriptor)
            raise EvidenceError(
                "evidence input must not be accessible to group or other"
            )
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            encoded = stream.read(MAX_EVIDENCE_BYTES + 1)
    except OSError as error:
        raise EvidenceError("could not read public-edge evidence") from error
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("evidence input exceeds its maximum size")
    try:
        depth = 0
        in_string = False
        escaped = False
        for byte in encoded:
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
                if depth > MAX_JSON_NESTING:
                    raise EvidenceError("evidence input exceeds JSON nesting boundary")
            elif byte in (ord("}"), ord("]")):
                depth -= 1

        def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, value in pairs:
                if key in result:
                    raise EvidenceError("evidence input contains duplicate JSON fields")
                result[key] = value
            return result

        def reject_constant(_value: str) -> Any:
            raise EvidenceError("evidence input contains a non-finite JSON number")

        return json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except EvidenceError:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise EvidenceError(
            "evidence input is not canonical JSON-compatible data"
        ) from error
