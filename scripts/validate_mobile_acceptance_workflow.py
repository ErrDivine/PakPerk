#!/usr/bin/env python3
"""Validate the fail-closed protected physical-device workflow contract."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

import validate_mobile_acceptance_evidence as evidence


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mobile-protected-acceptance.yml"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"

EXPECTED_INPUTS = {
    "source_revision": (
        "Reviewed full lowercase commit SHA that exactly matches the selected main revision"
    ),
    "candidate_id": (
        "Installed signed-candidate manifest content ID in exact sha256 lowercase digest form"
    ),
    "provenance_id": (
        "Signed-release provenance manifest content ID in exact sha256 lowercase digest form"
    ),
    "confirmation": (
        "Type RUN_PROTECTED_MOBILE_ACCEPTANCE to exercise disposable staging accounts and physical devices"
    ),
}

EXPECTED_JOB_ENV = {
    "REQUESTED_REVISION": "${{ inputs.source_revision }}",
    "CANDIDATE_ID": "${{ inputs.candidate_id }}",
    "PROVENANCE_ID": "${{ inputs.provenance_id }}",
    "DISPATCH_CONFIRMATION": "${{ inputs.confirmation }}",
    "RUNNER_SESSION_ID": "${{ vars.PAKPERK_MOBILE_RUNNER_SESSION_ID }}",
    "DRIVER_SHA256": "${{ vars.PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256 }}",
    "ANDROID_SIGNER_SHA256": "${{ vars.PAKPERK_ANDROID_SIGNER_SHA256 }}",
    "IOS_TEAM_ID": "${{ vars.PAKPERK_IOS_TEAM_ID }}",
    "IOS_SIGNER_SHA256": "${{ vars.PAKPERK_IOS_SIGNER_SHA256 }}",
    "PATH": "/usr/bin:/bin",
    "PYTHONDONTWRITEBYTECODE": '"1"',
}

EXPECTED_STEP_NAMES = (
    "Verify exact reviewed main source and protected coordinates",
    "Verify protected macOS runner and signed candidate manifest",
    "Verify the pinned protected driver and device set",
    "Run complete protected physical-device acceptance",
    "Validate and atomically package sanitized acceptance evidence",
    "Verify packaged archive immediately before upload",
    "Upload exact-source protected mobile acceptance evidence",
    "Enforce protected mobile acceptance result",
)

# Every executable command and complete step boundary is content-locked. Updating
# either digest requires reviewing the corresponding workflow block and tamper tests.
EXPECTED_RUN_SHA256 = {
    "Verify exact reviewed main source and protected coordinates": (
        "2895c90f0cd9bdf77c7ac8ac02091ad9666e0553d8d7f36a527bf914a789c4f6"
    ),
    "Verify protected macOS runner and signed candidate manifest": (
        "6d4ce1fd6d59e17a39bffd9f27bf7b61981d03eaaef42478290e6269dbdcff49"
    ),
    "Verify the pinned protected driver and device set": (
        "1b4b90b4ae6e28862d670649aa0f80c0f5d32ac7756aa68edf513aeeec463d48"
    ),
    "Run complete protected physical-device acceptance": (
        "47d877c8357a5b288f60319b210e904285fcad6a23576ae71742080e1665dd27"
    ),
    "Validate and atomically package sanitized acceptance evidence": (
        "f36f94110916fa576203c779b285f20dd9aaf314132a555e0143603a252dc096"
    ),
    "Verify packaged archive immediately before upload": (
        "3281a8d9ec2dd7faed91d4fa07f2682a8350c3a3d77142d74d39085cdfa50535"
    ),
    "Enforce protected mobile acceptance result": (
        "04f13582f94ef4b6aa25b617f673fd1b1c1004b94000ae7200dc603f88ca205d"
    ),
}
EXPECTED_STEP_SHA256 = {
    "checkout": "6bc05ec1a7fbb3a14b447485291230172fdfe398392d701d6fc4ec2a09b4ca50",
    "Verify exact reviewed main source and protected coordinates": (
        "9aa66ab7b8e8183893476411ee3a1a2d057817a2d05ea47cfcff636bb4b093c5"
    ),
    "Verify protected macOS runner and signed candidate manifest": (
        "4acfb95e6ff896a9eb78286a9b1f84216b9c3d7628b7a2d2c5c2223ee7ab2b7f"
    ),
    "Verify the pinned protected driver and device set": (
        "4e47a5a2ccbdb20f6404f17729e8d663b2cab4a613eb986af0e00dd041491353"
    ),
    "Run complete protected physical-device acceptance": (
        "3736d77a90f7a35d95439751705f78612a449184cebdcec4b66eebadecda0c23"
    ),
    "Validate and atomically package sanitized acceptance evidence": (
        "29cd5d959ffeeb25ca5052fecefa612f0edd5270e958f24bfb8e1052f367277f"
    ),
    "Verify packaged archive immediately before upload": (
        "c10d15992f3c0b924c788b84397504c6211dfbb51f2712a4a7816cb184740cf4"
    ),
    "Upload exact-source protected mobile acceptance evidence": (
        "7fe157e59c1395c65f0a24f308291e5bfa19426e6c4d70ad48422283ecc47595"
    ),
    "Enforce protected mobile acceptance result": (
        "ce88e98afd2cfc364e1f578bc9ad8e87ed4dfed6d0561510f5671eb852ab66ce"
    ),
}


def _require(source: str, fragment: str, label: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"{label} is missing: {fragment}")


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


def _step_block(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"workflow must contain exactly one {label}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def _named_step(source: str, name: str) -> str:
    return _step_block(source, f"      - name: {name}\n", f"step named {name!r}")


def _require_step_keys(block: str, expected: list[str], label: str) -> None:
    keys = re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", block)
    if keys != expected:
        raise RuntimeError(
            f"{label} has an unexpected, duplicate, or reordered step key"
        )


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _require_step_digest(block: str, label: str) -> None:
    expected = EXPECTED_STEP_SHA256[label]
    if _digest(block) != expected:
        raise RuntimeError(f"{label} complete step block changed")


def _require_run_digest(block: str, label: str) -> None:
    marker = "        run: |\n"
    if block.count(marker) != 1:
        raise RuntimeError(f"{label} command boundary is malformed")
    command = block[block.index(marker) :]
    if _digest(command) != EXPECTED_RUN_SHA256[label]:
        raise RuntimeError(f"{label} executable command block changed")


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
    if source.count("\non:\n") != 1 or source.count("\npermissions:\n") != 1:
        raise RuntimeError("protected acceptance trigger boundary is malformed")
    start = source.index("\non:\n") + 1
    end = source.index("\npermissions:\n", start)
    trigger = source[start:end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("protected mobile acceptance must be manual-dispatch only")
    input_names = re.findall(r"(?m)^      ([a-z][a-z0-9_]*):$", trigger)
    if input_names != list(EXPECTED_INPUTS):
        raise RuntimeError("protected acceptance dispatch input surface changed")
    for name, description in EXPECTED_INPUTS.items():
        block = _input_block(trigger, name)
        if re.findall(r"(?m)^        ([a-z][a-z0-9_-]*):", block) != [
            "description",
            "required",
            "type",
        ]:
            raise RuntimeError(
                f"dispatch input {name} has an unexpected property surface"
            )
        expected = (
            f"      {name}:\n"
            f"        description: {description}\n"
            "        required: true\n"
            "        type: string"
        )
        if block.rstrip("\n") != expected:
            raise RuntimeError(
                f"dispatch input {name} is not one exact required string"
            )


def _validate_job_environment(source: str) -> None:
    marker = "\n    env:\n"
    if source.count(marker) != 1:
        raise RuntimeError("workflow must contain exactly one job environment binding")
    start = source.index(marker) + len(marker)
    end = source.index("\n    steps:\n", start)
    observed: dict[str, str] = {}
    for raw_line in source[start:end].splitlines():
        match = re.fullmatch(r"      ([A-Z][A-Z0-9_]*): (.+)", raw_line)
        if match is None:
            raise RuntimeError("job environment contains a malformed binding")
        name, value = match.groups()
        if name in observed:
            raise RuntimeError(f"job environment duplicates {name}")
        observed[name] = value
    if observed != EXPECTED_JOB_ENV:
        raise RuntimeError("job environment changed outside the reviewed bindings")


def _validate_steps(source: str) -> None:
    step_items = re.findall(r"(?m)^      -[^\n]*$", source)
    if any(
        re.fullmatch(r"      - (?:name: .+|uses: [^ #]+(?: # .+)?)", item) is None
        for item in step_items
    ):
        raise RuntimeError("workflow contains a non-canonical step item")
    headers = re.findall(r"(?m)^      - (name|uses): (.+)$", source)
    if len(headers) != 1 + len(EXPECTED_STEP_NAMES):
        raise RuntimeError(
            "protected acceptance workflow has an unexpected step surface"
        )
    if headers[0] != ("uses", f"{CHECKOUT_ACTION} # v7.0.1"):
        raise RuntimeError("protected acceptance checkout step changed")
    if (
        tuple(value for kind, value in headers[1:] if kind == "name")
        != EXPECTED_STEP_NAMES
    ):
        raise RuntimeError("protected acceptance steps changed or were reordered")

    actions = re.findall(r"(?m)^\s+(?:- )?uses: ([^ #]+)", source)
    if actions != [CHECKOUT_ACTION, UPLOAD_ACTION]:
        raise RuntimeError("workflow must use only the two reviewed pinned actions")
    if re.findall(r"(?m)^        shell: (.+)$", source) != ["bash"] * 7:
        raise RuntimeError("all executable workflow steps must use exact Bash shells")
    if source.count("        run: |\n") != 7:
        raise RuntimeError("workflow executable command surface changed")
    if re.findall(r"(?m)^        if: (.+)$", source) != [
        "always()",
        "always()",
        "steps.evidence-package.outcome == 'success' && "
        "steps.archive-verify.outcome == 'success'",
        "always()",
    ]:
        raise RuntimeError("workflow recovery guards changed")
    if re.findall(r"(?m)^        continue-on-error: (.+)$", source) != [
        "true",
        "true",
        "true",
        "true",
    ]:
        raise RuntimeError("workflow recoverable-step surface changed")
    if re.findall(r"(?m)^        id: (.+)$", source) != [
        "candidate",
        "acceptance",
        "evidence-package",
        "archive-verify",
        "evidence-upload",
    ]:
        raise RuntimeError("workflow step outcome/output bindings changed")

    checkout = _step_block(
        source,
        f"      - uses: {CHECKOUT_ACTION}",
        "exact-source checkout step",
    )
    _require_step_keys(checkout, ["with"], "exact-source checkout")
    _require_step_digest(checkout, "checkout")

    expected_keys = {
        EXPECTED_STEP_NAMES[0]: ["shell", "env", "run"],
        EXPECTED_STEP_NAMES[1]: ["id", "shell", "run"],
        EXPECTED_STEP_NAMES[2]: ["shell", "env", "run"],
        EXPECTED_STEP_NAMES[3]: ["id", "continue-on-error", "shell", "env", "run"],
        EXPECTED_STEP_NAMES[4]: [
            "id",
            "if",
            "continue-on-error",
            "shell",
            "env",
            "run",
        ],
        EXPECTED_STEP_NAMES[5]: [
            "id",
            "if",
            "continue-on-error",
            "shell",
            "env",
            "run",
        ],
        EXPECTED_STEP_NAMES[7]: ["if", "shell", "env", "run"],
    }
    for name, keys in expected_keys.items():
        block = _named_step(source, name)
        _require_step_keys(block, keys, name)
        _require_run_digest(block, name)
        _require_step_digest(block, name)

    upload = _named_step(source, EXPECTED_STEP_NAMES[6])
    _require_step_keys(
        upload, ["id", "if", "continue-on-error", "uses", "with"], "upload"
    )
    _require_step_digest(upload, EXPECTED_STEP_NAMES[6])


def _validate_secret_surface(source: str) -> None:
    expected_counts = {
        "PAKPERK_ANDROID_GESTURE_DEVICE_ID": 2,
        "PAKPERK_ANDROID_THREE_BUTTON_DEVICE_ID": 2,
        "PAKPERK_IOS_HOME_INDICATOR_DEVICE_ID": 2,
        "PAKPERK_IPAD_KEYBOARD_SECONDARY_SYNC_DEVICE_ID": 2,
        "PAKPERK_PRIMARY_TEST_ACCOUNT": 1,
        "PAKPERK_PRIMARY_TEST_PASSWORD": 1,
        "PAKPERK_SECONDARY_TEST_ACCOUNT": 1,
        "PAKPERK_SECONDARY_TEST_PASSWORD": 1,
        "PAKPERK_REPORT_TARGET_ACCOUNT": 1,
    }
    observed = re.findall(r"\$\{\{\s*secrets\.([A-Z][A-Z0-9_]*)\s*\}\}", source)
    for name, count in expected_counts.items():
        if observed.count(name) != count:
            raise RuntimeError(f"protected secret binding count changed for {name}")
    if set(observed) != set(expected_counts):
        raise RuntimeError("workflow consumes an unreviewed protected secret")
    for forbidden in (
        "set -x",
        "set -o xtrace",
        "bash -x",
        "printenv",
        "${{ github.token }}",
    ):
        if forbidden in source:
            raise RuntimeError(
                f"workflow contains a disclosure boundary bypass: {forbidden}"
            )


def _validate_semantic_contract(source: str) -> None:
    for forbidden in (
        "PAKPERK_STAGING_API_ORIGIN",
        "PAKPERK_STAGING_OIDC_ISSUER",
        "PAKPERK_STAGING_MOBILE_CLIENT_ID",
        "ANDROID_APPLICATION_ID",
        "IOS_APPLICATION_ID",
    ):
        if forbidden in source:
            raise RuntimeError(
                "protected workflow contains a mutable coordinate or application identity"
            )

    source_gate = _named_step(source, EXPECTED_STEP_NAMES[0])
    for fragment in (
        '[[ "$PROVENANCE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]',
        '[[ "$RUNNER_SESSION_ID" =~ ^sha256:[0-9a-f]{64}$ ]]',
        'python3 -I - mobile/config/staging.json "$GITHUB_ENV"',
        'hasattr(os, "O_NOFOLLOW")',
        "identity(metadata) != identity(before)",
        "value.st_ctime_ns",
        "object_pairs_hook=reject_duplicate_pairs",
        "parse_constant=reject_nonfinite_constant",
        'config.get("PAKPERK_API_BASE_URL")',
        'config.get("PAKPERK_OIDC_ISSUER_URL")',
        'config.get("PAKPERK_OIDC_CLIENT_ID")',
        'config.get("PAKPERK_FULLTEXT_POLICY") != "strict"',
        'output.write(f"STAGING_API_ORIGIN={api_origin}\\n")',
        'output.write(f"STAGING_OIDC_ISSUER={issuer}\\n")',
        'output.write(f"STAGING_OIDC_CLIENT_ID={client_id}\\n")',
    ):
        _require(source_gate, fragment, "exact staging source contract")

    candidate = _named_step(source, EXPECTED_STEP_NAMES[1])
    for fragment in (
        '[[ "$(uname -s)" != "Darwin" ]]',
        '[[ "$(command -v "$tool")" != "/usr/bin/$tool" ]]',
        "sys.version_info < (3, 9)",
        'candidate_manifest="/opt/pakperk/mobile-candidates/$candidate_digest.json"',
        'provenance_manifest="/opt/pakperk/mobile-release-provenance/$provenance_digest.json"',
        'runner_session_manifest="/opt/pakperk/mobile-runner-sessions/$runner_session_digest.json"',
        "python3 -I scripts/validate_mobile_acceptance_evidence.py validate-candidate",
        '--provenance-manifest "$provenance_manifest"',
        '--runner-session-manifest "$runner_session_manifest"',
        '--provenance-id "$PROVENANCE_ID"',
        '--runner-session-id "$RUNNER_SESSION_ID"',
        '--binding-output "$candidate_binding"',
        '--session-binding-output "$runner_session_binding"',
        "secrets.token_hex(32)",
        'output.write(f"challenge={secrets.token_hex(32)}\\n")',
        'output.write(f"not_before={not_before}\\n")',
    ):
        _require(candidate, fragment, "protected candidate and run binding")

    driver = _named_step(source, EXPECTED_STEP_NAMES[2])
    for fragment in (
        'pathlib.Path("/")',
        'pathlib.Path("/opt")',
        'pathlib.Path("/opt/pakperk")',
        'pathlib.Path("/opt/pakperk/bin")',
        "metadata.st_uid != 0",
        "metadata.st_mode & 0o022",
        'hasattr(os, "O_NOFOLLOW")',
        "before = os.fstat(descriptor)",
        "after = os.fstat(descriptor)",
        "current = os.lstat(path)",
        "identity(before) != identity(after)",
        "value.st_ctime_ns",
        "digest_state.hexdigest()",
        "if len(set(values)) != len(values):",
    ):
        _require(driver, fragment, "protected driver and device gate")

    acceptance = _named_step(source, EXPECTED_STEP_NAMES[3])
    scenario_match = re.search(
        r'(?ms)^              "scenarios": \[\n(?P<body>.*?)^              \],$',
        acceptance,
    )
    if scenario_match is None:
        raise RuntimeError("protected acceptance request lacks a closed scenario list")
    scenarios = tuple(
        re.findall(
            r'^                  "([a-z0-9_]+)",$',
            scenario_match["body"],
            re.MULTILINE,
        )
    )
    if scenarios != evidence.SCENARIO_IDS:
        raise RuntimeError(
            "protected acceptance scenarios differ from evidence contract"
        )
    role_match = re.search(
        r'(?ms)^              "device_roles": \[\n(?P<body>.*?)^              \],$',
        acceptance,
    )
    if role_match is None:
        raise RuntimeError(
            "protected acceptance request lacks a closed device-role list"
        )
    roles = tuple(
        re.findall(
            r'^                  "([a-z0-9_]+)",$',
            role_match["body"],
            re.MULTILINE,
        )
    )
    if roles != tuple(evidence.DEVICE_CONTRACT):
        raise RuntimeError(
            "protected acceptance device roles differ from evidence contract"
        )
    for fragment in (
        "CANDIDATE_MANIFEST: ${{ steps.candidate.outputs.manifest }}",
        "PROVENANCE_MANIFEST: ${{ steps.candidate.outputs.provenance_manifest }}",
        "RUNNER_SESSION_MANIFEST: ${{ steps.candidate.outputs.runner_session_manifest }}",
        "RUNNER_SESSION_BINDING: ${{ steps.candidate.outputs.runner_session_binding }}",
        "RUN_CHALLENGE: ${{ steps.candidate.outputs.challenge }}",
        "RUN_NOT_BEFORE: ${{ steps.candidate.outputs.not_before }}",
        "RUN_ID_BINDING: ${{ github.run_id }}",
        "RUN_ATTEMPT_BINDING: ${{ github.run_attempt }}",
        '"runner_session": runner_session_binding',
        '"device_identity_hash_contract": {',
        '"algorithm": "HMAC-SHA256"',
        '"key_source": "root-owned-runner-device-identity-key"',
        '"root_attestation_field": "physical_identities"',
        '"distinct_across_roles": True',
        '"retain_raw_device_identifiers": False',
        '--candidate-manifest "$CANDIDATE_MANIFEST"',
        '--provenance-manifest "$PROVENANCE_MANIFEST"',
        '--runner-session-manifest "$RUNNER_SESSION_MANIFEST"',
        ') >"$driver_log" 2>&1',
        "trap cleanup_driver_log EXIT",
        "unset GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY",
    ):
        _require(acceptance, fragment, "private protected driver invocation")

    package = _named_step(source, EXPECTED_STEP_NAMES[4])
    for fragment in (
        "git status --porcelain=v1 --untracked-files=all --ignored=matching",
        "python3 -I scripts/validate_mobile_acceptance_evidence.py validate-and-package",
        '--candidate-manifest "$CANDIDATE_MANIFEST"',
        '--provenance-manifest "$PROVENANCE_MANIFEST"',
        '--runner-session-manifest "$RUNNER_SESSION_MANIFEST"',
        '--provenance-id "$PROVENANCE_ID"',
        '--runner-session-id "$RUNNER_SESSION_ID"',
        '--run-id "$RUN_ID_BINDING"',
        '--run-attempt "$RUN_ATTEMPT_BINDING"',
        '--run-challenge "$RUN_CHALLENGE"',
        '--not-before "$RUN_NOT_BEFORE"',
        '--github-output "$GITHUB_OUTPUT"',
    ):
        _require(package, fragment, "isolated evidence validation and packaging")

    archive_verify = _named_step(source, EXPECTED_STEP_NAMES[5])
    for fragment in (
        "PACKAGE_OUTCOME: ${{ steps.evidence-package.outcome }}",
        "ARCHIVE_SHA256: ${{ steps.evidence-package.outputs.archive_sha256 }}",
        '[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]',
        "validate_mobile_acceptance_evidence.py verify-archive",
        '--expected-sha256 "$ARCHIVE_SHA256"',
    ):
        _require(archive_verify, fragment, "pre-upload archive verification")

    upload = _named_step(source, EXPECTED_STEP_NAMES[6])
    for fragment in (
        "if: steps.evidence-package.outcome == 'success' && "
        "steps.archive-verify.outcome == 'success'",
        "${{ steps.evidence-package.outputs.archive_sha256 }}",
        "if-no-files-found: error",
    ):
        _require(upload, fragment, "digest-bound archive upload")

    final = _named_step(source, EXPECTED_STEP_NAMES[7])
    for fragment in (
        "ARCHIVE_VERIFY_OUTCOME: ${{ steps.archive-verify.outcome }}",
        "ARCHIVE_SHA256: ${{ steps.evidence-package.outputs.archive_sha256 }}",
        "UPLOADED_ARTIFACT_DIGEST: ${{ steps.evidence-upload.outputs.artifact-digest }}",
        '[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ && '
        '"$UPLOADED_ARTIFACT_DIGEST" =~ ^[0-9a-f]{64}$ ]]',
    ):
        _require(final, fragment, "final archive digest binding")


def validate(workflow: pathlib.Path = WORKFLOW) -> None:
    source = workflow.read_text(encoding="utf-8")
    if "\r" in source or "\t" in source:
        raise RuntimeError("protected acceptance workflow must use canonical LF/spaces")
    if _mapping_keys(source, 0) != ["name", "on", "permissions", "concurrency", "jobs"]:
        raise RuntimeError("protected acceptance root mapping changed")
    if re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("YAML merge keys are forbidden")
    _validate_trigger(source)

    permissions_start = source.index("\npermissions:") + 1
    permissions_end = source.index("\nconcurrency:", permissions_start)
    if (
        source[permissions_start:permissions_end].strip()
        != "permissions:\n  contents: read"
    ):
        raise RuntimeError("protected acceptance permissions are not least privilege")
    concurrency_start = source.index("\nconcurrency:") + 1
    concurrency_end = source.index("\njobs:", concurrency_start)
    expected_concurrency = (
        "concurrency:\n"
        "  group: protected-mobile-acceptance\n"
        "  cancel-in-progress: false"
    )
    if source[concurrency_start:concurrency_end].strip() != expected_concurrency:
        raise RuntimeError("protected acceptance concurrency changed")

    jobs = source[source.index("\njobs:\n") + len("\njobs:\n") :]
    if _mapping_keys(jobs, 2) != ["protected-acceptance"]:
        raise RuntimeError("workflow must contain exactly one bounded protected job")
    job_start = source.index("  protected-acceptance:\n")
    env_start = source.index("    env:\n", job_start)
    expected_job_prefix = (
        "  protected-acceptance:\n"
        "    runs-on: [self-hosted, macOS, pakperk-mobile-acceptance]\n"
        "    environment: mobile-device-verification\n"
        "    timeout-minutes: 360\n"
    )
    if source[job_start:env_start] != expected_job_prefix:
        raise RuntimeError("protected macOS job execution boundary changed")
    if _mapping_keys(source[job_start:], 4) != [
        "runs-on",
        "environment",
        "timeout-minutes",
        "env",
        "steps",
    ]:
        raise RuntimeError("protected job has an unexpected or duplicate job-level key")
    if source.count("timeout-minutes:") != 1:
        raise RuntimeError("workflow must have one reviewed job timeout")

    _validate_job_environment(source)
    _validate_steps(source)
    _validate_secret_surface(source)
    _validate_semantic_contract(source)


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"mobile acceptance workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Protected mobile acceptance workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
