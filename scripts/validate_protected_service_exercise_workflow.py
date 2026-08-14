#!/usr/bin/env python3
"""Validate the fail-closed protected service-exercise workflow surface."""

from __future__ import annotations

import hashlib
import os
import pathlib
import re
import stat
import sys
from typing import Sequence


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/protected-service-exercise.yml"
MAX_WORKFLOW_BYTES = 64 * 1024
EXPECTED_WORKFLOW_SHA256 = "46d0fdb98e5fd938c16735c59866061573af3fe50d287860e05aeb6920574c5c"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
DRIVER_REQUEST_CONTRACT_SHA256 = (
    "sha256:e49f4ef9e1680b1682f5f4f72af0bbd63a98fc0b34e7b4684e713bca45630f48"
)

EXPECTED_INPUTS = (
    "source_revision",
    "candidate_id",
    "deployment_evidence_id",
    "confirmation",
)
EXPECTED_STEPS = (
    "Verify exact reviewed main source and protected bindings",
    "Verify root-owned protected driver and validator",
    "Validate fresh root-owned protected runner session",
    "Run protected exercise through the data-only driver handoff",
    "Validate exact sanitized protected exercise evidence",
    "Upload validated protected service exercise evidence",
    "Enforce protected service exercise result",
)


def _read(path: pathlib.Path) -> bytes:
    metadata = os.lstat(path)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or not 0 < metadata.st_size <= MAX_WORKFLOW_BYTES
    ):
        raise RuntimeError("protected workflow must be one bounded regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = MAX_WORKFLOW_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise RuntimeError("protected workflow exceeds the byte boundary")
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = os.lstat(path)
    identity = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
    )
    data = b"".join(chunks)
    if (
        identity(metadata) != identity(before)
        or identity(before) != identity(after)
        or identity(after) != identity(current)
        or len(data) != before.st_size
    ):
        raise RuntimeError("protected workflow changed while it was read")
    if b"\r" in data or not data.endswith(b"\n"):
        raise RuntimeError("protected workflow must use canonical LF text")
    try:
        data.decode("ascii")
    except UnicodeError as error:
        raise RuntimeError("protected workflow must be bounded ASCII text") from error
    return data


def _require(source: str, fragment: str, label: str) -> None:
    if source.count(fragment) != 1:
        raise RuntimeError(f"{label} must appear exactly once")


