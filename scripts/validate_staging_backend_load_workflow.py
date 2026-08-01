#!/usr/bin/env python3
"""Validate the fail-closed protected staging backend-load workflow."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/staging-backend-load.yml"
DEFAULT_CI = ROOT / ".github/workflows/ci.yml"
DEFAULT_CHECK = ROOT / "scripts/check.sh"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
EXPECTED_TRIGGER_SHA256 = (
    "795ac492d0770264d327de59af8bae7f68971e5d5bbf6a758bfad78832a22385"
)
EXPECTED_RUN_SHA256 = {
    "source gate": "c27da15a7f7d72e7a6469a8307cd1cb62cae33f7b698e2e1a09ec79d9b8e1bd3",
    "bounded runner": "1d39942e7725de4340c735f6bebb27b5434532ea3c5280f96e403f59bd6e3292",
    "final enforcement": "d64d089eecbec5591a7e140c4371cf07713b84261adfa9d7c34072c0e71a078d",
}
EXPECTED_CHECKOUT_STEP_SHA256 = (
    "6bc05ec1a7fbb3a14b447485291230172fdfe398392d701d6fc4ec2a09b4ca50"
)
EXPECTED_STEP_SHA256 = {
    "source gate": "de2d036e948e0f8628baf14fcf3944ad4169ca178f8082f82400d589240ff296",
    "bounded runner": "173445d54bfe4e8dad7eb09b65d55c75e3abdc4ee2d7776b8d6b97416299e1b7",
    "evidence upload": "e810128426d200e4f483095ff03c68be912035e47e57fc842b591fbd5ab150b3",
    "final enforcement": "0a196f8fd691841d59867d538e64d1274ba91625463e2534be3b39d07262fcf3",
}
EXPECTED_INPUTS = [
    "source_revision",
    "evidence_id",
    "duration_seconds",
    "concurrency",
    "max_requests",
    "minimum_samples_per_scenario",
    "include_authenticated_library",
    "include_authenticated_comments",
    "allow_library_mutations",
    "mutation_confirmation",
    "max_library_mutation_requests",
    "simulated_network_delay_ms",
    "simulated_packet_loss_rate",
]
EXPECTED_JOB_ENV = {
    "STAGING_API_ORIGIN": "${{ vars.PAKPERK_STAGING_API_ORIGIN }}",
    "COMMENTS_PAPER_ID": "${{ vars.PAKPERK_STAGING_LOAD_COMMENTS_PAPER_ID }}",
    "MUTATION_PAPER_ID": "${{ vars.PAKPERK_STAGING_LOAD_MUTATION_PAPER_ID }}",
    "REQUESTED_REVISION": "${{ inputs.source_revision }}",
    "EVIDENCE_ID": "${{ inputs.evidence_id }}",
    "DURATION_SECONDS": "${{ inputs.duration_seconds }}",
    "LOAD_CONCURRENCY": "${{ inputs.concurrency }}",
    "MAX_REQUESTS": "${{ inputs.max_requests }}",
    "MINIMUM_SAMPLES": "${{ inputs.minimum_samples_per_scenario }}",
    "INCLUDE_LIBRARY": "${{ inputs.include_authenticated_library }}",
    "INCLUDE_COMMENTS": "${{ inputs.include_authenticated_comments }}",
    "ALLOW_MUTATIONS": "${{ inputs.allow_library_mutations }}",
    "MUTATION_CONFIRMATION": "${{ inputs.mutation_confirmation }}",
    "MAX_MUTATIONS": "${{ inputs.max_library_mutation_requests }}",
    "NETWORK_DELAY_MS": "${{ inputs.simulated_network_delay_ms }}",
    "PACKET_LOSS_RATE": "${{ inputs.simulated_packet_loss_rate }}",
}
EXPECTED_STEP_NAMES = (
    "Verify reviewed source and protected inputs",
    "Run bounded staging gate",
    "Upload redacted staging evidence",
    "Enforce staging load result",
)


def _mapping_keys(source: str, indent: int) -> list[str]:
    prefix = " " * indent
    nested_prefix = prefix + " "
    keys: list[str] = []
    for raw_line in source.splitlines():
        if not raw_line.startswith(prefix) or raw_line.startswith(nested_prefix):
            continue
        content = raw_line[indent:]
        if not content or content.startswith("#") or ":" not in content:
            continue
        keys.append(content.partition(":")[0].strip())
    return keys


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


def _require_exact_run(block: str, label: str) -> None:
    marker = "        run: |\n"
    if block.count(marker) != 1:
        raise RuntimeError(f"{label} command boundary is malformed")
    command = block[block.index(marker) :]
    digest = hashlib.sha256(command.encode("utf-8")).hexdigest()
    if digest != EXPECTED_RUN_SHA256[label]:
        raise RuntimeError(f"{label} command block changed")


def _require_exact_step(block: str, label: str) -> None:
    digest = hashlib.sha256(block.encode("utf-8")).hexdigest()
    if digest != EXPECTED_STEP_SHA256[label]:
        raise RuntimeError(f"{label} step block changed")


def _validate_trigger(source: str) -> None:
    if source.count("\non:\n") != 1 or "\npermissions:" not in source:
        raise RuntimeError("staging load trigger boundary is malformed")
    start = source.index("\non:\n") + 1
    end = source.index("\npermissions:", start)
    trigger = source[start:end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("staging load gate must be manual-dispatch only")
    inputs = re.findall(r"(?m)^      ([a-z][a-z0-9_]*):$", trigger)
    if inputs != EXPECTED_INPUTS:
        raise RuntimeError("staging load gate has an unexpected dispatch input surface")
    if hashlib.sha256(trigger.encode("utf-8")).hexdigest() != EXPECTED_TRIGGER_SHA256:
        raise RuntimeError("staging load dispatch schema, defaults, or bounds changed")


def _validate_job_environment(source: str) -> None:
    marker = "\n    env:\n"
    if source.count(marker) != 1:
        raise RuntimeError(
            "workflow must contain exactly one protected job environment"
        )
    start = source.index(marker) + len(marker)
    end = source.index("\n    steps:\n", start)
    environment: dict[str, str] = {}
    for raw_line in source[start:end].splitlines():
        match = re.fullmatch(r"      ([A-Z][A-Z0-9_]*): (.+)", raw_line)
        if match is None:
            raise RuntimeError("protected job environment contains a malformed binding")
        name, value = match.groups()
        if name in environment:
            raise RuntimeError(f"protected job environment duplicates {name}")
        environment[name] = value
    if environment != EXPECTED_JOB_ENV:
        raise RuntimeError("protected job environment bindings changed")


def _validate_wiring(ci: pathlib.Path, check: pathlib.Path) -> None:
    ci_source = ci.read_text(encoding="utf-8")
    ci_commands = (
        "          python3 scripts/test_validate_staging_backend_load_workflow.py\n",
        "          python3 scripts/validate_staging_backend_load_workflow.py\n",
    )
    check_source = check.read_text(encoding="utf-8")
    check_commands = (
        'python3 "$project_dir/scripts/test_validate_staging_backend_load_workflow.py"\n',
        'python3 "$project_dir/scripts/validate_staging_backend_load_workflow.py"\n',
    )
    for label, source, commands in (
        ("CI", ci_source, ci_commands),
        ("local check", check_source, check_commands),
    ):
        lines = source.splitlines()
        command_lines = tuple(command.removesuffix("\n") for command in commands)
        if any(lines.count(command) != 1 for command in command_lines):
            raise RuntimeError(
                f"{label} must run the staging-load validator and tamper suite exactly once"
            )
        if lines.index(command_lines[0]) > lines.index(command_lines[1]):
            raise RuntimeError(
                f"{label} must run staging-load tamper tests before validation"
            )


def validate(
    workflow: pathlib.Path = DEFAULT_WORKFLOW,
    ci: pathlib.Path = DEFAULT_CI,
    check: pathlib.Path = DEFAULT_CHECK,
) -> None:
    source = workflow.read_text(encoding="utf-8")
    if _mapping_keys(source, 0) != [
        "name",
        "on",
        "permissions",
        "concurrency",
        "jobs",
    ]:
        raise RuntimeError(
            "staging load workflow has an unexpected or duplicate root key"
        )
    if re.search(r"(?m)^\s*<<:", source):
        raise RuntimeError("YAML merge keys are forbidden in the staging load workflow")
    _validate_trigger(source)

    permissions_start = source.index("\npermissions:") + 1
    permissions_end = source.index("\nconcurrency:", permissions_start)
    if source[permissions_start:permissions_end].strip() != (
        "permissions:\n  contents: read"
    ):
        raise RuntimeError("staging load permissions are not least privilege")

    concurrency_start = source.index("\nconcurrency:") + 1
    concurrency_end = source.index("\njobs:", concurrency_start)
    if source[concurrency_start:concurrency_end].strip() != (
        "concurrency:\n" "  group: staging-backend-load\n" "  cancel-in-progress: false"
    ):
        raise RuntimeError(
            "staging load concurrency must be bounded and non-cancelling"
        )

    jobs = source[source.index("\njobs:") :]
    if _mapping_keys(jobs, 2) != ["load-gate"]:
        raise RuntimeError("staging load workflow must contain exactly one bounded job")
    job_start = source.index("  load-gate:")
    env_start = source.index("    env:", job_start)
    expected_job_prefix = (
        "  load-gate:\n"
        "    runs-on: ubuntu-24.04\n"
        "    timeout-minutes: 15\n"
        "    environment: staging\n"
    )
    if source[job_start:env_start] != expected_job_prefix:
        raise RuntimeError(
            "staging load job runner, timeout, environment, or fail-closed surface changed"
        )
    if _mapping_keys(source[job_start:], 4) != [
        "runs-on",
        "timeout-minutes",
        "environment",
        "env",
        "steps",
    ]:
        raise RuntimeError(
            "staging load job contains an unexpected or reordered job-level key"
        )
    if source.count("timeout-minutes:") != 1:
        raise RuntimeError("staging load workflow must have one reviewed timeout")
    _validate_job_environment(source)

    step_items = re.findall(r"(?m)^      -[^\n]*$", source)
    expected_step_items = [
        f"      - uses: {CHECKOUT_ACTION} # v7.0.1",
        *(f"      - name: {name}" for name in EXPECTED_STEP_NAMES),
    ]
    if step_items != expected_step_items:
        raise RuntimeError("staging load workflow has an unexpected step surface")
    actions = re.findall(r"(?m)^\s+(?:- )?uses: ([^ #]+)", source)
    if actions != [CHECKOUT_ACTION, UPLOAD_ACTION]:
        raise RuntimeError(
            "staging load workflow must use only reviewed pinned actions"
        )
    if re.findall(r"(?m)^        shell: (.+)$", source) != ["bash", "bash"]:
        raise RuntimeError("staging load command steps must use exact non-tracing Bash")
    if source.count("        run: |\n") != 3:
        raise RuntimeError("staging load workflow command surface changed")

    checkout = _step_block(
        source, f"      - uses: {CHECKOUT_ACTION}", "exact-source checkout step"
    )
    if (
        hashlib.sha256(checkout.encode("utf-8")).hexdigest()
        != EXPECTED_CHECKOUT_STEP_SHA256
    ):
        raise RuntimeError("staging load checkout step changed")
    _require_step_keys(checkout, ["with"], "exact-source checkout")
    expected_checkout = (
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false\n"
    )
    if checkout[checkout.index("        with:\n") :] != expected_checkout:
        raise RuntimeError("staging load exact-source checkout inputs changed")

    source_gate = _step_block(
        source,
        "      - name: Verify reviewed source and protected inputs\n",
        "reviewed-source gate",
    )
    _require_exact_step(source_gate, "source gate")
    _require_step_keys(source_gate, ["shell", "env", "run"], "reviewed-source gate")
    expected_source_env = "        env:\n          DISPATCH_REF: ${{ github.ref }}\n"
    env_start = source_gate.index("        env:\n")
    run_start = source_gate.index("        run: |\n", env_start)
    if source_gate[env_start:run_start] != expected_source_env:
        raise RuntimeError("reviewed-source dispatch-ref binding changed")
    _require_exact_run(source_gate, "source gate")
    for fragment in (
        "DISPATCH_REF: ${{ github.ref }}",
        'if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
        'if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
        'if [[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]; then',
        'git merge-base --is-ancestor "$REQUESTED_REVISION" origin/main',
        'if [[ -z "$STAGING_API_ORIGIN" ]]; then',
        'case "$DURATION_SECONDS" in',
        "30|60|120|300) ;;",
        'case "$LOAD_CONCURRENCY" in',
        "1|4|8|16) ;;",
        'case "$MAX_REQUESTS" in',
        "1000|5000|10000|25000) ;;",
        'case "$MINIMUM_SAMPLES" in',
        'case "$MAX_MUTATIONS" in',
        'case "$NETWORK_DELAY_MS" in',
        'case "$PACKET_LOSS_RATE" in',
        "for boolean_input in INCLUDE_LIBRARY INCLUDE_COMMENTS ALLOW_MUTATIONS; do",
        'case "${!boolean_input}" in',
        "true|false) ;;",
        '"RUN_DEDICATED_STAGING_LIBRARY_MUTATIONS"',
    ):
        _require(source_gate, fragment, "exact reviewed-source gate")
    if "continue-on-error:" in source_gate:
        raise RuntimeError("reviewed-source trust gate must not be recoverable")

    runner = _step_block(
        source,
        "      - name: Run bounded staging gate\n",
        "bounded staging runner",
    )
    _require_exact_step(runner, "bounded runner")
    _require_step_keys(
        runner,
        ["id", "continue-on-error", "shell", "env", "run"],
        "bounded staging runner",
    )
    expected_runner_env = (
        "        env:\n"
        "          STAGING_LOAD_TOKEN: ${{ secrets.PAKPERK_STAGING_LOAD_TOKEN }}\n"
    )
    env_start = runner.index("        env:\n")
    run_start = runner.index("        run: |\n", env_start)
    if runner[env_start:run_start] != expected_runner_env:
        raise RuntimeError("staging load secret must remain one step-scoped binding")
    _require(runner, "id: backend-load", "bounded staging runner")
    _require(runner, "continue-on-error: true", "bounded staging runner")
    _require_exact_run(runner, "bounded runner")
    if source.count('python3 scripts/run_backend_load.py "${arguments[@]}"') != 1:
        raise RuntimeError("workflow must invoke the checked-in bounded runner once")

    secret_refs = re.findall(r"\$\{\{\s*secrets\.([A-Z][A-Z0-9_]*)\s*\}\}", source)
    if secret_refs != ["PAKPERK_STAGING_LOAD_TOKEN"]:
        raise RuntimeError("staging load workflow secret surface changed")
    for forbidden in (
        "${{ github.token }}",
        "${{ inputs.staging_api_origin }}",
        "set -x",
        "set -o xtrace",
        "bash -x",
        "printenv",
    ):
        if forbidden in source:
            raise RuntimeError(
                f"staging load workflow contains a trust bypass: {forbidden}"
            )

    upload = _step_block(
        source,
        "      - name: Upload redacted staging evidence\n",
        "staging evidence upload",
    )
    _require_exact_step(upload, "evidence upload")
    _require_step_keys(upload, ["if", "uses", "with"], "staging evidence upload")
    expected_upload = (
        "        with:\n"
        "          name: staging-backend-load-${{ github.run_id }}-${{ github.run_attempt }}\n"
        "          path: ${{ runner.temp }}/pakperk-backend-load-evidence.tar\n"
        "          if-no-files-found: error\n"
        "          retention-days: 90\n"
    )
    if upload[upload.index("        with:\n") :] != expected_upload:
        raise RuntimeError("staging evidence upload boundary changed")
    for fragment in ("if: always()", f"uses: {UPLOAD_ACTION}"):
        _require(upload, fragment, "staging evidence upload")
    if "continue-on-error:" in upload:
        raise RuntimeError("staging evidence upload failure must remain fatal")

    enforce = _step_block(
        source,
        "      - name: Enforce staging load result\n",
        "final staging enforcement",
    )
    _require_exact_step(enforce, "final enforcement")
    _require_step_keys(enforce, ["if", "env", "run"], "final staging enforcement")
    expected_enforce_env = (
        "        env:\n" "          LOAD_OUTCOME: ${{ steps.backend-load.outcome }}\n"
    )
    env_start = enforce.index("        env:\n")
    run_start = enforce.index("        run: |\n", env_start)
    if enforce[env_start:run_start] != expected_enforce_env:
        raise RuntimeError("final staging outcome binding changed")
    _require(enforce, "if: always()", "final staging enforcement")
    _require_exact_run(enforce, "final enforcement")
    if "continue-on-error:" in enforce or not source.endswith(enforce):
        raise RuntimeError("final staging enforcement must be non-recoverable and last")

    positions = [
        source.index(f"      - uses: {CHECKOUT_ACTION}"),
        source.index("Verify reviewed source and protected inputs"),
        source.index("Run bounded staging gate"),
        source.index("Upload redacted staging evidence"),
        source.index("Enforce staging load result"),
    ]
    if positions != sorted(positions):
        raise RuntimeError("staging source, load, evidence, and result steps reordered")
    _validate_wiring(ci, check)


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(
            f"staging backend-load workflow validation failed: {error}", file=sys.stderr
        )
        return 1
    print("Staging backend-load fail-closed workflow contract validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
