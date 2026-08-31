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
    "VALIDATOR_SHA256": "${{ vars.PAKPERK_MOBILE_ACCEPTANCE_VALIDATOR_SHA256 }}",
    "DRIVER_SHA256": "${{ vars.PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256 }}",
    "ANDROID_SIGNER_SHA256": "${{ vars.PAKPERK_ANDROID_SIGNER_SHA256 }}",
    "IOS_TEAM_ID": "${{ vars.PAKPERK_IOS_TEAM_ID }}",
    "IOS_SIGNER_SHA256": "${{ vars.PAKPERK_IOS_SIGNER_SHA256 }}",
    "PATH": "/usr/bin:/bin",
    "PYTHONDONTWRITEBYTECODE": '"1"',
    "BASH_ENV": "/dev/null",
    "ENV": "/dev/null",
}

EXPECTED_STEP_NAMES = (
    "Verify exact reviewed main source and protected coordinates",
    "Verify protected macOS runner, pinned tools, and signed candidate manifest",
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
        "8e0fa1fc1909878573561111b7810c600a49fda2c404ae155384d5672c25135d"
    ),
    "Verify protected macOS runner, pinned tools, and signed candidate manifest": (
        "68882b133588798cf62ff1a05ff8bb5198b9e8f191493f49a2e9af060f786ee0"
    ),
    "Run complete protected physical-device acceptance": (
        "7547673be6749d6090d083e20863e3785e107358a86a57ff3b7486f32e48469e"
    ),
    "Validate and atomically package sanitized acceptance evidence": (
        "89f990f5eee2e0f796bde6b3e0f9d43b428899464c6e1ee0eb4820cdb1d7976d"
    ),
    "Verify packaged archive immediately before upload": (
        "42d1946a5cef19170a294856ccaf4bf8c7a5898af87603b52a1d161ad2f46aca"
    ),
    "Enforce protected mobile acceptance result": (
        "04f13582f94ef4b6aa25b617f673fd1b1c1004b94000ae7200dc603f88ca205d"
    ),
}
EXPECTED_STEP_SHA256 = {
    "checkout": "6bc05ec1a7fbb3a14b447485291230172fdfe398392d701d6fc4ec2a09b4ca50",
    "Verify exact reviewed main source and protected coordinates": (
        "a0e153d5ddd7146825c5e27e1d6acdeb6080edd54a033269e417c13b098132be"
    ),
    "Verify protected macOS runner, pinned tools, and signed candidate manifest": (
        "9a12a6bdff51bf16c4e5658f91dac84f23d72320c71f93f1bee4b34b1b058465"
    ),
    "Run complete protected physical-device acceptance": (
        "b318ce0689502a1c4c477cc115e6172c727568e092db09725793e903e40d45b4"
    ),
    "Validate and atomically package sanitized acceptance evidence": (
        "bd51391cbdcec15dfc633d4068bacd6033ebd71be631021fe12277976c3818f7"
    ),
    "Verify packaged archive immediately before upload": (
        "893be12c8e2a483c54775371a2229838b789197da10ef509d60f566e9ffcbb1a"
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
    if re.findall(r"(?m)^        shell: (.+)$", source) != ["bash"] * 6:
        raise RuntimeError("all executable workflow steps must use exact Bash shells")
    if source.count("        run: |\n") != 6:
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
        "source",
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
        EXPECTED_STEP_NAMES[0]: ["id", "shell", "env", "run"],
        EXPECTED_STEP_NAMES[1]: ["id", "shell", "env", "run"],
        EXPECTED_STEP_NAMES[2]: ["id", "continue-on-error", "shell", "env", "run"],
        EXPECTED_STEP_NAMES[3]: [
            "id",
            "if",
            "continue-on-error",
            "shell",
            "env",
            "run",
        ],
        EXPECTED_STEP_NAMES[4]: [
            "id",
            "if",
            "continue-on-error",
            "shell",
            "env",
            "run",
        ],
        EXPECTED_STEP_NAMES[6]: ["if", "shell", "env", "run"],
    }
    for name, keys in expected_keys.items():
        block = _named_step(source, name)
        _require_step_keys(block, keys, name)
        _require_run_digest(block, name)
        _require_step_digest(block, name)

    upload = _named_step(source, EXPECTED_STEP_NAMES[5])
    _require_step_keys(
        upload, ["id", "if", "continue-on-error", "uses", "with"], "upload"
    )
    _require_step_digest(upload, EXPECTED_STEP_NAMES[5])


def _validate_secret_surface(source: str) -> None:
    expected_counts = {
        "PAKPERK_ANDROID_GESTURE_DEVICE_ID": 1,
        "PAKPERK_ANDROID_THREE_BUTTON_DEVICE_ID": 1,
        "PAKPERK_IOS_HOME_INDICATOR_DEVICE_ID": 1,
        "PAKPERK_IPAD_KEYBOARD_SECONDARY_SYNC_DEVICE_ID": 1,
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
    acceptance = _named_step(
        source, "Run complete protected physical-device acceptance"
    )
    outside_acceptance = source.replace(acceptance, "", 1)
    if re.search(r"\$\{\{\s*secrets\.", outside_acceptance):
        raise RuntimeError(
            "protected secrets must be bound only to the pinned-driver step"
        )
    if (
        "          BASH_ENV: /dev/null\n" not in acceptance
        or "          ENV: /dev/null\n" not in acceptance
    ):
        raise RuntimeError("credentialed shell startup files are not pinned closed")
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


def _validate_candidate_execution_boundary(source: str) -> None:
    """Keep the candidate checkout data-only for the whole protected runner job."""

    for forbidden in (
        "scripts/",
        "${{ github.workspace }}",
        "$GITHUB_WORKSPACE",
        "/bin/bash",
        "/bin/sh",
        "nohup ",
        "disown",
        "setsid ",
        "subprocess",
        "os.system",
        "os.spawn",
        "Popen",
        "eval ",
    ):
        if forbidden in source:
            raise RuntimeError(
                f"candidate checkout must remain data-only; found {forbidden!r}"
            )
    if re.search(r"(?m)^ {10}[^#\n]*[^&]&[ \t]*$", source):
        raise RuntimeError("protected workflow must not launch a background process")
    if source.count(
        "validator=/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py"
    ) != 1:
        raise RuntimeError("root-owned validator path must be assigned exactly once")
    if source.count("exec /opt/pakperk/bin/pakperk-mobile-acceptance-driver run") != 1:
        raise RuntimeError("root-owned driver must be the only acceptance executable")
    if source.count("GITHUB_ENV") != 1 or source.count("GITHUB_PATH") != 1:
        raise RuntimeError("protected workflow command-file surface changed")
    if (
        "unset GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY RUNNER_TEMP"
        not in source
    ):
        raise RuntimeError("driver must not inherit GitHub command-file paths")
    if source.count("BASH_ENV") != 2:
        raise RuntimeError("shell startup-file boundary changed")
    for match in re.finditer(r"(?m)^ {10}/usr/bin/python3(?P<tail>[^\n]*)$", source):
        tail = match.group("tail").strip()
        if not (
            tail.startswith("-I -")
            or tail == '-I "$validator" validate-candidate \\'
            or tail == "-I \\"
        ):
            raise RuntimeError("protected Python may not execute candidate-authored code")
    if re.search(r"(?m)^ {10}(?:source|\.)[ \t]+", source):
        raise RuntimeError("protected workflow may not source candidate-authored files")


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
        '[[ "$VALIDATOR_SHA256" =~ ^[0-9a-f]{64}$ ]]',
        "/usr/bin/python3 -I - \\",
        '"$RUNNER_TEMP/pakperk-mobile-source-binding.json"',
        '"$GITHUB_OUTPUT" <<\'PY\'',
        'hasattr(os, "O_NOFOLLOW")',
        "identity(metadata) != identity(before)",
        "value.st_ctime_ns",
        "object_pairs_hook=reject_duplicate_pairs",
        "parse_constant=reject_nonfinite_constant",
        'config.get("PAKPERK_API_BASE_URL")',
        'config.get("PAKPERK_APP_LINK_ORIGIN")',
        'config.get("PAKPERK_OIDC_ISSUER_URL")',
        'config.get("PAKPERK_OIDC_CLIENT_ID")',
        'config.get("PAKPERK_FULLTEXT_POLICY") != "strict"',
        "any(ord(character) < 0x20 or ord(character) == 0x7f",
        "parsed.geturl() != value",
        '"app_link_origin": app_link_origin',
        f'"schema": {evidence.SOURCE_BINDING_SCHEMA_VERSION}',
        "os.O_WRONLY | os.O_CREAT | os.O_EXCL",
        'f"app_version={match.group(1)}\\n"',
        'f"build_number={match.group(2)}\\n"',
        'f"source_binding={binding_path}\\n"',
    ):
        _require(source_gate, fragment, "exact staging source contract")
    if "$GITHUB_ENV" in source_gate:
        raise RuntimeError("candidate data must not write the cross-step environment")

    candidate = _named_step(source, EXPECTED_STEP_NAMES[1])
    for fragment in (
        '[[ "$(/usr/bin/uname -s)" != "Darwin" ]]',
        '[[ "$(command -v "$tool")" != "/usr/bin/$tool" ]]',
        "sys.version_info < (3, 9)",
        "validator=/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py",
        "driver=/opt/pakperk/bin/pakperk-mobile-acceptance-driver",
        '"$validator" "$VALIDATOR_SHA256"',
        '"$driver" "$DRIVER_SHA256"',
        'pathlib.Path("/")',
        'pathlib.Path("/opt")',
        'pathlib.Path("/opt/pakperk")',
        'pathlib.Path("/opt/pakperk/bin")',
        "metadata.st_uid != 0",
        "metadata.st_mode & 0o022",
        "before = os.fstat(descriptor)",
        "after = os.fstat(descriptor)",
        "current = os.lstat(path)",
        "identity(before) != identity(after)",
        "verify(validator_path, validator_digest, \"acceptance validator\", False)",
        "verify(driver_path, driver_digest, \"acceptance driver\", True)",
        'candidate_manifest="/opt/pakperk/mobile-candidates/$candidate_digest.json"',
        'provenance_manifest="/opt/pakperk/mobile-release-provenance/$provenance_digest.json"',
        'runner_session_manifest="/opt/pakperk/mobile-runner-sessions/$runner_session_digest.json"',
        '/usr/bin/python3 -I "$validator" validate-candidate',
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

    acceptance = _named_step(source, EXPECTED_STEP_NAMES[2])
    candidate_binding_contract = (
        "          if set(candidate_binding) != {\n"
        '              "manifest_id",\n'
        '              "provenance_id",\n'
        '              "signed_workflow",\n'
        '              "strict_full_text",\n'
        '              "mobile_feature_evidence",\n'
        '              "android",\n'
        '              "ios",\n'
        "          }:\n"
        '              raise SystemExit("candidate binding does not match its closed key contract")'
    )
    if acceptance.count(candidate_binding_contract) != 1:
        raise RuntimeError(
            "protected acceptance request lacks the closed candidate binding"
        )
    mobile_feature_contract = (
        '          mobile_feature_evidence = candidate_binding["mobile_feature_evidence"]\n'
        "          if (\n"
        "              not isinstance(mobile_feature_evidence, dict)\n"
        "              or set(mobile_feature_evidence) != {\n"
        '                  "schema",\n'
        '                  "sha256",\n'
        '                  "paperTitleSearch",\n'
        '                  "libraryImportWrites",\n'
        '                  "readingFeed",\n'
        '                  "toReadFirstEnforcement",\n'
        '                  "libraryV2",\n'
        '                  "recommendations",\n'
        '                  "recommendationEvents",\n'
        '                  "searchLookup",\n'
        '                  "searchExplore",\n'
        '                  "savedQueries",\n'
        '                  "researchProfiles",\n'
        '                  "readingBriefs",\n'
        '                  "subscriptions",\n'
        '                  "notifications",\n'
        '                  "deepReader",\n'
        '                  "paperPassport",\n'
        '                  "semanticFacets",\n'
        '                  "documentVisualObjects",\n'
        '                  "readingCheckpoints",\n'
        '                  "annotations",\n'
        '                  "evidenceCards",\n'
        '                  "researchMemory",\n'
        '                  "versionDiff",\n'
        '                  "assistantV2",\n'
        "              }\n"
        '              or type(mobile_feature_evidence["schema"]) is not int\n'
        '              or mobile_feature_evidence["schema"] != 6\n'
        '              or not isinstance(mobile_feature_evidence["sha256"], str)\n'
        '              or len(mobile_feature_evidence["sha256"]) != 64\n'
        "              or any(\n"
        '                  character not in "0123456789abcdef"\n'
        '                  for character in mobile_feature_evidence["sha256"]\n'
        "              )\n"
        "              or any(\n"
        "                  type(mobile_feature_evidence[key]) is not bool\n"
        "                  for key in (\n"
        '                      "paperTitleSearch",\n'
        '                      "libraryImportWrites",\n'
        '                      "readingFeed",\n'
        '                      "toReadFirstEnforcement",\n'
        '                      "libraryV2",\n'
        '                      "recommendations",\n'
        '                      "recommendationEvents",\n'
        '                      "searchLookup",\n'
        '                      "searchExplore",\n'
        '                      "savedQueries",\n'
        '                      "researchProfiles",\n'
        '                      "readingBriefs",\n'
        '                      "subscriptions",\n'
        '                      "notifications",\n'
        '                      "deepReader",\n'
        '                      "paperPassport",\n'
        '                      "semanticFacets",\n'
        '                      "documentVisualObjects",\n'
        '                      "readingCheckpoints",\n'
        '                      "annotations",\n'
        '                      "evidenceCards",\n'
        '                      "researchMemory",\n'
        '                      "versionDiff",\n'
        '                      "assistantV2",\n'
        "                  )\n"
        "              )\n"
        "              or any(\n"
        "                  mobile_feature_evidence[key] is not True\n"
        "                  for key in (\n"
        '                      "paperTitleSearch",\n'
        '                      "libraryImportWrites",\n'
        '                      "readingFeed",\n'
        '                      "toReadFirstEnforcement",\n'
        '                      "libraryV2",\n'
        '                      "recommendations",\n'
        '                      "recommendationEvents",\n'
        '                      "searchLookup",\n'
        '                      "searchExplore",\n'
        '                      "savedQueries",\n'
        '                      "researchProfiles",\n'
        '                      "readingBriefs",\n'
        '                      "subscriptions",\n'
        '                      "notifications",\n'
        '                      "deepReader",\n'
        '                      "paperPassport",\n'
        '                      "semanticFacets",\n'
        '                      "documentVisualObjects",\n'
        '                      "readingCheckpoints",\n'
        '                      "annotations",\n'
        '                      "evidenceCards",\n'
        '                      "researchMemory",\n'
        '                      "versionDiff",\n'
        '                      "assistantV2",\n'
        "                  )\n"
        "              )\n"
        "          ):\n"
        '              raise SystemExit("candidate mobile feature evidence is invalid")'
    )
    if acceptance.count(mobile_feature_contract) != 1:
        raise RuntimeError(
            "protected acceptance request lacks exact mobile feature evidence"
        )
    request_schema = (
        '          request = {\n'
        f'              "schema": {evidence.EVIDENCE_SCHEMA_VERSION},\n'
    )
    if acceptance.count(request_schema) != 1:
        raise RuntimeError(
            "protected acceptance request lacks the exact schema version"
        )
    acceptance_contract = (
        '              "acceptance_contract": {\n'
        f'                  "schema": {evidence.EVIDENCE_SCHEMA_VERSION},\n'
        f'                  "scenario_count": {evidence.SCENARIO_COUNT},\n'
        f'                  "assertion_count": {evidence.ASSERTION_COUNT},\n'
        f'                  "metric_count": {evidence.METRIC_COUNT},\n'
        f'                  "sha256": "{evidence.SCENARIO_CONTRACT_SHA256}",\n'
        "              },"
    )
    if acceptance.count(acceptance_contract) != 1:
        raise RuntimeError(
            "protected acceptance request lacks the exact scenario contract"
        )
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
    performance_contract = (
        '              "performance_metric_rules": {\n'
        '                  "cold_cache_launch": {\n'
        '                      "cached_first_readable_frame_p95_ms": '
        f'["range", 1, {evidence.CACHED_FIRST_READABLE_FRAME_P95_MAX_MS}],\n'
        '                      "opening_transition_ms": '
        f'["range", 1, {evidence.OPENING_TRANSITION_MAX_MS}],\n'
        "                  },\n"
        '                  "plan03_reader_queue_and_large_document_safety": {\n'
        '                      "large_document_fixture_blocks": '
        f'["eq", {evidence.LARGE_DOCUMENT_FIXTURE_BLOCKS}, None],\n'
        '                      "large_document_minimum_blocks_traversed_per_device": '
        f'["eq", {evidence.LARGE_DOCUMENT_BLOCKS_TRAVERSED_PER_DEVICE}, None],\n'
        '                      "large_document_minimum_pages_traversed_per_device": '
        f'["min", {evidence.LARGE_DOCUMENT_MIN_PAGES_TRAVERSED}, None],\n'
        '                      "large_document_minimum_page_fetch_samples_per_device": '
        f'["min", {evidence.LARGE_DOCUMENT_MIN_PAGE_FETCH_SAMPLES}, None],\n'
        '                      "large_document_minimum_frame_samples_per_device": '
        f'["min", {evidence.LARGE_DOCUMENT_MIN_FRAME_SAMPLES}, None],\n'
        '                      "large_document_minimum_scroll_window_seconds_per_device": '
        f'["min", {evidence.LARGE_DOCUMENT_MIN_SCROLL_WINDOW_SECONDS}, None],\n'
        '                      "large_document_requested_page_size_blocks": '
        f'["eq", {evidence.LARGE_DOCUMENT_REQUEST_PAGE_SIZE_BLOCKS}, None],\n'
        '                      "large_document_peak_retained_blocks": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_MAX_RETAINED_BLOCKS}],\n'
        '                      "large_document_worst_device_first_page_ms": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_FIRST_PAGE_MAX_MS}],\n'
        '                      "large_document_worst_device_page_fetch_p95_ms": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_PAGE_FETCH_P95_MAX_MS}],\n'
        '                      "large_document_worst_device_scroll_frame_p95_us": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_SCROLL_FRAME_P95_MAX_US}],\n'
        '                      "large_document_worst_device_scroll_frame_max_us": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_SCROLL_FRAME_MAX_US}],\n'
        '                      "large_document_worst_device_missed_frame_ratio_basis_points": '
        f'["range", 0, {evidence.LARGE_DOCUMENT_MISSED_FRAME_RATIO_MAX_BPS}],\n'
        '                      "large_document_worst_device_peak_rss_growth_mib": '
        f'["range", 0, {evidence.LARGE_DOCUMENT_PEAK_RSS_GROWTH_MAX_MIB}],\n'
        '                      "large_document_worst_device_maximum_live_block_widgets": '
        f'["range", 1, {evidence.LARGE_DOCUMENT_MAX_LIVE_BLOCK_WIDGETS}],\n'
        "                  },\n"
        "              },"
    )
    if acceptance.count(performance_contract) != 1:
        raise RuntimeError(
            "protected acceptance request lacks the exact performance metric rules"
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
        "SOURCE_BINDING: ${{ steps.source.outputs.source_binding }}",
        "PAKPERK_APP_VERSION: ${{ steps.source.outputs.app_version }}",
        "PAKPERK_BUILD_NUMBER: ${{ steps.source.outputs.build_number }}",
        "BASH_ENV: /dev/null",
        "ENV: /dev/null",
        '"runner_session": runner_session_binding',
        '"mobile_feature_evidence": mobile_feature_evidence',
        '"acceptance_contract": {',
        '"performance_metric_rules": {',
        '"device_identity_hash_contract": {',
        '"algorithm": "HMAC-SHA256"',
        '"key_source": "root-owned-runner-device-identity-key"',
        '"root_attestation_field": "physical_identities"',
        '"distinct_across_roles": True',
        '"retain_raw_device_identifiers": False',
        "source_binding = load(sys.argv[4], 32 * 1024, \"source binding\")",
        f'source_binding["schema"] != {evidence.SOURCE_BINDING_SCHEMA_VERSION}',
        '"api_origin": source_binding["api_origin"]',
        '"app_link_origin": source_binding["app_link_origin"]',
        "os.O_WRONLY | os.O_CREAT | os.O_EXCL",
        '--candidate-manifest "$CANDIDATE_MANIFEST"',
        '--provenance-manifest "$PROVENANCE_MANIFEST"',
        '--runner-session-manifest "$RUNNER_SESSION_MANIFEST"',
        ') >"$driver_log" 2>&1',
        "trap cleanup_driver_log EXIT",
        "unset GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY",
    ):
        _require(acceptance, fragment, "private protected driver invocation")

    package = _named_step(source, EXPECTED_STEP_NAMES[3])
    for fragment in (
        "/usr/bin/git status --porcelain=v1 --untracked-files=all --ignored=matching",
        "/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py",
        "validate-and-package",
        '--candidate-manifest "$CANDIDATE_MANIFEST"',
        '--provenance-manifest "$PROVENANCE_MANIFEST"',
        '--runner-session-manifest "$RUNNER_SESSION_MANIFEST"',
        '--provenance-id "$PROVENANCE_ID"',
        '--runner-session-id "$RUNNER_SESSION_ID"',
        '--validator-sha256 "$VALIDATOR_SHA256"',
        '--driver-sha256 "$DRIVER_SHA256"',
        '--source-binding "$SOURCE_BINDING"',
        '--run-id "$RUN_ID_BINDING"',
        '--run-attempt "$RUN_ATTEMPT_BINDING"',
        '--run-challenge "$RUN_CHALLENGE"',
        '--not-before "$RUN_NOT_BEFORE"',
        '--github-output "$GITHUB_OUTPUT"',
    ):
        _require(package, fragment, "isolated evidence validation and packaging")

    archive_verify = _named_step(source, EXPECTED_STEP_NAMES[4])
    for fragment in (
        "PACKAGE_OUTCOME: ${{ steps.evidence-package.outcome }}",
        "ARCHIVE_SHA256: ${{ steps.evidence-package.outputs.archive_sha256 }}",
        '[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]',
        "/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py",
        "verify-archive",
        '--expected-sha256 "$ARCHIVE_SHA256"',
        '--expected-validator-sha256 "$VALIDATOR_SHA256"',
        '--expected-driver-sha256 "$DRIVER_SHA256"',
    ):
        _require(archive_verify, fragment, "pre-upload archive verification")

    upload = _named_step(source, EXPECTED_STEP_NAMES[5])
    for fragment in (
        "if: steps.evidence-package.outcome == 'success' && "
        "steps.archive-verify.outcome == 'success'",
        "${{ steps.evidence-package.outputs.archive_sha256 }}",
        "if-no-files-found: error",
    ):
        _require(upload, fragment, "digest-bound archive upload")

    final = _named_step(source, EXPECTED_STEP_NAMES[6])
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
    _validate_candidate_execution_boundary(source)
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