def _step(source: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if source.count(marker) != 1:
        raise RuntimeError("protected workflow step surface changed")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def _validate_trigger_and_job(source: str) -> None:
    if not source.startswith("name: protected service exercise\n\non:\n"):
        raise RuntimeError("protected workflow name or trigger boundary changed")
    for forbidden in (
        "\n  push:",
        "\n  pull_request:",
        "\n  pull_request_target:",
        "\n  schedule:",
        "\n  workflow_call:",
        "\n  repository_dispatch:",
    ):
        if forbidden in source:
            raise RuntimeError("protected workflow must be manual-dispatch only")
    observed_inputs = re.findall(r"(?m)^      ([a-z][a-z0-9_]*):$", source)
    if tuple(observed_inputs[: len(EXPECTED_INPUTS)]) != EXPECTED_INPUTS:
        raise RuntimeError("protected dispatch inputs changed or were reordered")
    if len(observed_inputs) != len(EXPECTED_INPUTS):
        raise RuntimeError("protected dispatch input surface is not closed")
    for input_name in EXPECTED_INPUTS:
        block_start = source.index(f"      {input_name}:\n")
        remainder = source[block_start + 1 :]
        next_input = re.search(r"(?m)^      [a-z][a-z0-9_]*:$", remainder)
        next_start = (
            block_start + 1 + next_input.start()
            if next_input is not None
            else -1
        )
        permissions_start = source.find("\npermissions:\n", block_start)
        block_end = min(item for item in (next_start, permissions_start) if item >= 0)
        block = source[block_start:block_end]
        if block.count("        required: true\n") != 1 or block.count("        type: string\n") != 1:
            raise RuntimeError("every protected dispatch input must be one required string")
    _require(source, "permissions:\n  contents: read\n", "read-only permissions")
    if source.count("\npermissions:\n") != 1 or re.search(r"(?m)^    permissions:", source):
        raise RuntimeError("protected workflow permissions surface changed")
    _require(source, "  group: protected-service-exercise\n  cancel-in-progress: false\n", "non-cancelling concurrency")
    _require(
        source,
        "    runs-on: [self-hosted, Linux, pakperk-protected-service-exercise]\n",
        "protected self-hosted runner",
    )
    _require(
        source,
        "    environment: protected-staging-service-exercise\n",
        "protected GitHub environment",
    )
    _require(source, "    timeout-minutes: 360\n", "bounded job timeout")


def _validate_actions_and_steps(source: str) -> None:
    actions = re.findall(r"(?m)^\s+(?:- )?uses: ([^ #]+)", source)
    if actions != [CHECKOUT_ACTION, UPLOAD_ACTION]:
        raise RuntimeError("workflow must use only the two reviewed pinned actions")
    checkout = source[source.index(f"      - uses: {CHECKOUT_ACTION}") :]
    checkout = checkout[: checkout.index("\n\n      - name:")]
    for fragment in (
        "          ref: ${{ inputs.source_revision }}",
        "          fetch-depth: 0",
        "          persist-credentials: false",
    ):
        if checkout.count(fragment) != 1:
            raise RuntimeError("exact-source checkout contract changed")
    names = tuple(re.findall(r"(?m)^      - name: (.+)$", source))
    if names != EXPECTED_STEPS:
        raise RuntimeError("protected workflow steps changed or were reordered")
    if source.count("        run: |\n") != 6:
        raise RuntimeError("protected workflow executable surface changed")
    if re.findall(r"(?m)^        shell: (.+)$", source) != ["bash"] * 6:
        raise RuntimeError("all protected executable steps must use Bash")
    if re.findall(r"(?m)^        continue-on-error: (.+)$", source) != [
        "true",
        "true",
        "true",
    ]:
        raise RuntimeError("protected recoverable-step surface changed")
    if re.findall(r"(?m)^        if: (.+)$", source) != [
        "steps.exercise.outcome == 'success'",
        "steps.evidence.outcome == 'success'",
        "always()",
    ]:
        raise RuntimeError("protected validation, upload, or enforcement guard changed")


def _validate_trust_boundary(source: str) -> None:
    if re.search(r"\$\{\{\s*secrets\.", source):
        raise RuntimeError("protected workflow must not expose GitHub secrets")
    for forbidden in (
        "${{ github.token }}",
        "${{ github.workspace }}",
        "$GITHUB_WORKSPACE",
        "scripts/",
        " curl ",
        " wget ",
        " kubectl ",
        " helm ",
        " psql ",
        "set -x",
        "set -o xtrace",
        "bash -x",
        "printenv",
        "nohup ",
        "disown",
        "setsid ",
        "eval ",
    ):
        if forbidden in source:
            raise RuntimeError("candidate workflow crossed the protected data-only boundary")
    if re.search(r"(?m)^ {10}(?:source|\.)[ \t]+", source):
        raise RuntimeError("protected workflow may not source candidate-authored files")
    if re.search(r"(?m)^ {10}[^#\n]*[^&]&[ \t]*$", source):
        raise RuntimeError("protected workflow may not launch a background process")
    _require(
        source,
        "exec /usr/bin/env -i \\\n",
        "empty-environment protected driver execution",
    )
    _require(
        source,
        "/opt/pakperk/bin/pakperk-protected-service-exercise-driver run \\\n",
        "root-owned protected driver execution",
    )
    if source.count("/opt/pakperk/bin/pakperk-protected-service-exercise-driver") != 2:
        raise RuntimeError("root-owned driver path surface changed")
    if source.count("/opt/pakperk/bin/pakperk-protected-service-exercise-validator.py") != 3:
        raise RuntimeError("root-owned validator path surface changed")
    _require(
        source,
        "unset GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY RUNNER_TEMP\n",
        "driver command-file isolation",
    )
    driver = _step(source, EXPECTED_STEPS[3])
    if (
        "${{ secrets." in driver
        or "exec /usr/bin/env -i" not in driver
        or "PAKPERK_PROTECTED_DATA_ONLY_HANDOFF=1" not in driver
    ):
        raise RuntimeError("protected driver invocation is not credential-free and root-owned")
    for fragment in (
        '"evidence_schema_version": 1',
        '"assertion_count": 29',
        '"measurement_count": 20',
        '"switch_case_count": 6',
        '"invalid_dependency_case_count": 6',
        '"contract_sha256": os.environ["DRIVER_REQUEST_CONTRACT_SHA256"]',
        '"real_protected_observations_required": True',
        '"approved_synthetic_fixtures_only": True',
        '"post_run_owner_approvals_required": True',
        '"raw_credentials_tokens_cookies_network_addresses_ugc_logs_and_operator_identity_forbidden": True',
    ):
        if driver.count(fragment) != 1:
            raise RuntimeError("protected driver request policy changed")


def _validate_bindings(source: str) -> None:
    source_step = _step(source, EXPECTED_STEPS[0])
    for fragment in (
        '[[ "$DISPATCH_REF" != "refs/heads/main" ]]',
        '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
        '$(/usr/bin/git rev-parse HEAD)',
        '$(/usr/bin/git rev-parse refs/remotes/origin/main)',
        "^deployment-binding-v1:sha256:[0-9a-f]{64}$",
        "/usr/bin/sha256sum .github/workflows/protected-service-exercise.yml",
        '[[ "$observed_workflow_sha" != "$WORKFLOW_SHA256" ]]',
        "challenge = secrets.token_hex(32)",
    ):
        if fragment not in source_step:
            raise RuntimeError("exact-main or fresh-challenge source binding changed")
    for name in (
        "PAKPERK_PROTECTED_SERVICE_RUNNER_SESSION_ID",
        "PAKPERK_PROTECTED_SERVICE_DRIVER_SHA256",
        "PAKPERK_PROTECTED_SERVICE_VALIDATOR_SHA256",
        "PAKPERK_PROTECTED_SERVICE_WORKFLOW_SHA256",
    ):
        _require(source, f"${{{{ vars.{name} }}}}", "protected environment variable binding")
    _require(
        source,
        f"      DRIVER_REQUEST_CONTRACT_SHA256: {DRIVER_REQUEST_CONTRACT_SHA256}\n",
        "protected driver request contract digest",
    )

    session = _step(source, EXPECTED_STEPS[2])
    for fragment in (
        'runner_session_digest="${RUNNER_SESSION_ID#sha256:}"',
        'runner_session_manifest="/opt/pakperk/protected-service-runner-sessions/${runner_session_digest}.json"',
        "/usr/bin/env -i \\\n",
        "validate-session \\\n",
        '"$runner_session_manifest" \\\n',
        '--session-id "$RUNNER_SESSION_ID" \\\n',
        '--source-revision "$REQUESTED_REVISION"',
    ):
        if session.count(fragment) != 1:
            raise RuntimeError("protected runner-session import contract changed")

    evidence = _step(source, EXPECTED_STEPS[4])
    for fragment in (
        "/usr/bin/env -i \\\n",
        "PYTHONDONTWRITEBYTECODE=1 \\\n",
        "validate \\\n",
        '--source-revision "$REQUESTED_REVISION"',
        '--candidate-id "$CANDIDATE_ID"',
        '--deployment-evidence-id "$DEPLOYMENT_EVIDENCE_ID"',
        '--workflow-run-id "$WORKFLOW_RUN_ID"',
        '--workflow-run-attempt "$WORKFLOW_RUN_ATTEMPT"',
        '--challenge "$RUN_CHALLENGE"',
        '--runner-session-id "$RUNNER_SESSION_ID"',
        '--driver-sha256 "sha256:$DRIVER_SHA256"',
        '--validator-sha256 "sha256:$VALIDATOR_SHA256"',
        '--workflow-sha256 "sha256:$WORKFLOW_SHA256"',
    ):
        if evidence.count(fragment) != 1:
            raise RuntimeError("protected evidence expected-binding invocation changed")

    upload = _step(source, EXPECTED_STEPS[5])
    for fragment in (
        "        if: steps.evidence.outcome == 'success'\n",
        f"        uses: {UPLOAD_ACTION} # v7.0.1\n",
        "          path: ${{ runner.temp }}/pakperk-protected-service-evidence.json\n",
        "          if-no-files-found: error\n",
        "          retention-days: 90\n",
        "          compression-level: 0\n",
        "          include-hidden-files: false\n",
    ):
        if upload.count(fragment) != 1:
            raise RuntimeError("sanitized evidence upload contract changed")


def validate(path: pathlib.Path = WORKFLOW) -> None:
    data = _read(path)
    source = data.decode("ascii")
    _validate_trigger_and_job(source)
    _validate_actions_and_steps(source)
    _validate_trust_boundary(source)
    _validate_bindings(source)
    if hashlib.sha256(data).hexdigest() != EXPECTED_WORKFLOW_SHA256:
        raise RuntimeError("protected workflow bytes changed outside review")


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if len(arguments) > 1:
        print("usage: validate_protected_service_exercise_workflow.py [workflow]", file=sys.stderr)
        return 2
    path = pathlib.Path(arguments[0]) if arguments else WORKFLOW
    try:
        validate(path)
    except (OSError, RuntimeError) as error:
        print(f"protected service workflow invalid: {error}", file=sys.stderr)
        return 2
    print(f"Validated protected service workflow {EXPECTED_WORKFLOW_SHA256}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
