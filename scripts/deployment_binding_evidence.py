#!/usr/bin/env python3
"""Build and verify sanitized dark-deployment provenance evidence.

The builder consumes a release-image promotion handoff, a live Kubernetes
release-evidence ConfigMap, a live PodList, and one small platform observation.
It emits only closed, bounded identifiers and one-way digests. Kubernetes
credentials, raw manifests, Pod names, node names, public origins, and operator
identity are deliberately excluded from the evidence artifact.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_EVIDENCE_BYTES = 128 * 1024
MAX_JSON_NESTING = 24
CONTENT_DOMAIN = b"pakperk-deployment-binding-v1\0"
CONTENT_PREFIX = "deployment-binding-v1:sha256:"

SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
CONTENT_ID_RE = re.compile(r"deployment-binding-v1:sha256:[0-9a-f]{64}\Z")
REVISION_RE = re.compile(r"[0-9a-f]{40}\Z")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
SAFE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
DNS_LABEL_RE = re.compile(r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?\Z")
OCI_REPOSITORY_RE = re.compile(
    r"(?:[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[1-9][0-9]{0,4})?/)?"
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*\Z"
)
UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)
SEMVER_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\Z"
)

ENVIRONMENTS = {"staging", "production"}
FEATURE_KEYS = {
    "accounts",
    "library",
    "libraryWrites",
    "comments",
    "commentCreation",
    "accountDeletion",
}
RELEASE_EVIDENCE_KEYS = {
    "legalReviewId",
    "moderationReadinessId",
    "accountDeletionE2eId",
    "restoreDrillId",
    "reviewerFlowId",
    "strictContentReviewId",
}
IMAGE_KEYS = {"backend", "site", "grobid", "otelCollector"}
CORE_COMPONENTS = (
    "api",
    "paper-worker",
    "deletion-worker",
    "telemetry-gateway",
    "site",
    "grobid",
    "otel-collector",
)
EPHEMERAL_COMPONENTS = {"metadata-sync", "migration"}
ALL_COMPONENTS = set(CORE_COMPONENTS) | EPHEMERAL_COMPONENTS
COMPONENT_IMAGE = {
    "api": "backend",
    "paper-worker": "backend",
    "deletion-worker": "backend",
    "telemetry-gateway": "backend",
    "metadata-sync": "backend",
    "migration": "backend",
    "site": "site",
    "grobid": "grobid",
    "otel-collector": "otelCollector",
}
SMOKE_CHECK_KEYS = {
    "api_readiness",
    "site_readiness",
    "public_feed",
    "telemetry_readiness",
    "candidate_identity",
}

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "binding",
    "release",
    "workloads",
    "ingress",
    "controls",
    "staging_smoke",
    "approval",
    "scope",
    "sanitization",
}
BINDING_KEYS = {
    "environment",
    "source_revision",
    "captured_at",
    "cluster_identity",
    "release_namespace_sha256",
    "release_instance_sha256",
    "promotion_handoff_sha256",
    "scan_handoff",
}
RELEASE_KEYS = {
    "config_map_sha256",
    "release_binding_sha256",
    "release_evidence_sha256",
    "chart",
    "features",
    "release_evidence",
    "alert_policy_sha256",
    "images",
    "legal_policy",
}
WORKLOAD_KEYS = {
    "component",
    "replicas",
    "ready_replicas",
    "image_repository",
    "image_digest",
    "pod_set_sha256",
    "pod_spec_sha256",
}
INGRESS_KEYS = {
    "controller_repository",
    "controller_digest",
    "configuration_sha256",
    "review_reference",
}
CONTROL_KEYS = {
    "rendered_values_sha256",
    "auth_configuration_sha256",
    "database_roles_sha256",
    "network_policies_sha256",
    "retention_configuration_sha256",
    "secret_rotation_sha256",
}
SMOKE_KEYS = {
    "environment",
    "source_revision",
    "backend_digest",
    "site_digest",
    "checks",
    "reference",
}
APPROVAL_KEYS = {"role", "reference"}
SCOPE_KEYS = {
    "classification",
    "raw_kubernetes_objects",
    "cluster_credentials",
    "pod_and_node_names",
    "operator_identity",
    "promotion_binding",
    "release_binding",
    "runtime_image_identity",
    "ingress_configuration",
    "staging_smoke",
}
SANITIZATION_KEYS = {
    "artifact_contract",
    "input_files",
    "namespaces_and_instances",
    "pod_inventory",
    "configuration_values",
    "credentials_and_tokens",
}

SCOPE = {
    "classification": "sanitized dark-deployment provenance",
    "raw_kubernetes_objects": "excluded",
    "cluster_credentials": "excluded",
    "pod_and_node_names": "excluded_digest_only",
    "operator_identity": "excluded_role_and_reference_only",
    "promotion_binding": "exact_canonical_handoff",
    "release_binding": "live_immutable_config_map",
    "runtime_image_identity": "settled_ready_pod_image_ids",
    "ingress_configuration": "reviewed_digest_and_controller_identity",
    "staging_smoke": "exact_source_and_candidate_digests",
}
SANITIZATION = {
    "artifact_contract": "closed_allowlist_v1",
    "input_files": "validated_then_excluded",
    "namespaces_and_instances": "sha256_only",
    "pod_inventory": "component_counts_set_and_reviewed_spec_digest_only",
    "configuration_values": "closed_release_contract_and_control_digests_only",
    "credentials_and_tokens": "forbidden",
}


class EvidenceError(RuntimeError):
    """A bounded failure whose message never includes untrusted data."""


def _canonical_bytes(value: Any, *, newline: bool = False) -> bytes:
    encoded = json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return encoded + (b"\n" if newline else b"")


def _closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("duplicate JSON member")
        result[key] = value
    return result


def _reject_constant(_: str) -> Any:
    raise EvidenceError("non-finite JSON number")


def _json_depth(value: Any, depth: int = 0) -> int:
    if depth > MAX_JSON_NESTING:
        raise EvidenceError("JSON nesting is too deep")
    if isinstance(value, dict):
        for key, member in value.items():
            if not isinstance(key, str):
                raise EvidenceError("JSON object key is not text")
            _json_depth(member, depth + 1)
    elif isinstance(value, list):
        for member in value:
            _json_depth(member, depth + 1)
    return depth


def strict_json(data: bytes, *, require_canonical: bool = False) -> Any:
    if len(data) > MAX_INPUT_BYTES:
        raise EvidenceError("JSON input is oversized")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("JSON input is not UTF-8") from error
    decoder = json.JSONDecoder(
        object_pairs_hook=_closed_object,
        parse_constant=_reject_constant,
    )
    leading = len(text) - len(text.lstrip())
    try:
        value, end = decoder.raw_decode(text, leading)
    except (ValueError, RecursionError, EvidenceError) as error:
        raise EvidenceError("invalid JSON document") from error
    if text[end:].strip():
        raise EvidenceError("multiple JSON documents")
    try:
        _json_depth(value)
    except RecursionError as error:
        raise EvidenceError("JSON nesting is too deep") from error
    if require_canonical and data != _canonical_bytes(value, newline=True):
        raise EvidenceError("JSON document is not canonical")
    return value


def _read_regular(path: Path, *, max_bytes: int = MAX_INPUT_BYTES) -> bytes:
    try:
        before = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise EvidenceError("input file is unavailable") from error
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            raise EvidenceError("input is not one regular file")
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise EvidenceError("input file identity changed")
        if current.st_uid not in {0, os.geteuid()} or current.st_mode & 0o022:
            raise EvidenceError("input file ownership or permissions are unsafe")
        if current.st_size <= 0 or current.st_size > max_bytes:
            raise EvidenceError("input file size is invalid")
        chunks: list[bytes] = []
        total = 0
        while total <= max_bytes:
            chunk = os.read(descriptor, min(64 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > max_bytes:
            raise EvidenceError("input file is oversized")
        after = os.fstat(descriptor)
        if (
            after.st_size != current.st_size
            or after.st_mtime_ns != current.st_mtime_ns
            or after.st_ctime_ns != current.st_ctime_ns
        ):
            raise EvidenceError("input file changed while read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _write_exclusive(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise EvidenceError("could not create fresh evidence output") from error
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceError("evidence output write did not make progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _exact(value: Any, keys: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} does not use the closed key set")
    return value


def _text(value: Any, label: str, *, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise EvidenceError(f"{label} is not bounded text")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise EvidenceError(f"{label} contains a control character")
    return value


def _integer(value: Any, label: str, *, minimum: int = 0, maximum: int = 10000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise EvidenceError(f"{label} is outside its integer bound")
    return value


def _sha256(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if allow_empty and value == "":
        return ""
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a SHA-256 identifier")
    payload = value.removeprefix("sha256:")
    if len(set(payload)) == 1:
        raise EvidenceError(f"{label} is an obvious placeholder")
    return value


def _safe_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or SAFE_ID_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a safe identifier")
    return value


def _timestamp(value: Any, label: str) -> str:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not an exact UTC timestamp")
    try:
        dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise EvidenceError(f"{label} is not a calendar timestamp") from error
    return value


def _repository(value: Any, label: str) -> str:
    text = _text(value, label, maximum=255)
    if OCI_REPOSITORY_RE.fullmatch(text) is None or text != text.lower():
        raise EvidenceError(f"{label} is not a lowercase tag-free OCI repository")
    return text


def _hash_id(domain: bytes, value: Any) -> str:
    return "sha256:" + hashlib.sha256(domain + _canonical_bytes(value)).hexdigest()


def pod_spec_id(value: Any, component: str) -> str:
    if not isinstance(value, dict):
        raise EvidenceError("Pod spec is not an object")
    if component not in CORE_COMPONENTS:
        raise EvidenceError("Pod spec component is invalid")
    normalized = copy.deepcopy(value)
    # Scheduling assigns this per Pod after the reviewed template is chosen;
    # every other field remains bound so command, arguments, environment,
    # security context, injected containers, volumes, and service identity
    # cannot change without a new reviewed digest.
    assigned_node = normalized.pop("nodeName", None)
    if assigned_node is not None and (
        not isinstance(assigned_node, str)
        or not assigned_node
        or len(assigned_node) > 253
    ):
        raise EvidenceError("assigned Pod node is invalid")
    if component == "otel-collector":
        affinity = normalized.get("affinity")
        if affinity is not None:
            if not isinstance(affinity, dict):
                raise EvidenceError("DaemonSet Pod affinity is invalid")
            node_affinity = affinity.get("nodeAffinity")
            if node_affinity is not None:
                if not isinstance(node_affinity, dict):
                    raise EvidenceError("DaemonSet Pod node affinity is invalid")
                required = node_affinity.get(
                    "requiredDuringSchedulingIgnoredDuringExecution"
                )
                if required is not None:
                    expected_keys = {"nodeSelectorTerms"}
                    if not isinstance(required, dict) or set(required) != expected_keys:
                        raise EvidenceError("DaemonSet target-node affinity is invalid")
                    terms = required["nodeSelectorTerms"]
                    if not isinstance(terms, list) or len(terms) != 1:
                        raise EvidenceError("DaemonSet target-node affinity is invalid")
                    term = terms[0]
                    if not isinstance(term, dict) or set(term) != {"matchFields"}:
                        raise EvidenceError("DaemonSet target-node affinity is invalid")
                    fields = term["matchFields"]
                    if not isinstance(fields, list) or len(fields) != 1:
                        raise EvidenceError("DaemonSet target-node affinity is invalid")
                    field = fields[0]
                    if (
                        not isinstance(field, dict)
                        or set(field) != {"key", "operator", "values"}
                        or field["key"] != "metadata.name"
                        or field["operator"] != "In"
                        or not isinstance(field["values"], list)
                        or len(field["values"]) != 1
                        or not isinstance(field["values"][0], str)
                        or not field["values"][0]
                        or len(field["values"][0]) > 253
                        or assigned_node is None
                        or field["values"] != [assigned_node]
                    ):
                        raise EvidenceError("DaemonSet target-node affinity is invalid")
                    del node_affinity[
                        "requiredDuringSchedulingIgnoredDuringExecution"
                    ]
                    if not node_affinity:
                        del affinity["nodeAffinity"]
                    if not affinity:
                        del normalized["affinity"]
    return _hash_id(b"pakperk-deployment-pod-spec-v1\0", normalized)


def _content_id(value: Mapping[str, Any]) -> str:
    payload = dict(value)
    payload["content_id"] = ""
    return CONTENT_PREFIX + hashlib.sha256(CONTENT_DOMAIN + _canonical_bytes(payload)).hexdigest()


def _validate_image(value: Any, label: str) -> dict[str, str]:
    item = _exact(value, {"repository", "digest"}, label)
    return {
        "repository": _repository(item["repository"], f"{label} repository"),
        "digest": _sha256(item["digest"], f"{label} digest"),
    }


def validate_promotion_handoff(value: Any) -> dict[str, Any]:
    root = _exact(
        value,
        {"schema", "environment", "source_revision", "scan_handoff", "helm_values"},
        "promotion handoff",
    )
    if root["schema"] != 1 or isinstance(root["schema"], bool):
        raise EvidenceError("promotion handoff schema is unsupported")
    environment = root["environment"]
    if environment not in ENVIRONMENTS:
        raise EvidenceError("promotion environment is invalid")
    revision = root["source_revision"]
    if not isinstance(revision, str) or REVISION_RE.fullmatch(revision) is None:
        raise EvidenceError("promotion source revision is invalid")
    scan = _exact(
        root["scan_handoff"],
        {"artifact_id", "artifact_digest", "manifest_sha256"},
        "scan handoff",
    )
    if not isinstance(scan["artifact_id"], str) or re.fullmatch(r"[1-9][0-9]{0,19}", scan["artifact_id"]) is None:
        raise EvidenceError("scan handoff artifact ID is invalid")
    for key in ("artifact_digest", "manifest_sha256"):
        if not isinstance(scan[key], str) or re.fullmatch(r"[0-9a-f]{64}", scan[key]) is None:
            raise EvidenceError("scan handoff digest is invalid")
        if len(set(scan[key])) == 1:
            raise EvidenceError("scan handoff digest is an obvious placeholder")
    helm_values = _exact(root["helm_values"], {"image", "siteImage"}, "promotion Helm values")
    backend = _validate_image(helm_values["image"], "promotion backend image")
    site = _validate_image(helm_values["siteImage"], "promotion site image")
    backend_match = re.fullmatch(r"ghcr\.io/([a-z0-9-]{1,64})/pakperk-backend", backend["repository"])
    site_match = re.fullmatch(r"ghcr\.io/([a-z0-9-]{1,64})/pakperk-site", site["repository"])
    if backend_match is None or site_match is None or backend_match.group(1) != site_match.group(1):
        raise EvidenceError("promotion images are outside the paired Pakperk repositories")
    return dict(root)


def _parse_embedded_json(value: Any, label: str) -> Any:
    text = _text(value, label, maximum=MAX_EVIDENCE_BYTES)
    parsed = strict_json(text.encode("utf-8"))
    try:
        encoded = text.encode("ascii", errors="strict")
    except UnicodeEncodeError as error:
        raise EvidenceError(f"{label} is not canonical ASCII JSON") from error
    if encoded != _canonical_bytes(parsed):
        raise EvidenceError(f"{label} is not canonical JSON")
    return parsed


def _validate_release_contract(value: Any, environment: str) -> dict[str, Any]:
    contract = _exact(
        value,
        {
            "schemaVersion",
            "environment",
            "features",
            "releaseEvidence",
            "alertPolicySha256",
            "images",
            "chart",
            "legalPolicy",
        },
        "release contract",
    )
    if contract["schemaVersion"] != 1 or isinstance(contract["schemaVersion"], bool):
        raise EvidenceError("release contract schema is unsupported")
    if contract["environment"] != environment:
        raise EvidenceError("release contract environment does not match")

    features = _exact(contract["features"], FEATURE_KEYS, "release features")
    if any(not isinstance(value, bool) for value in features.values()):
        raise EvidenceError("release feature is not boolean")
    if features["library"] and not features["accounts"]:
        raise EvidenceError("release feature dependencies are invalid")
    if features["libraryWrites"] and not features["library"]:
        raise EvidenceError("release feature dependencies are invalid")
    if features["comments"] and not features["accounts"]:
        raise EvidenceError("release feature dependencies are invalid")
    if features["commentCreation"] and not features["comments"]:
        raise EvidenceError("release feature dependencies are invalid")
    if features["accountDeletion"] and not features["accounts"]:
        raise EvidenceError("release feature dependencies are invalid")
    if environment == "production" and features["accounts"] and not features["accountDeletion"]:
        raise EvidenceError("production account feature dependencies are invalid")
    if environment == "production" and features["comments"] and not features["accountDeletion"]:
        raise EvidenceError("production comment feature dependencies are invalid")

    release_evidence = _exact(
        contract["releaseEvidence"], RELEASE_EVIDENCE_KEYS, "release approvals"
    )
    required_approvals: set[str] = set()
    if environment == "production":
        required_approvals.update(
            {"legalReviewId", "reviewerFlowId", "strictContentReviewId"}
        )
        if features["comments"]:
            required_approvals.add("moderationReadinessId")
        if features["accountDeletion"]:
            required_approvals.update({"accountDeletionE2eId", "restoreDrillId"})
    for key, identifier in release_evidence.items():
        _sha256(
            identifier,
            f"release approval {key}",
            allow_empty=key not in required_approvals,
        )

    images = _exact(contract["images"], IMAGE_KEYS, "release images")
    for key in IMAGE_KEYS:
        _validate_image(images[key], f"release image {key}")

    chart = _exact(contract["chart"], {"name", "version", "appVersion"}, "chart identity")
    if chart["name"] != "pakperk":
        raise EvidenceError("release chart is not Pakperk")
    for key in ("version", "appVersion"):
        if not isinstance(chart[key], str) or SEMVER_RE.fullmatch(chart[key]) is None:
            raise EvidenceError(f"chart {key} is not a canonical semantic version")

    legal = _exact(
        contract["legalPolicy"],
        {"documentVersion", "termsVersion", "communityGuidelinesVersion", "fulltext"},
        "legal policy",
    )
    for key in ("documentVersion", "termsVersion", "communityGuidelinesVersion"):
        _safe_identifier(legal[key], f"legal policy {key}")
    if not (legal["documentVersion"] == legal["termsVersion"] == legal["communityGuidelinesVersion"]):
        raise EvidenceError("legal policy versions do not match")
    if legal["fulltext"] not in {"strict", "permissive"}:
        raise EvidenceError("full-text policy is invalid")
    if environment == "production" and legal["fulltext"] != "strict":
        raise EvidenceError("production full-text policy is not strict")

    alert = contract["alertPolicySha256"]
    _sha256(alert, "alert policy", allow_empty=environment == "staging")
    if environment == "production" and not alert:
        raise EvidenceError("production alert policy is unavailable")
    return dict(contract)


def validate_release_config_map(
    value: Any,
    *,
    environment: str,
    namespace: str,
    instance: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not isinstance(value, dict):
        raise EvidenceError("release ConfigMap is not an object")
    if value.get("apiVersion") != "v1" or value.get("kind") != "ConfigMap":
        raise EvidenceError("release ConfigMap kind is invalid")
    if value.get("immutable") is not True:
        raise EvidenceError("release ConfigMap is not immutable")
    metadata = value.get("metadata")
    if not isinstance(metadata, dict):
        raise EvidenceError("release ConfigMap metadata is invalid")
    name = metadata.get("name")
    if not isinstance(name, str) or len(name) > 253 or not name:
        raise EvidenceError("release ConfigMap name is invalid")
    if metadata.get("namespace") != namespace:
        raise EvidenceError("release ConfigMap namespace does not match")
    labels = metadata.get("labels")
    annotations = metadata.get("annotations")
    if not isinstance(labels, dict) or not isinstance(annotations, dict):
        raise EvidenceError("release ConfigMap labels or annotations are invalid")
    if labels.get("app.kubernetes.io/component") != "release-evidence":
        raise EvidenceError("release ConfigMap component label is invalid")
    if labels.get("app.kubernetes.io/instance") != instance:
        raise EvidenceError("release ConfigMap instance label does not match")
    app_name = labels.get("app.kubernetes.io/name")
    if not isinstance(app_name, str) or DNS_LABEL_RE.fullmatch(app_name) is None:
        raise EvidenceError("release ConfigMap application label is invalid")

    data = _exact(
        value.get("data"),
        {
            "environment",
            "enabledFeatures.json",
            "alertPolicySha256",
            "imageIdentities.json",
            "chartIdentity.json",
            "legalPolicy.json",
            "releaseContract.json",
            *RELEASE_EVIDENCE_KEYS,
        },
        "release ConfigMap data",
    )
    if data["environment"] != environment:
        raise EvidenceError("release ConfigMap environment does not match")
    contract = _validate_release_contract(
        _parse_embedded_json(data["releaseContract.json"], "release contract data"),
        environment,
    )
    mirrors = {
        "enabledFeatures.json": contract["features"],
        "imageIdentities.json": contract["images"],
        "chartIdentity.json": contract["chart"],
        "legalPolicy.json": contract["legalPolicy"],
    }
    for key, expected in mirrors.items():
        if _parse_embedded_json(data[key], f"release ConfigMap {key}") != expected:
            raise EvidenceError("release ConfigMap data mirror does not match contract")
    if data["alertPolicySha256"] != contract["alertPolicySha256"]:
        raise EvidenceError("release ConfigMap alert policy mirror does not match")
    for key in RELEASE_EVIDENCE_KEYS:
        if data[key] != contract["releaseEvidence"][key]:
            raise EvidenceError("release ConfigMap approval mirror does not match")

    contract_bytes = _canonical_bytes(contract)
    binding_sha = "sha256:" + hashlib.sha256(contract_bytes).hexdigest()
    approval_bytes = _canonical_bytes(contract["releaseEvidence"])
    approval_sha = "sha256:" + hashlib.sha256(approval_bytes).hexdigest()
    if annotations.get("pakperk.app/release-binding-schema") != "1":
        raise EvidenceError("release binding annotation schema is invalid")
    if annotations.get("pakperk.app/release-binding-sha256") != binding_sha:
        raise EvidenceError("release binding annotation digest does not match")
    if annotations.get("pakperk.app/release-evidence-sha256") != approval_sha:
        raise EvidenceError("release approval annotation digest does not match")
    binding_suffix = binding_sha.removeprefix("sha256:")[:12]
    if not name.endswith("-release-evidence-" + binding_suffix):
        raise EvidenceError("release ConfigMap name is not content-bound")
    chart = contract["chart"]
    if labels.get("app.kubernetes.io/version") != chart["appVersion"]:
        raise EvidenceError("release ConfigMap application version does not match")
    if labels.get("helm.sh/chart") != f"{chart['name']}-{chart['version']}":
        raise EvidenceError("release ConfigMap chart label does not match")
    return contract, {"name": name, "app_name": app_name, "binding_sha": binding_sha, "approval_sha": approval_sha}


def validate_observation(value: Any, promotion: Mapping[str, Any]) -> dict[str, Any]:
    observation = _exact(
        value,
        {
            "schema",
            "environment",
            "source_revision",
            "captured_at",
            "release_namespace",
            "release_instance",
            "cluster_identity",
            "expected_replicas",
            "expected_pod_specs",
            "controls",
            "ingress",
            "staging_smoke",
            "approval",
        },
        "deployment observation",
    )
    if observation["schema"] != 1 or isinstance(observation["schema"], bool):
        raise EvidenceError("deployment observation schema is unsupported")
    if observation["environment"] != promotion["environment"]:
        raise EvidenceError("deployment observation environment does not match")
    if observation["source_revision"] != promotion["source_revision"]:
        raise EvidenceError("deployment observation source revision does not match")
    _timestamp(observation["captured_at"], "deployment capture time")
    namespace = observation["release_namespace"]
    instance = observation["release_instance"]
    if not isinstance(namespace, str) or DNS_LABEL_RE.fullmatch(namespace) is None:
        raise EvidenceError("release namespace is invalid")
    if not isinstance(instance, str) or DNS_LABEL_RE.fullmatch(instance) is None:
        raise EvidenceError("release instance is invalid")
    _sha256(observation["cluster_identity"], "cluster identity")

    replicas = _exact(observation["expected_replicas"], set(CORE_COMPONENTS), "expected replicas")
    for component in CORE_COMPONENTS:
        minimum = 0 if component == "deletion-worker" else 1
        count = _integer(replicas[component], f"expected replicas for {component}", minimum=minimum, maximum=100)
        if observation["environment"] == "production" and component in {"api", "site", "telemetry-gateway"} and count < 2:
            raise EvidenceError("production replica floor is not met")
    expected_specs = _exact(
        observation["expected_pod_specs"],
        set(CORE_COMPONENTS),
        "expected Pod specs",
    )
    for component in CORE_COMPONENTS:
        identifier = expected_specs[component]
        if replicas[component] == 0 and identifier == "":
            continue
        _sha256(identifier, f"expected Pod spec for {component}")

    controls = _exact(observation["controls"], CONTROL_KEYS, "deployment control digests")
    for key, identifier in controls.items():
        _sha256(identifier, f"deployment control {key}")

    ingress = _exact(observation["ingress"], INGRESS_KEYS, "ingress observation")
    _repository(ingress["controller_repository"], "ingress controller repository")
    for key in ("controller_digest", "configuration_sha256", "review_reference"):
        _sha256(ingress[key], f"ingress {key}")

    smoke = _exact(observation["staging_smoke"], SMOKE_KEYS, "staging smoke")
    if smoke["environment"] != "staging" or smoke["source_revision"] != promotion["source_revision"]:
        raise EvidenceError("staging smoke source binding does not match")
    backend = promotion["helm_values"]["image"]["digest"]
    site = promotion["helm_values"]["siteImage"]["digest"]
    if smoke["backend_digest"] != backend or smoke["site_digest"] != site:
        raise EvidenceError("staging smoke candidate digests do not match")
    checks = _exact(smoke["checks"], SMOKE_CHECK_KEYS, "staging smoke checks")
    if any(outcome != "passed" for outcome in checks.values()):
        raise EvidenceError("staging smoke check did not pass")
    _sha256(smoke["reference"], "staging smoke reference")

    approval = _exact(observation["approval"], APPROVAL_KEYS, "platform approval")
    if approval["role"] != "platform_owner":
        raise EvidenceError("platform approval role is invalid")
    _sha256(approval["reference"], "platform approval reference")
    return dict(observation)


def _normalize_image_id(value: Any) -> tuple[str, str]:
    text = _text(value, "container image ID", maximum=512)
    if "://" in text:
        scheme, text = text.split("://", 1)
        if scheme not in {"docker-pullable", "containerd", "cri-o"}:
            raise EvidenceError("container image ID scheme is unsupported")
    if "@" not in text:
        raise EvidenceError("container image ID is not pullable by digest")
    repository, digest = text.rsplit("@", 1)
    _repository(repository, "container image ID repository")
    _sha256(digest, "container image ID digest")
    return repository, digest


def _runtime_image_matches(value: Any, expected_image: str) -> bool:
    expected_repository, expected_digest = expected_image.rsplit("@", 1)
    repository, digest = _normalize_image_id(value)
    if digest != expected_digest:
        return False
    repositories = {expected_repository}
    if "." not in expected_repository.split("/", 1)[0] and ":" not in expected_repository.split("/", 1)[0]:
        repositories.add(f"docker.io/{expected_repository}")
        repositories.add(f"index.docker.io/{expected_repository}")
    return repository in repositories


def _status_by_name(value: Any, label: str) -> dict[str, Mapping[str, Any]]:
    if value is None:
        return {}
    if not isinstance(value, list) or len(value) > 32:
        raise EvidenceError(f"{label} is not a bounded list")
    result: dict[str, Mapping[str, Any]] = {}
    for item in value:
        if not isinstance(item, dict):
            raise EvidenceError(f"{label} member is invalid")
        name = _safe_identifier(item.get("name"), f"{label} name")
        if name in result:
            raise EvidenceError(f"{label} has a duplicate name")
        result[name] = item
    return result


def _validate_pod_containers(pod: Mapping[str, Any], expected_image: str) -> None:
    spec = pod.get("spec")
    status = pod.get("status")
    if not isinstance(spec, dict) or not isinstance(status, dict):
        raise EvidenceError("Pod spec or status is invalid")
    containers = spec.get("containers")
    if not isinstance(containers, list) or not containers or len(containers) > 16:
        raise EvidenceError("Pod containers are invalid")
    main_status = _status_by_name(status.get("containerStatuses"), "container status")
    main_names: set[str] = set()
    for container in containers:
        if not isinstance(container, dict):
            raise EvidenceError("Pod container is invalid")
        name = _safe_identifier(container.get("name"), "container name")
        if name in main_names:
            raise EvidenceError("Pod has duplicate container names")
        main_names.add(name)
        if container.get("image") != expected_image:
            raise EvidenceError("Pod spec image does not match release binding")
        current = main_status.get(name)
        if current is None or current.get("ready") is not True:
            raise EvidenceError("Pod container is not ready")
        _integer(current.get("restartCount"), "container restart count", maximum=1_000_000)
        if not _runtime_image_matches(current.get("imageID"), expected_image):
            raise EvidenceError("runtime container image ID does not match release binding")
    if set(main_status) != main_names:
        raise EvidenceError("Pod container status set does not match spec")

    init_containers = spec.get("initContainers", [])
    if not isinstance(init_containers, list) or len(init_containers) > 16:
        raise EvidenceError("Pod init containers are invalid")
    init_status = _status_by_name(status.get("initContainerStatuses"), "init container status")
    init_names: set[str] = set()
    for container in init_containers:
        if not isinstance(container, dict):
            raise EvidenceError("Pod init container is invalid")
        name = _safe_identifier(container.get("name"), "init container name")
        if name in init_names:
            raise EvidenceError("Pod has duplicate init container names")
        init_names.add(name)
        if container.get("image") != expected_image:
            raise EvidenceError("Pod init image does not match release binding")
        current = init_status.get(name)
        terminated = current.get("state", {}).get("terminated") if current else None
        if not isinstance(terminated, dict) or terminated.get("exitCode") != 0:
            raise EvidenceError("Pod init container did not complete successfully")
        if not _runtime_image_matches(current.get("imageID"), expected_image):
            raise EvidenceError("runtime init image ID does not match release binding")
    if set(init_status) != init_names:
        raise EvidenceError("Pod init status set does not match spec")


def validate_pods(
    value: Any,
    *,
    namespace: str,
    instance: str,
    app_name: str,
    expected_replicas: Mapping[str, Any],
    expected_pod_specs: Mapping[str, Any],
    contract: Mapping[str, Any],
) -> list[dict[str, Any]]:
    if not isinstance(value, dict) or value.get("apiVersion") != "v1" or value.get("kind") not in {"List", "PodList"}:
        raise EvidenceError("Kubernetes PodList kind is invalid")
    items = value.get("items")
    if not isinstance(items, list) or len(items) > 1000:
        raise EvidenceError("Kubernetes PodList is not bounded")
    images = contract["images"]
    records: dict[str, list[dict[str, str]]] = {component: [] for component in CORE_COMPONENTS}
    observed_specs: dict[str, set[str]] = {component: set() for component in CORE_COMPONENTS}
    observed_owners: dict[str, set[tuple[str, str]]] = {
        component: set() for component in CORE_COMPONENTS
    }
    seen_names: set[str] = set()
    for pod in items:
        if not isinstance(pod, dict) or pod.get("apiVersion") != "v1" or pod.get("kind") != "Pod":
            raise EvidenceError("PodList contains a non-Pod object")
        metadata = pod.get("metadata")
        if not isinstance(metadata, dict):
            raise EvidenceError("Pod metadata is invalid")
        labels = metadata.get("labels")
        if not isinstance(labels, dict):
            continue
        if metadata.get("namespace") != namespace or labels.get("app.kubernetes.io/instance") != instance:
            continue
        if labels.get("app.kubernetes.io/name") != app_name:
            raise EvidenceError("selected Pod application label does not match release binding")
        if metadata.get("deletionTimestamp") is not None:
            raise EvidenceError("selected release Pod is terminating")
        component = labels.get("app.kubernetes.io/component")
        if component not in ALL_COMPONENTS:
            raise EvidenceError("selected Pod has an unknown component")
        status = pod.get("status")
        if not isinstance(status, dict):
            raise EvidenceError("selected Pod status is invalid")
        phase = status.get("phase")
        if component in EPHEMERAL_COMPONENTS:
            if phase == "Succeeded":
                continue
            raise EvidenceError("ephemeral release workload is not settled")
        if phase != "Running":
            raise EvidenceError("selected release Pod is not running")
        conditions = status.get("conditions")
        if not isinstance(conditions, list):
            raise EvidenceError("selected Pod conditions are invalid")
        ready_conditions = [
            condition
            for condition in conditions
            if isinstance(condition, dict) and condition.get("type") == "Ready"
        ]
        if len(ready_conditions) != 1 or ready_conditions[0].get("status") != "True":
            raise EvidenceError("selected release Pod is not Ready")
        name = metadata.get("name")
        uid = metadata.get("uid")
        if not isinstance(name, str) or len(name) > 253 or not name or name in seen_names:
            raise EvidenceError("selected Pod name is invalid or duplicated")
        if not isinstance(uid, str) or UUID_RE.fullmatch(uid) is None:
            raise EvidenceError("selected Pod UID is invalid")
        owner_references = metadata.get("ownerReferences")
        if not isinstance(owner_references, list) or len(owner_references) > 8:
            raise EvidenceError("selected Pod owner references are invalid")
        controller_owners = [
            owner
            for owner in owner_references
            if isinstance(owner, dict) and owner.get("controller") is True
        ]
        if len(controller_owners) != 1:
            raise EvidenceError("selected Pod lacks one controller owner")
        owner = controller_owners[0]
        expected_owner_kind = (
            "DaemonSet" if component == "otel-collector" else "ReplicaSet"
        )
        if (
            owner.get("apiVersion") != "apps/v1"
            or owner.get("kind") != expected_owner_kind
            or owner.get("blockOwnerDeletion") is not True
        ):
            raise EvidenceError("selected Pod controller owner is invalid")
        owner_name = owner.get("name")
        owner_uid = owner.get("uid")
        if (
            not isinstance(owner_name, str)
            or not owner_name
            or len(owner_name) > 253
            or not isinstance(owner_uid, str)
            or UUID_RE.fullmatch(owner_uid) is None
        ):
            raise EvidenceError("selected Pod controller identity is invalid")
        seen_names.add(name)
        image = images[COMPONENT_IMAGE[component]]
        expected_image = f"{image['repository']}@{image['digest']}"
        _validate_pod_containers(pod, expected_image)
        spec_identifier = pod_spec_id(pod.get("spec"), component)
        if spec_identifier != expected_pod_specs[component]:
            raise EvidenceError("runtime Pod spec does not match reviewed expectation")
        observed_specs[component].add(spec_identifier)
        observed_owners[component].add((expected_owner_kind, owner_uid))
        records[component].append(
            {
                "name": name,
                "uid": uid,
                "image": expected_image,
                "owner_kind": expected_owner_kind,
                "owner_name": owner_name,
                "owner_uid": owner_uid,
            }
        )

    workloads: list[dict[str, Any]] = []
    for component in CORE_COMPONENTS:
        expected = _integer(expected_replicas[component], f"expected replicas for {component}", maximum=100)
        observed = records[component]
        if len(observed) != expected:
            raise EvidenceError("settled Pod replica count does not match expectation")
        if expected == 0:
            continue
        if observed_specs[component] != {expected_pod_specs[component]}:
            raise EvidenceError("runtime Pod specs are not one reviewed template")
        if len(observed_owners[component]) != 1:
            raise EvidenceError("runtime Pods do not share one settled controller")
        image = images[COMPONENT_IMAGE[component]]
        pod_digest = _hash_id(
            b"pakperk-deployment-pod-set-v1\0",
            sorted(observed, key=lambda item: (item["name"], item["uid"])),
        )
        workloads.append(
            {
                "component": component,
                "replicas": expected,
                "ready_replicas": expected,
                "image_repository": image["repository"],
                "image_digest": image["digest"],
                "pod_set_sha256": pod_digest,
                "pod_spec_sha256": expected_pod_specs[component],
            }
        )
    if contract["features"]["accountDeletion"] and expected_replicas["deletion-worker"] < 1:
        raise EvidenceError("account deletion is enabled without a deletion worker")
    if not contract["features"]["accountDeletion"] and expected_replicas["deletion-worker"] != 0:
        raise EvidenceError("deletion worker expectation is enabled without account deletion")
    return workloads


def build_evidence(
    promotion_bytes: bytes,
    config_map_bytes: bytes,
    pods_bytes: bytes,
    observation_bytes: bytes,
) -> dict[str, Any]:
    promotion = validate_promotion_handoff(strict_json(promotion_bytes, require_canonical=True))
    observation = validate_observation(strict_json(observation_bytes, require_canonical=True), promotion)
    config_map = strict_json(config_map_bytes)
    contract, config_identity = validate_release_config_map(
        config_map,
        environment=promotion["environment"],
        namespace=observation["release_namespace"],
        instance=observation["release_instance"],
    )
    for key, promotion_key in (("backend", "image"), ("site", "siteImage")):
        if contract["images"][key] != promotion["helm_values"][promotion_key]:
            raise EvidenceError("release binding images do not match promotion handoff")
    workloads = validate_pods(
        strict_json(pods_bytes),
        namespace=observation["release_namespace"],
        instance=observation["release_instance"],
        app_name=config_identity["app_name"],
        expected_replicas=observation["expected_replicas"],
        expected_pod_specs=observation["expected_pod_specs"],
        contract=contract,
    )
    release = {
        "config_map_sha256": "sha256:" + hashlib.sha256(config_map_bytes).hexdigest(),
        "release_binding_sha256": config_identity["binding_sha"],
        "release_evidence_sha256": config_identity["approval_sha"],
        "chart": contract["chart"],
        "features": contract["features"],
        "release_evidence": contract["releaseEvidence"],
        "alert_policy_sha256": contract["alertPolicySha256"],
        "images": contract["images"],
        "legal_policy": contract["legalPolicy"],
    }
    evidence: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "content_id": "",
        "binding": {
            "environment": promotion["environment"],
            "source_revision": promotion["source_revision"],
            "captured_at": observation["captured_at"],
            "cluster_identity": observation["cluster_identity"],
            "release_namespace_sha256": _hash_id(
                b"pakperk-deployment-namespace-v1\0", observation["release_namespace"]
            ),
            "release_instance_sha256": _hash_id(
                b"pakperk-deployment-instance-v1\0", observation["release_instance"]
            ),
            "promotion_handoff_sha256": "sha256:" + hashlib.sha256(promotion_bytes).hexdigest(),
            "scan_handoff": promotion["scan_handoff"],
        },
        "release": release,
        "workloads": workloads,
        "ingress": observation["ingress"],
        "controls": observation["controls"],
        "staging_smoke": observation["staging_smoke"],
        "approval": observation["approval"],
        "scope": dict(SCOPE),
        "sanitization": dict(SANITIZATION),
    }
    evidence["content_id"] = _content_id(evidence)
    return validate_evidence(evidence)


def validate_evidence(value: Any) -> dict[str, Any]:
    root = _exact(value, ROOT_KEYS, "deployment evidence")
    if root["schema_version"] != SCHEMA_VERSION or isinstance(root["schema_version"], bool):
        raise EvidenceError("deployment evidence schema is unsupported")
    content_id = root["content_id"]
    if not isinstance(content_id, str) or CONTENT_ID_RE.fullmatch(content_id) is None:
        raise EvidenceError("deployment evidence content ID is invalid")

    binding = _exact(root["binding"], BINDING_KEYS, "deployment binding")
    if binding["environment"] not in ENVIRONMENTS:
        raise EvidenceError("deployment evidence environment is invalid")
    if not isinstance(binding["source_revision"], str) or REVISION_RE.fullmatch(binding["source_revision"]) is None:
        raise EvidenceError("deployment evidence source revision is invalid")
    _timestamp(binding["captured_at"], "deployment evidence capture time")
    for key in (
        "cluster_identity",
        "release_namespace_sha256",
        "release_instance_sha256",
        "promotion_handoff_sha256",
    ):
        _sha256(binding[key], f"deployment binding {key}")
    scan = _exact(
        binding["scan_handoff"],
        {"artifact_id", "artifact_digest", "manifest_sha256"},
        "deployment scan handoff",
    )
    if not isinstance(scan["artifact_id"], str) or re.fullmatch(r"[1-9][0-9]{0,19}", scan["artifact_id"]) is None:
        raise EvidenceError("deployment scan artifact ID is invalid")
    for key in ("artifact_digest", "manifest_sha256"):
        if not isinstance(scan[key], str) or re.fullmatch(r"[0-9a-f]{64}", scan[key]) is None or len(set(scan[key])) == 1:
            raise EvidenceError("deployment scan digest is invalid")

    release = _exact(root["release"], RELEASE_KEYS, "deployment release binding")
    for key in ("config_map_sha256", "release_binding_sha256", "release_evidence_sha256"):
        _sha256(release[key], f"deployment release {key}")
    contract = {
        "schemaVersion": 1,
        "environment": binding["environment"],
        "features": release["features"],
        "releaseEvidence": release["release_evidence"],
        "alertPolicySha256": release["alert_policy_sha256"],
        "images": release["images"],
        "chart": release["chart"],
        "legalPolicy": release["legal_policy"],
    }
    validated_contract = _validate_release_contract(contract, binding["environment"])
    expected_binding = "sha256:" + hashlib.sha256(_canonical_bytes(validated_contract)).hexdigest()
    expected_approvals = "sha256:" + hashlib.sha256(_canonical_bytes(validated_contract["releaseEvidence"])).hexdigest()
    if release["release_binding_sha256"] != expected_binding or release["release_evidence_sha256"] != expected_approvals:
        raise EvidenceError("deployment release digest does not match its closed contract")

    workloads = root["workloads"]
    if not isinstance(workloads, list) or not 6 <= len(workloads) <= len(CORE_COMPONENTS):
        raise EvidenceError("deployment workload inventory is invalid")
    expected_order = [component for component in CORE_COMPONENTS if component != "deletion-worker"]
    if release["features"]["accountDeletion"]:
        expected_order = list(CORE_COMPONENTS)
    actual_order: list[str] = []
    for workload in workloads:
        item = _exact(workload, WORKLOAD_KEYS, "deployment workload")
        component = item["component"]
        if component not in CORE_COMPONENTS or component in actual_order:
            raise EvidenceError("deployment workload component is invalid or duplicated")
        actual_order.append(component)
        replicas = _integer(item["replicas"], "deployment workload replicas", minimum=1, maximum=100)
        if _integer(item["ready_replicas"], "deployment workload ready replicas", minimum=1, maximum=100) != replicas:
            raise EvidenceError("deployment workload is not fully ready")
        image_key = COMPONENT_IMAGE[component]
        image = release["images"][image_key]
        if item["image_repository"] != image["repository"] or item["image_digest"] != image["digest"]:
            raise EvidenceError("deployment workload image does not match release binding")
        _sha256(item["pod_set_sha256"], "deployment workload Pod-set digest")
        _sha256(item["pod_spec_sha256"], "deployment workload Pod-spec digest")
    if actual_order != expected_order:
        raise EvidenceError("deployment workload order or required set is invalid")
    if binding["environment"] == "production":
        counts = {item["component"]: item["replicas"] for item in workloads}
        if any(counts[component] < 2 for component in ("api", "site", "telemetry-gateway")):
            raise EvidenceError("production workload replica floor is not met")

    ingress = _exact(root["ingress"], INGRESS_KEYS, "deployment ingress evidence")
    _repository(ingress["controller_repository"], "deployment ingress repository")
    for key in ("controller_digest", "configuration_sha256", "review_reference"):
        _sha256(ingress[key], f"deployment ingress {key}")
    controls = _exact(root["controls"], CONTROL_KEYS, "deployment controls")
    for key, identifier in controls.items():
        _sha256(identifier, f"deployment control {key}")
    smoke = _exact(root["staging_smoke"], SMOKE_KEYS, "deployment staging smoke")
    if smoke["environment"] != "staging" or smoke["source_revision"] != binding["source_revision"]:
        raise EvidenceError("deployment staging smoke source does not match")
    if smoke["backend_digest"] != release["images"]["backend"]["digest"] or smoke["site_digest"] != release["images"]["site"]["digest"]:
        raise EvidenceError("deployment staging smoke images do not match")
    checks = _exact(smoke["checks"], SMOKE_CHECK_KEYS, "deployment staging smoke checks")
    if any(outcome != "passed" for outcome in checks.values()):
        raise EvidenceError("deployment staging smoke is not passing")
    _sha256(smoke["reference"], "deployment staging smoke reference")
    approval = _exact(root["approval"], APPROVAL_KEYS, "deployment platform approval")
    if approval["role"] != "platform_owner":
        raise EvidenceError("deployment platform approval role is invalid")
    _sha256(approval["reference"], "deployment platform approval reference")
    if root["scope"] != SCOPE or set(root["scope"]) != SCOPE_KEYS:
        raise EvidenceError("deployment evidence scope is invalid")
    if root["sanitization"] != SANITIZATION or set(root["sanitization"]) != SANITIZATION_KEYS:
        raise EvidenceError("deployment evidence sanitization contract is invalid")
    if content_id != _content_id(root):
        raise EvidenceError("deployment evidence content ID does not match")
    return dict(root)


def read_evidence(path: Path) -> dict[str, Any]:
    data = _read_regular(path, max_bytes=MAX_EVIDENCE_BYTES)
    value = strict_json(data, require_canonical=True)
    return validate_evidence(value)


def write_evidence(path: Path, evidence: Mapping[str, Any]) -> None:
    validated = validate_evidence(evidence)
    encoded = _canonical_bytes(validated, newline=True)
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("deployment evidence is oversized")
    _write_exclusive(path, encoded)


def build_from_paths(
    promotion_path: Path,
    config_map_path: Path,
    pods_path: Path,
    observation_path: Path,
) -> dict[str, Any]:
    return build_evidence(
        _read_regular(promotion_path),
        _read_regular(config_map_path),
        _read_regular(pods_path),
        _read_regular(observation_path),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "verify"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--promotion-handoff", type=Path, required=True)
        sub.add_argument("--release-config-map", type=Path, required=True)
        sub.add_argument("--pods", type=Path, required=True)
        sub.add_argument("--observation", type=Path, required=True)
        if command == "build":
            sub.add_argument("--output", type=Path, required=True)
        else:
            sub.add_argument("--evidence", type=Path, required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--evidence", type=Path, required=True)
    pod_spec = subparsers.add_parser(
        "pod-spec-id",
        help="derive the retained digest for one reviewed API-defaulted Pod",
    )
    pod_spec.add_argument("--component", choices=CORE_COMPONENTS, required=True)
    pod_spec.add_argument("--pod", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "pod-spec-id":
            pod = strict_json(_read_regular(arguments.pod))
            if (
                not isinstance(pod, dict)
                or pod.get("apiVersion") != "v1"
                or pod.get("kind") != "Pod"
            ):
                raise EvidenceError("Pod-spec input is not one Kubernetes Pod")
            print(pod_spec_id(pod.get("spec"), arguments.component))
            return 0
        if arguments.command == "validate":
            evidence = read_evidence(arguments.evidence)
        else:
            expected = build_from_paths(
                arguments.promotion_handoff,
                arguments.release_config_map,
                arguments.pods,
                arguments.observation,
            )
            if arguments.command == "build":
                write_evidence(arguments.output, expected)
                evidence = expected
            else:
                evidence = read_evidence(arguments.evidence)
                if _canonical_bytes(evidence) != _canonical_bytes(expected):
                    raise EvidenceError("deployment evidence does not match supplied captures")
        print(evidence["content_id"])
        return 0
    except EvidenceError as error:
        print(f"deployment binding evidence rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
