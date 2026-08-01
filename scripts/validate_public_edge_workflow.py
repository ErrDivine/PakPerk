#!/usr/bin/env python3
"""Validate the exact-source manual public-edge observation workflow."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/public-edge-verification.yml"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
EXPECTED_JOB_ENV = {
    "REQUESTED_REVISION": "${{ inputs.source_revision }}",
    "DISPATCH_CONFIRMATION": "${{ inputs.confirmation }}",
    "TARGET_ENVIRONMENT": "${{ inputs.target_environment }}",
    "CANDIDATE_ID": "${{ inputs.candidate_id }}",
    "SITE_ORIGIN": "${{ vars.PAKPERK_SITE_ORIGIN }}",
    "API_ORIGIN": "${{ vars.PAKPERK_API_ORIGIN }}",
    "TELEMETRY_ORIGIN": "${{ vars.PAKPERK_TELEMETRY_ORIGIN }}",
    "OIDC_ISSUER": "${{ vars.PAKPERK_OIDC_ISSUER }}",
    "OIDC_CLIENT_ID": "${{ vars.PAKPERK_WEB_OIDC_CLIENT_ID }}",
    "SUPPORT_EMAIL": "${{ vars.PAKPERK_SUPPORT_EMAIL }}",
    "DOCUMENT_VERSION": "${{ vars.PAKPERK_PUBLIC_DOCUMENT_VERSION }}",
    "ANDROID_PACKAGE": "${{ vars.PAKPERK_ANDROID_PACKAGE }}",
    "ANDROID_SHA256": "${{ vars.PAKPERK_ANDROID_SHA256 }}",
    "APPLE_TEAM_ID": "${{ vars.PAKPERK_APPLE_TEAM_ID }}",
    "APPLE_BUNDLE_ID": "${{ vars.PAKPERK_APPLE_BUNDLE_ID }}",
    "PYTHONDONTWRITEBYTECODE": '"1"',
}
EXPECTED_PUBLIC_VARS = {
    "PAKPERK_SITE_ORIGIN",
    "PAKPERK_API_ORIGIN",
    "PAKPERK_TELEMETRY_ORIGIN",
    "PAKPERK_OIDC_ISSUER",
    "PAKPERK_WEB_OIDC_CLIENT_ID",
    "PAKPERK_SUPPORT_EMAIL",
    "PAKPERK_PUBLIC_DOCUMENT_VERSION",
    "PAKPERK_ANDROID_PACKAGE",
    "PAKPERK_ANDROID_SHA256",
    "PAKPERK_APPLE_TEAM_ID",
    "PAKPERK_APPLE_BUNDLE_ID",
}
REQUIRED_COORDINATES = (
    "SITE_ORIGIN",
    "API_ORIGIN",
    "TELEMETRY_ORIGIN",
    "OIDC_ISSUER",
    "OIDC_CLIENT_ID",
    "SUPPORT_EMAIL",
    "DOCUMENT_VERSION",
    "ANDROID_PACKAGE",
    "ANDROID_SHA256",
    "APPLE_TEAM_ID",
    "APPLE_BUNDLE_ID",
)
EXPECTED_STEP_NAMES = (
    "Verify exact reviewed main source and scoped coordinates",
    "Observe exact public-edge contract",
    "Validate and atomically package sanitized technical evidence",
    "Record public-edge evidence boundary",
    "Upload exact-source public-edge evidence",
    "Enforce public-edge verification result",
)
EXPECTED_SOURCE_GATE_RUN = """        run: |
          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then
            echo "Public-edge verification must be dispatched from main." >&2
            exit 2
          fi
          if [[ "$DISPATCH_CONFIRMATION" != "RUN_PUBLIC_EDGE_VERIFICATION" ]]; then
            echo "Dispatch confirmation did not match the required phrase." >&2
            exit 2
          fi
          if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
            echo "source_revision must be a full lowercase Git commit SHA." >&2
            exit 2
          fi
          if [[ "$TARGET_ENVIRONMENT" != "staging" && "$TARGET_ENVIRONMENT" != "production" ]]; then
            echo "target_environment must be staging or production." >&2
            exit 2
          fi
          if ! [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            echo "candidate_id must be an exact lowercase sha256 content ID." >&2
            exit 2
          fi
          if [[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]; then
            echo "source_revision must exactly match the selected main revision." >&2
            exit 2
          fi
          if [[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]; then
            echo "Checkout did not resolve the exact requested revision." >&2
            exit 2
          fi
          if [[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]; then
            echo "The requested revision is not the fetched origin/main tip." >&2
            exit 2
          fi
          required_coordinates=(
            SITE_ORIGIN
            API_ORIGIN
            TELEMETRY_ORIGIN
            OIDC_ISSUER
            OIDC_CLIENT_ID
            SUPPORT_EMAIL
            DOCUMENT_VERSION
            ANDROID_PACKAGE
            ANDROID_SHA256
            APPLE_TEAM_ID
            APPLE_BUNDLE_ID
          )
          for coordinate in "${required_coordinates[@]}"; do
            if [[ -z "${!coordinate}" ]]; then
              echo "A required environment-scoped public coordinate is unavailable." >&2
              exit 2
            fi
          done
"""
EXPECTED_RUN_SHA256 = {
    "source gate": "894098d756da34a528ca378d5761622aa72dd7c9645263c7b84183a5dc53036e",
    "public-edge verifier": "b7bd86d1909cf9391ba460d05cf29b1396e947f82c705f7d2425cc15447da5cb",
    "evidence package": "1eb13b427afd1d3bccbb82631a209e9abfddf8d8cbf031196736d151a620180b",
    "evidence boundary summary": "192903fbe81096bef801d7745fc2b20c0ce4c2ef40abdee83dd70da0e50c19c2",
    "final enforcement": "234d270b2953ee45053a367c385ab7195517285ec914b0f85c21a75df9330eb9",
}


def _require(source: str, fragment: str, label: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"{label} is missing: {fragment}")


def _step_block(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"workflow must contain exactly one {label}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def _require_step_keys(block: str, expected: list[str], label: str) -> None:
    keys = re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", block)
    if keys != expected:
        raise RuntimeError(f"{label} has an unexpected or duplicate step key")


def _require_exact_env(block: str, expected: str, label: str) -> None:
    marker = "        env:\n"
    if block.count(marker) != 1 or "        run: |\n" not in block:
        raise RuntimeError(f"{label} environment boundary is malformed")
    start = block.index(marker)
    end = block.index("        run: |\n", start)
    if block[start:end] != expected:
        raise RuntimeError(f"{label} environment bindings changed")


def _require_exact_run(block: str, label: str) -> None:
    marker = "        run: |\n"
    if block.count(marker) != 1:
        raise RuntimeError(f"{label} command boundary is malformed")
    command = block[block.index(marker) :]
    digest = hashlib.sha256(command.encode("utf-8")).hexdigest()
    if digest != EXPECTED_RUN_SHA256[label]:
        raise RuntimeError(f"{label} command block changed")


def _input_block(trigger: str, name: str) -> str:
    marker = f"      {name}:\n"
    if trigger.count(marker) != 1:
        raise RuntimeError(f"workflow must define exactly one {name} input")
    start = trigger.index(marker)
    remainder = trigger[start + len(marker) :]
    next_input = re.search(r"(?m)^      [a-z][a-z0-9_]*:\n", remainder)
    if next_input is None:
        return trigger[start:]
    return trigger[start : start + len(marker) + next_input.start()]


def _validate_trigger(source: str) -> None:
    if source.count("\non:\n") != 1 or "\npermissions:" not in source:
        raise RuntimeError("public-edge workflow trigger boundary is malformed")
    trigger_start = source.index("\non:\n") + 1
    trigger_end = source.index("\npermissions:", trigger_start)
    trigger = source[trigger_start:trigger_end]
    trigger_names = re.findall(r"(?m)^  ([a-z][a-z0-9_-]*):", trigger)
    if trigger_names != ["workflow_dispatch"]:
        raise RuntimeError("public-edge verification must be manual-dispatch only")

    input_names = re.findall(r"(?m)^      ([a-z][a-z0-9_]*):$", trigger)
    expected_inputs = [
        "source_revision",
        "target_environment",
        "candidate_id",
        "confirmation",
    ]
    if input_names != expected_inputs:
        raise RuntimeError(
            "public-edge workflow has an unexpected dispatch input surface"
        )

    for input_name in ("source_revision", "candidate_id", "confirmation"):
        block = _input_block(trigger, input_name)
        if re.findall(r"(?m)^        ([a-z][a-z0-9_-]*):", block) != [
            "description",
            "required",
            "type",
        ]:
            raise RuntimeError(f"{input_name} has an unexpected property surface")
        if (
            block.count("        required: true") != 1
            or block.count("        type: string") != 1
        ):
            raise RuntimeError(f"{input_name} must be one required string input")
    _require(
        _input_block(trigger, "candidate_id"),
        "description: Non-secret candidate-record ID in exact sha256 lowercase digest form",
        "immutable candidate-record input",
    )

    environment = _input_block(trigger, "target_environment")
    if re.findall(r"(?m)^        ([a-z][a-z0-9_-]*):", environment) != [
        "description",
        "required",
        "type",
        "options",
    ]:
        raise RuntimeError("target_environment has an unexpected property surface")
    for fragment in (
        "        required: true",
        "        type: choice",
        "        options:\n          - staging\n          - production",
    ):
        _require(environment, fragment, "closed target-environment input")
    options = re.findall(r"(?m)^          - ([a-z]+)$", environment)
    if options != ["staging", "production"]:
        raise RuntimeError(
            "target_environment must allow exactly staging and production"
        )


def _validate_job_environment(source: str) -> None:
    marker = "\n    env:\n"
    if source.count(marker) != 1:
        raise RuntimeError("workflow must contain exactly one job environment binding")
    start = source.index(marker) + len(marker)
    end = source.index("\n    steps:\n", start)
    environment: dict[str, str] = {}
    for raw_line in source[start:end].splitlines():
        match = re.fullmatch(r"      ([A-Z][A-Z0-9_]*): (.+)", raw_line)
        if match is None:
            raise RuntimeError("job environment contains a malformed binding")
        name, value = match.groups()
        if name in environment:
            raise RuntimeError(f"job environment duplicates {name}")
        environment[name] = value
    if environment != EXPECTED_JOB_ENV:
        raise RuntimeError("job environment changed outside the reviewed public inputs")

    public_vars = re.findall(r"\$\{\{\s*vars\.([A-Z][A-Z0-9_]*)\s*\}\}", source)
    if set(public_vars) != EXPECTED_PUBLIC_VARS or len(public_vars) != len(
        EXPECTED_PUBLIC_VARS
    ):
        raise RuntimeError(
            "workflow must consume each reviewed public variable exactly once"
        )


def _validate_actions_and_steps(source: str) -> None:
    headers = re.findall(r"(?m)^      - (name|uses): (.+)$", source)
    if len(headers) != 1 + len(EXPECTED_STEP_NAMES):
        raise RuntimeError("public-edge workflow has an unexpected step surface")
    if (
        headers[0][0] != "uses"
        or tuple(value for kind, value in headers[1:] if kind == "name")
        != EXPECTED_STEP_NAMES
    ):
        raise RuntimeError("public-edge workflow steps changed or were reordered")

    actions = re.findall(r"(?m)^\s+(?:- )?uses: ([^ #]+)", source)
    if actions != [CHECKOUT_ACTION, UPLOAD_ACTION]:
        raise RuntimeError("public-edge workflow must use only reviewed pinned actions")
    shells = re.findall(r"(?m)^        shell: (.+)$", source)
    if shells != ["bash"] * 5 or source.count("        run: |\n") != 5:
        raise RuntimeError(
            "public-edge command steps must use exact non-tracing Bash blocks"
        )
    if re.findall(r"(?m)^        if: (.+)$", source) != ["always()"] * 4:
        raise RuntimeError(
            "public-edge recovery steps must use four exact always guards"
        )
    if re.findall(r"(?m)^        continue-on-error: (.+)$", source) != [
        "true",
        "true",
        "true",
    ]:
        raise RuntimeError("public-edge recovery surface changed")
    if re.findall(r"(?m)^        id: (.+)$", source) != [
        "public-edge",
        "evidence-package",
        "evidence-upload",
    ]:
        raise RuntimeError("public-edge step outcome bindings changed")
    if re.search(r"(?m)^\s*(?:sudo\s+)?(?:curl|wget|nc|ncat|ssh|scp)\b", source):
        raise RuntimeError(
            "workflow must delegate all public network access to the verifier"
        )
    for forbidden in (
        "set -x",
        "set -o xtrace",
        "bash -x",
        "printenv",
        "${{ secrets.",
        "${{ github.token }}",
    ):
        if forbidden in source:
            raise RuntimeError(
                f"public-edge workflow contains a disclosure boundary bypass: {forbidden}"
            )
    for name in (*REQUIRED_COORDINATES, "CANDIDATE_ID"):
        if re.search(rf"(?m)^\s*(?:echo|printf)\b[^\n]*\${name}\b", source):
            raise RuntimeError("workflow must not print public-edge input values")


def validate(workflow: pathlib.Path = DEFAULT_WORKFLOW) -> None:
    source = workflow.read_text(encoding="utf-8")
    root_keys = re.findall(r"(?m)^([A-Za-z][A-Za-z0-9_-]*):(?:.*)$", source)
    if root_keys != ["name", "on", "permissions", "concurrency", "jobs"]:
        raise RuntimeError(
            "public-edge workflow has an unexpected or duplicate root key"
        )
    if re.search(r"(?m)^\s*<<:", source):
        raise RuntimeError("YAML merge keys are forbidden in the public-edge workflow")
    _validate_trigger(source)

    permissions_start = source.index("\npermissions:") + 1
    permissions_end = source.index("\nconcurrency:", permissions_start)
    permissions = source[permissions_start:permissions_end].strip()
    if permissions != "permissions:\n  contents: read":
        raise RuntimeError("public-edge workflow permissions are not least privilege")

    concurrency_start = source.index("\nconcurrency:") + 1
    concurrency_end = source.index("\njobs:", concurrency_start)
    concurrency = source[concurrency_start:concurrency_end].strip()
    expected_concurrency = (
        "concurrency:\n"
        "  group: public-edge-verification-${{ inputs.target_environment }}\n"
        "  cancel-in-progress: false"
    )
    if concurrency != expected_concurrency:
        raise RuntimeError(
            "public-edge concurrency must be non-cancelling and target-scoped"
        )

    job_names = re.findall(
        r"(?m)^  ([A-Za-z_][A-Za-z0-9_-]*):$",
        source[source.index("\njobs:") :],
    )
    if job_names != ["verify-edge"]:
        raise RuntimeError("public-edge workflow must contain exactly one bounded job")
    job_prefix = source[source.index("  verify-edge:") : source.index("    env:")]
    expected_job_prefix = (
        "  verify-edge:\n"
        "    runs-on: ubuntu-24.04\n"
        "    environment: ${{ inputs.target_environment }}\n"
        "    timeout-minutes: 15\n"
    )
    if job_prefix != expected_job_prefix:
        raise RuntimeError("public-edge job execution boundary changed")
    if source.count("timeout-minutes:") != 1:
        raise RuntimeError("public-edge workflow must have one reviewed timeout")

    _validate_job_environment(source)
    _validate_actions_and_steps(source)

    checkout = _step_block(
        source,
        f"      - uses: {CHECKOUT_ACTION}",
        "exact-source checkout step",
    )
    _require_step_keys(checkout, ["with"], "exact-source checkout")
    expected_checkout_with = (
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false\n"
    )
    if checkout[checkout.index("        with:\n") :] != expected_checkout_with:
        raise RuntimeError("exact-source checkout inputs changed")
    for fragment in (
        "ref: ${{ inputs.source_revision }}",
        "fetch-depth: 0",
        "persist-credentials: false",
    ):
        _require(checkout, fragment, "exact-source checkout")

    source_gate = _step_block(
        source,
        "      - name: Verify exact reviewed main source and scoped coordinates\n",
        "source and coordinate gate",
    )
    _require_step_keys(source_gate, ["shell", "env", "run"], "source gate")
    _require_exact_env(
        source_gate,
        "        env:\n"
        "          DISPATCH_REF: ${{ github.ref }}\n"
        "          DISPATCH_REVISION: ${{ github.sha }}\n",
        "source gate",
    )
    _require_exact_run(source_gate, "source gate")
    run_marker = "        run: |\n"
    source_gate_run = source_gate[source_gate.index(run_marker) :]
    if source_gate_run != EXPECTED_SOURCE_GATE_RUN:
        raise RuntimeError("exact reviewed source verification command changed")
    for fragment in (
        "DISPATCH_REF: ${{ github.ref }}",
        "DISPATCH_REVISION: ${{ github.sha }}",
        '[[ "$DISPATCH_REF" != "refs/heads/main" ]]',
        '[[ "$DISPATCH_CONFIRMATION" != "RUN_PUBLIC_EDGE_VERIFICATION" ]]',
        'if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
        'if [[ "$TARGET_ENVIRONMENT" != "staging" && "$TARGET_ENVIRONMENT" != "production" ]]; then',
        'if ! [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then',
        'if [[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]; then',
        'if [[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]; then',
        'if [[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]; then',
        "required_coordinates=(",
        'for coordinate in "${required_coordinates[@]}"',
        'if [[ -z "${!coordinate}" ]]; then',
    ):
        _require(source_gate, fragment, "exact reviewed source verification")
    for coordinate in REQUIRED_COORDINATES:
        if source_gate.count(f"            {coordinate}\n") != 1:
            raise RuntimeError(
                f"source gate must require the {coordinate} public coordinate"
            )
    if "continue-on-error:" in source_gate:
        raise RuntimeError("source and coordinate trust gate must not be recoverable")

    verifier = _step_block(
        source,
        "      - name: Observe exact public-edge contract\n",
        "public-edge verifier step",
    )
    _require_step_keys(
        verifier,
        ["id", "continue-on-error", "shell", "env", "run"],
        "public-edge verifier",
    )
    _require_exact_env(
        verifier,
        "        env:\n"
        "          PUBLIC_EDGE_EVIDENCE_FILE: ${{ runner.temp }}/pakperk-public-edge-evidence/public-edge-evidence.json\n",
        "public-edge verifier",
    )
    _require_exact_run(verifier, "public-edge verifier")
    verifier_call = """./scripts/verify_public_edge.sh \\
            "$SITE_ORIGIN" \\
            "$API_ORIGIN" \\
            "$TELEMETRY_ORIGIN" \\
            --evidence-output "$PUBLIC_EDGE_EVIDENCE_FILE" \\
            --source-revision "$REQUESTED_REVISION" \\
            --environment "$TARGET_ENVIRONMENT" \\
            --candidate-id "$CANDIDATE_ID" \\
            --oidc-issuer "$OIDC_ISSUER" \\
            --oidc-client-id "$OIDC_CLIENT_ID" \\
            --support-email "$SUPPORT_EMAIL" \\
            --document-version "$DOCUMENT_VERSION" \\
            --android-package "$ANDROID_PACKAGE" \\
            --android-sha256 "$ANDROID_SHA256" \\
            --apple-team-id "$APPLE_TEAM_ID" \\
            --apple-bundle-id "$APPLE_BUNDLE_ID"""  # noqa: E501
    for fragment in (
        "id: public-edge",
        "continue-on-error: true",
        "PUBLIC_EDGE_EVIDENCE_FILE: ${{ runner.temp }}/pakperk-public-edge-evidence/public-edge-evidence.json",
        "umask 077",
        'mkdir "$evidence_dir"',
        verifier_call,
    ):
        _require(verifier, fragment, "exact public-edge verifier invocation")
    if source.count("./scripts/verify_public_edge.sh") != 1:
        raise RuntimeError(
            "workflow must invoke the checked-in public-edge verifier once"
        )

    package = _step_block(
        source,
        "      - name: Validate and atomically package sanitized technical evidence\n",
        "evidence validation and packaging step",
    )
    _require_step_keys(
        package,
        ["id", "if", "continue-on-error", "shell", "env", "run"],
        "evidence package",
    )
    _require_exact_env(
        package,
        "        env:\n"
        "          PUBLIC_EDGE_OUTCOME: ${{ steps.public-edge.outcome }}\n"
        "          PUBLIC_EDGE_EVIDENCE_FILE: ${{ runner.temp }}/pakperk-public-edge-evidence/public-edge-evidence.json\n",
        "evidence package",
    )
    _require_exact_run(package, "evidence package")
    validator_call = """python3 scripts/validate_public_edge_evidence.py "$PUBLIC_EDGE_EVIDENCE_FILE" \\
            --source-revision "$REQUESTED_REVISION" \\
            --environment "$TARGET_ENVIRONMENT" \\
            --candidate-id "$CANDIDATE_ID" \\
            --site-origin "$SITE_ORIGIN" \\
            --api-origin "$API_ORIGIN" \\
            --telemetry-origin "$TELEMETRY_ORIGIN" \\
            --oidc-issuer "$OIDC_ISSUER" \\
            --oidc-client-id "$OIDC_CLIENT_ID" \\
            --support-email "$SUPPORT_EMAIL" \\
            --document-version "$DOCUMENT_VERSION" \\
            --android-package "$ANDROID_PACKAGE" \\
            --android-sha256 "$ANDROID_SHA256" \\
            --apple-team-id "$APPLE_TEAM_ID" \\
            --apple-bundle-id "$APPLE_BUNDLE_ID" \\
            --expected-outcome "$evidence_outcome"""  # noqa: E501
    for fragment in (
        "id: evidence-package",
        "if: always()",
        "continue-on-error: true",
        "PUBLIC_EDGE_OUTCOME: ${{ steps.public-edge.outcome }}",
        "umask 077",
        'archive="$RUNNER_TEMP/pakperk-public-edge-evidence-$REQUESTED_REVISION.tar"',
        'temporary_archive="$RUNNER_TEMP/.pakperk-public-edge-evidence-$REQUESTED_REVISION.tar.partial"',
        '[[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" || "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]',
        "git diff --quiet",
        "git diff --cached --quiet",
        'if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then',
        '[[ -e "$archive" || -L "$archive" || -e "$temporary_archive" || -L "$temporary_archive" ]]',
        "success) evidence_outcome=passed ;;",
        "failure) evidence_outcome=failed ;;",
        validator_call,
        '[[ ! -s "$evidence_file" || -L "$evidence_file" ]]',
        "mapfile -d '' evidence_entries < <(find \"$evidence_dir\" -mindepth 1 -maxdepth 1 -print0)",
        '[[ "${#evidence_entries[@]}" -ne 1 || "${evidence_entries[0]}" != "$evidence_file" ]]',
        "sha256sum -- public-edge-evidence.json >SHA256SUMS",
        "sha256sum --check --strict SHA256SUMS",
        "chmod 0400 public-edge-evidence.json SHA256SUMS",
        '--file "$temporary_archive"',
        '--directory "$evidence_dir"',
        "public-edge-evidence.json SHA256SUMS",
        'chmod 0400 "$temporary_archive"',
        'mv -- "$temporary_archive" "$archive"',
    ):
        _require(package, fragment, "fail-closed public-edge evidence packaging")
    if source.count("scripts/validate_public_edge_evidence.py") != 1:
        raise RuntimeError(
            "workflow must invoke the checked-in evidence validator once"
        )

    summary = _step_block(
        source,
        "      - name: Record public-edge evidence boundary\n",
        "public-edge boundary summary",
    )
    _require_step_keys(summary, ["if", "shell", "run"], "evidence boundary summary")
    _require_exact_run(summary, "evidence boundary summary")
    for fragment in (
        "if: always()",
        "sanitized public-edge technical verification",
        "requested candidate-record ID",
        "not observed at the edge",
        "observed site source comes",
        "public notices document",
        "endpoint process readiness only",
        "not end-to-end telemetry delivery",
        "does not attest GitHub",
        "environment reviewer or",
        "deployment-branch settings",
        "deployment provenance",
        "release approval",
        "legal/content approval",
        "signed-candidate",
        "store approval",
    ):
        _require(summary, fragment, "truthful technical evidence boundary")

    upload = _step_block(
        source,
        "      - name: Upload exact-source public-edge evidence\n",
        "exact-source evidence upload",
    )
    _require_step_keys(
        upload,
        ["id", "if", "continue-on-error", "uses", "with"],
        "evidence upload",
    )
    expected_upload_with = (
        "        with:\n"
        "          name: public-edge-${{ inputs.target_environment }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}\n"
        "          path: ${{ runner.temp }}/pakperk-public-edge-evidence-${{ github.sha }}.tar\n"
        "          if-no-files-found: error\n"
        "          retention-days: 90\n"
    )
    if upload[upload.index("        with:\n") :] != expected_upload_with:
        raise RuntimeError("exact-source evidence upload inputs changed")
    for fragment in (
        "id: evidence-upload",
        "if: always()",
        "continue-on-error: true",
        f"uses: {UPLOAD_ACTION}",
        "name: public-edge-${{ inputs.target_environment }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "path: ${{ runner.temp }}/pakperk-public-edge-evidence-${{ github.sha }}.tar",
        "if-no-files-found: error",
        "retention-days: 90",
    ):
        _require(upload, fragment, "exact-source evidence upload")

    enforce = _step_block(
        source,
        "      - name: Enforce public-edge verification result\n",
        "final result enforcement",
    )
    _require_step_keys(enforce, ["if", "shell", "env", "run"], "final enforcement")
    _require_exact_env(
        enforce,
        "        env:\n"
        "          PUBLIC_EDGE_OUTCOME: ${{ steps.public-edge.outcome }}\n"
        "          EVIDENCE_PACKAGE_OUTCOME: ${{ steps.evidence-package.outcome }}\n"
        "          EVIDENCE_UPLOAD_OUTCOME: ${{ steps.evidence-upload.outcome }}\n",
        "final enforcement",
    )
    _require_exact_run(enforce, "final enforcement")
    for fragment in (
        "if: always()",
        "PUBLIC_EDGE_OUTCOME: ${{ steps.public-edge.outcome }}",
        "EVIDENCE_PACKAGE_OUTCOME: ${{ steps.evidence-package.outcome }}",
        "EVIDENCE_UPLOAD_OUTCOME: ${{ steps.evidence-upload.outcome }}",
        '[[ "$PUBLIC_EDGE_OUTCOME" != "success" || "$EVIDENCE_PACKAGE_OUTCOME" != "success" || "$EVIDENCE_UPLOAD_OUTCOME" != "success" ]]',
        "exit 1",
    ):
        _require(enforce, fragment, "final public-edge result enforcement")
    if "continue-on-error:" in enforce or not source.rstrip().endswith("          fi"):
        raise RuntimeError(
            "final public-edge enforcement must be non-recoverable and last"
        )
    expected_enforce_run = (
        "        run: |\n"
        '          if [[ "$PUBLIC_EDGE_OUTCOME" != "success" || "$EVIDENCE_PACKAGE_OUTCOME" != "success" || "$EVIDENCE_UPLOAD_OUTCOME" != "success" ]]; then\n'
        '            echo "Public-edge verification, evidence validation, or evidence upload did not pass." >&2\n'
        "            exit 1\n"
        "          fi\n"
    )
    if enforce[enforce.index("        run: |\n") :] != expected_enforce_run:
        raise RuntimeError("final public-edge enforcement command changed")

    positions = [
        source.index(f"      - uses: {CHECKOUT_ACTION}"),
        source.index("Verify exact reviewed main source and scoped coordinates"),
        source.index("Observe exact public-edge contract"),
        source.index("Validate and atomically package sanitized technical evidence"),
        source.index("Record public-edge evidence boundary"),
        source.index("Upload exact-source public-edge evidence"),
        source.index("Enforce public-edge verification result"),
    ]
    if positions != sorted(positions):
        raise RuntimeError(
            "public-edge trust, observation, evidence, and result steps reordered"
        )


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"public-edge workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Public-edge exact-source workflow contract validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
