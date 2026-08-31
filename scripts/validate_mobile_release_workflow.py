#!/usr/bin/env python3
"""Validate the split, fail-closed signed-mobile release workflow."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys

import validate_flutter_toolchain as flutter_toolchain


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mobile-release.yml"
SECURITY_WORKFLOW = ROOT / ".github/workflows/security.yml"
IOS_VERIFIER = ROOT / "scripts/verify_ios_release_artifact.sh"
SECRET_MATERIALIZER = ROOT / "scripts/materialize_mobile_release_secret.py"
MOBILE_CONFIGS = tuple(
    ROOT / f"mobile/config/{name}.json" for name in ("dev", "staging", "prod")
)

CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
DOWNLOAD_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
FLUTTER_ACTION = "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2"
EXPECTED_WORKFLOW_SHA256 = (
    "e726a3e7627f7901ad7e00f67a2c1c116bd3be344f12305df3f89655e3475ec5"
)
EXPECTED_IOS_VERIFIER_SHA256 = (
    "e5e0193a51b71f1455eeadae610d82155abaf5257ddf7fad1d927c1fcadeaee5"
)
EXPECTED_GEMFILE_LOCK_SHA256 = (
    "df7c9313182c54ae68a3312f720334dc9f524d17973f6a3b1339e8892d778175"
)
EXPECTED_HELPER_SHA256 = {
    "assemble_mobile_signed_candidate.py": "dbfd4d0b49d71db400f52e1073e68c700696e1c9d9126b2bfb5115f1c84a7882",
    "capture_mobile_credentialed_runtime.py": "2d51f03bd21f2afa2af0396e801e0e950172210814a229ca50df67c5a8d135cd",
    "extract_mobile_store_client.py": "f1f2b989dd433223114c85451147404ad4e65992d1f5a86ed3f3c6937ea1fd3a",
    "finalize_mobile_signed_release.py": "5b1fab036a7be9ee87364b8209e0834c17437e1f40ff283aeeb3416e1762d6c1",
    "generate_mobile_store_upload_attempt.py": "61b72373391b5fd8d9ae92e69f5ebd7b03c52d1675eb7be870425e4d1ceef183",
    "generate_mobile_store_upload_handoff.py": "aaf319c661faf1b7eb775b50e7f842c42a7c4d23cbc32a6d8fb2e4c8ff2c2f40",
    "manage_app_store_phased_release.rb": "ee7e55a902bfe4f1f9fe2f933871e44d51c1f8906eff93aad8c8aa6c3f05b68c",
    "manage_google_play_rollout.rb": "2fb30a5ed3341e22254d2e6548d22b9b10e235176317b7b403d48d49d445c3ac",
    "materialize_mobile_release_secret.py": "1f82f4ae7a6771c19f963f42436d1cc1bc196b4d55fa88261b368b6356c204d4",
    "prepare_mobile_credentialed_upload.py": "b6c4597b55db335fc46af14e0ba9c6969e99ca8ec29d43c817d699045fe12498",
    "prepare_mobile_store_client.sh": "2346df0d861df39b5b0b6f580b6afb49648e9d7f6468c22dd47948f84a0ec076",
    "validate_mobile_signed_release_run.py": "e0581035290e5b8fbf8236863a8f4c2c6914569f1e23a9571cc482b6f070cf93",
    "validate_mobile_store_candidate.py": "b9be3edb7d8486db5d4e4e86757340c76a8902278d4f977242d95a51c5ca172e",
    "validate_mobile_store_client.py": "6172367be00718dce1beff7523bfa0988502b0860e6752912864817a92d2e4bf",
}

JOB_IDS = (
    "candidate-preparation",
    "android-signed-candidate",
    "ios-signed-candidate",
    "signed-candidate",
    "store-client-bootstrap",
    "android-store-upload",
    "ios-store-upload",
    "signed-release-finalizer",
)
JOB_NAMES = {
    "candidate-preparation": "${{ inputs.environment }} credential-free candidate preparation",
    "android-signed-candidate": "${{ inputs.environment }} isolated Android signed candidate",
    "ios-signed-candidate": "${{ inputs.environment }} isolated iOS signed candidate",
    "signed-candidate": "${{ inputs.environment }} signed candidate",
    "store-client-bootstrap": "isolated store-client bootstrap",
    "android-store-upload": "${{ inputs.environment }} isolated Android store upload",
    "ios-store-upload": "${{ inputs.environment }} isolated iOS store upload",
    "signed-release-finalizer": "${{ inputs.environment }} signed release finalizer",
}
ANDROID_SIGNING_SECRETS = {
    "PAKPERK_ANDROID_APP_SIGNING_SHA256",
    "PAKPERK_ANDROID_KEY_ALIAS",
    "PAKPERK_ANDROID_KEY_PASSWORD",
    "PAKPERK_ANDROID_KEYSTORE_BASE64",
    "PAKPERK_ANDROID_STORE_PASSWORD",
}
IOS_SIGNING_SECRETS = {
    "PAKPERK_DEVELOPMENT_TEAM",
    "PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_BASE64",
    "PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD",
    "PAKPERK_IOS_PROVISIONING_PROFILE_BASE64",
    "PAKPERK_IOS_PROVISIONING_PROFILE_SPECIFIER",
}
ANDROID_STORE_SECRETS = {"PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64"}
IOS_STORE_SECRETS = {
    "PAKPERK_APP_STORE_CONNECT_ISSUER_ID",
    "PAKPERK_APP_STORE_CONNECT_KEY_ID",
    "PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64",
}
TO_READ_FIRST_FEATURES = (
    ("PAPER_TITLE_SEARCH", "PAKPERK_PAPER_TITLE_SEARCH_ENABLED", "paperTitleSearch"),
    (
        "LIBRARY_IMPORT_WRITES",
        "PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED",
        "libraryImportWrites",
    ),
    ("READING_FEED", "PAKPERK_READING_FEED_ENABLED", "readingFeed"),
    (
        "TO_READ_FIRST_ENFORCEMENT",
        "PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED",
        "toReadFirstEnforcement",
    ),
)
PLAN02_FEATURES = (
    ("LIBRARY_V2", "PAKPERK_LIBRARY_V2_ENABLED", "libraryV2"),
    ("RECOMMENDATIONS", "PAKPERK_RECOMMENDATIONS_ENABLED", "recommendations"),
    (
        "RECOMMENDATION_EVENTS",
        "PAKPERK_RECOMMENDATION_EVENTS_ENABLED",
        "recommendationEvents",
    ),
    ("SEARCH_LOOKUP", "PAKPERK_SEARCH_LOOKUP_ENABLED", "searchLookup"),
    ("SEARCH_EXPLORE", "PAKPERK_SEARCH_EXPLORE_ENABLED", "searchExplore"),
    ("SAVED_QUERIES", "PAKPERK_SAVED_QUERIES_ENABLED", "savedQueries"),
    (
        "RESEARCH_PROFILES",
        "PAKPERK_RESEARCH_PROFILES_ENABLED",
        "researchProfiles",
    ),
    ("READING_BRIEFS", "PAKPERK_READING_BRIEFS_ENABLED", "readingBriefs"),
    ("SUBSCRIPTIONS", "PAKPERK_SUBSCRIPTIONS_ENABLED", "subscriptions"),
    ("NOTIFICATIONS", "PAKPERK_NOTIFICATIONS_ENABLED", "notifications"),
)
PLAN03_FEATURES = (
    ("DEEP_READER", "PAKPERK_DEEP_READER_ENABLED", "deepReader"),
    ("PAPER_PASSPORT", "PAKPERK_PAPER_PASSPORT_ENABLED", "paperPassport"),
    ("SEMANTIC_FACETS", "PAKPERK_SEMANTIC_FACETS_ENABLED", "semanticFacets"),
    (
        "DOCUMENT_VISUAL_OBJECTS",
        "PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED",
        "documentVisualObjects",
    ),
    (
        "READING_CHECKPOINTS",
        "PAKPERK_READING_CHECKPOINTS_ENABLED",
        "readingCheckpoints",
    ),
    ("ANNOTATIONS", "PAKPERK_ANNOTATIONS_ENABLED", "annotations"),
    ("EVIDENCE_CARDS", "PAKPERK_EVIDENCE_CARDS_ENABLED", "evidenceCards"),
    ("RESEARCH_MEMORY", "PAKPERK_RESEARCH_MEMORY_ENABLED", "researchMemory"),
    ("VERSION_DIFF", "PAKPERK_VERSION_DIFF_ENABLED", "versionDiff"),
    ("ASSISTANT_V2", "PAKPERK_ASSISTANT_V2_ENABLED", "assistantV2"),
)
MOBILE_RELEASE_FEATURES = TO_READ_FIRST_FEATURES + PLAN02_FEATURES + PLAN03_FEATURES
SANITIZED_SHELL = "        shell: /bin/bash --noprofile --norc -e -o pipefail {0}\n"


def _require(source: str, fragments: tuple[str, ...], label: str) -> None:
    for fragment in fragments:
        if fragment not in source:
            raise RuntimeError(f"{label} is missing: {fragment}")


def _mapping_keys(source: str, indent: int) -> list[str]:
    prefix = " " * indent
    nested = prefix + " "
    keys: list[str] = []
    for line in source.splitlines():
        if not line.startswith(prefix) or line.startswith(nested):
            continue
        content = line[indent:]
        if content and not content.startswith("#") and ":" in content:
            keys.append(content.partition(":")[0].strip())
    return keys


def _job_block(source: str, name: str) -> str:
    marker = f"  {name}:\n"
    if source.count(marker) != 1:
        raise RuntimeError(f"workflow must contain exactly one {name!r} job")
    start = source.index(marker)
    match = re.search(r"(?m)^  [a-z][a-z0-9-]*:\n", source[start + len(marker) :])
    return (
        source[start:]
        if match is None
        else source[start : start + len(marker) + match.start()]
    )


def _step_block(job: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if job.count(marker) != 1:
        raise RuntimeError(f"job must contain exactly one step named {name!r}")
    start = job.index(marker)
    end = job.find("\n      - ", start + len(marker))
    return job[start:] if end < 0 else job[start:end]


def _ordered(job: str, names: tuple[str, ...], label: str) -> None:
    positions: list[int] = []
    for name in names:
        marker = f"      - name: {name}\n"
        if job.count(marker) != 1:
            raise RuntimeError(f"{label} must contain exactly one {name!r} step")
        positions.append(job.index(marker))
    if positions != sorted(positions):
        raise RuntimeError(f"{label} step ordering changed")


def _secrets(source: str) -> set[str]:
    return set(re.findall(r"\$\{\{\s*secrets\.([A-Z0-9_]+)\s*}}", source))


def _require_sanitized(block: str, label: str) -> None:
    _require(
        block,
        (
            SANITIZED_SHELL.rstrip("\n"),
            "          BASH_ENV: /dev/null",
            "          ENV: /dev/null",
            '          DYLD_INSERT_LIBRARIES: ""',
            '          DYLD_LIBRARY_PATH: ""',
            '          LD_LIBRARY_PATH: ""',
            '          LD_PRELOAD: ""',
        ),
        label,
    )


def _validate_mobile_feature_contract(
    block: str, *, materialization: bool, label: str
) -> None:
    _require(
        block,
        tuple(
            f"RELEASE_{short}_ENABLED: ${{{{ vars.{config_key} }}}}"
            for short, config_key, _ in MOBILE_RELEASE_FEATURES
        )
        + tuple(config_key for _, config_key, _ in MOBILE_RELEASE_FEATURES)
        + (
            '"schema": 6',
            '"paperTitleSearch":',
            '"libraryImportWrites":',
            '"readingFeed":',
            '"toReadFirstEnforcement":',
            '"libraryV2":',
            '"recommendations":',
            '"recommendationEvents":',
            '"searchLookup":',
            '"searchExplore":',
            '"savedQueries":',
            '"researchProfiles":',
            '"readingBriefs":',
            '"subscriptions":',
            '"notifications":',
            '"deepReader":',
            '"paperPassport":',
            '"semanticFacets":',
            '"documentVisualObjects":',
            '"readingCheckpoints":',
            '"annotations":',
            '"evidenceCards":',
            '"researchMemory":',
            '"versionDiff":',
            '"assistantV2":',
        ),
        label,
    )
    if materialization:
        _require(
            block,
            tuple(
                f'"{evidence_key}": config["{config_key}"] == "true",'
                for _, config_key, evidence_key in MOBILE_RELEASE_FEATURES
            )
            + tuple(
                f'("{short}", "{config_key}"),'
                for short, config_key, _ in MOBILE_RELEASE_FEATURES
            )
            + (
                'raw = os.environ.get(f"RELEASE_{short_name}_ENABLED", "") or "false"',
                'protected["PAKPERK_PAPER_TITLE_SEARCH_ENABLED"] == "true" and protected["PAKPERK_ACCOUNTS_ENABLED"] != "true"',
                'protected["PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED"] == "true" and (',
                'protected["PAKPERK_READING_FEED_ENABLED"] == "true" and (',
                'protected["PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true"',
                'protected["PAKPERK_LIBRARY_V2_ENABLED"] == "true" and (',
                'protected["PAKPERK_RECOMMENDATIONS_ENABLED"] == "true" and (',
                'protected["PAKPERK_SEARCH_EXPLORE_ENABLED"] == "true" and protected["PAKPERK_SEARCH_LOOKUP_ENABLED"] != "true"',
                'protected["PAKPERK_SAVED_QUERIES_ENABLED"] == "true" and (',
                'protected["PAKPERK_RESEARCH_PROFILES_ENABLED"] == "true" and protected["PAKPERK_ACCOUNTS_ENABLED"] != "true"',
                'protected["PAKPERK_READING_BRIEFS_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true"',
                'protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] == "true" and (',
                'protected["PAKPERK_NOTIFICATIONS_ENABLED"] == "true" and protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] != "true"',
                'protected["PAKPERK_DEEP_READER_ENABLED"] == "true" and (',
                '"PAKPERK_PAPER_PASSPORT_ENABLED",',
                '"PAKPERK_SEMANTIC_FACETS_ENABLED",',
                '"PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED",',
                '"PAKPERK_READING_CHECKPOINTS_ENABLED",',
                '"PAKPERK_ANNOTATIONS_ENABLED",',
                '"PAKPERK_VERSION_DIFF_ENABLED",',
                '"PAKPERK_ASSISTANT_V2_ENABLED",',
                'protected["PAKPERK_EVIDENCE_CARDS_ENABLED"] == "true" and protected["PAKPERK_ANNOTATIONS_ENABLED"] != "true"',
                'protected["PAKPERK_RESEARCH_MEMORY_ENABLED"] == "true" and protected["PAKPERK_EVIDENCE_CARDS_ENABLED"] != "true"',
                'handle.write(f"feature_evidence_sha256={feature_digest}\\n")',
            ),
            label,
        )
        for statement in (
            'if protected["PAKPERK_PAPER_TITLE_SEARCH_ENABLED"] == "true" and protected["PAKPERK_ACCOUNTS_ENABLED"] != "true":',
            'if protected["PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED"] == "true" and (',
            'if protected["PAKPERK_READING_FEED_ENABLED"] == "true" and (',
            'if protected["PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true":',
            'if protected["PAKPERK_LIBRARY_V2_ENABLED"] == "true" and (',
            'if protected["PAKPERK_RECOMMENDATIONS_ENABLED"] == "true" and (',
            'if protected["PAKPERK_SEARCH_EXPLORE_ENABLED"] == "true" and protected["PAKPERK_SEARCH_LOOKUP_ENABLED"] != "true":',
            'if protected["PAKPERK_SAVED_QUERIES_ENABLED"] == "true" and (',
            'if protected["PAKPERK_RESEARCH_PROFILES_ENABLED"] == "true" and protected["PAKPERK_ACCOUNTS_ENABLED"] != "true":',
            'if protected["PAKPERK_READING_BRIEFS_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true":',
            'if protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] == "true" and (',
            'if protected["PAKPERK_NOTIFICATIONS_ENABLED"] == "true" and protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] != "true":',
        ):
            if block.count(f"\n              {statement}\n") != 1:
                raise RuntimeError(f"{label} dependency statement is not top-level")
        return
    _require(
        block,
        tuple(
            f'"{evidence_key}": expected_config["{config_key}"] == "true",'
            for _, config_key, evidence_key in MOBILE_RELEASE_FEATURES
        )
        + (
            'value = os.environ.get("RELEASE_" + short + "_ENABLED", "") or "false"',
            'expected_config.get("PAKPERK_PAPER_TITLE_SEARCH_ENABLED") == "true" and expected_config.get("PAKPERK_ACCOUNTS_ENABLED") != "true"',
            'expected_config.get("PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_READING_FEED_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED") == "true" and expected_config.get("PAKPERK_READING_FEED_ENABLED") != "true"',
            'expected_config.get("PAKPERK_LIBRARY_V2_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_RECOMMENDATIONS_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_SEARCH_EXPLORE_ENABLED") == "true" and expected_config.get("PAKPERK_SEARCH_LOOKUP_ENABLED") != "true"',
            'expected_config.get("PAKPERK_SAVED_QUERIES_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_RESEARCH_PROFILES_ENABLED") == "true" and expected_config.get("PAKPERK_ACCOUNTS_ENABLED") != "true"',
            'expected_config.get("PAKPERK_READING_BRIEFS_ENABLED") == "true" and expected_config.get("PAKPERK_READING_FEED_ENABLED") != "true"',
            'expected_config.get("PAKPERK_SUBSCRIPTIONS_ENABLED") == "true" and (',
            'expected_config.get("PAKPERK_NOTIFICATIONS_ENABLED") == "true" and expected_config.get("PAKPERK_SUBSCRIPTIONS_ENABLED") != "true"',
            'expected_config.get("PAKPERK_DEEP_READER_ENABLED") == "true" and (',
            '"PAKPERK_PAPER_PASSPORT_ENABLED",',
            '"PAKPERK_SEMANTIC_FACETS_ENABLED",',
            '"PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED",',
            '"PAKPERK_READING_CHECKPOINTS_ENABLED",',
            '"PAKPERK_ANNOTATIONS_ENABLED",',
            '"PAKPERK_VERSION_DIFF_ENABLED",',
            '"PAKPERK_ASSISTANT_V2_ENABLED",',
            'expected_config.get("PAKPERK_EVIDENCE_CARDS_ENABLED") == "true" and expected_config.get("PAKPERK_ANNOTATIONS_ENABLED") != "true"',
            'expected_config.get("PAKPERK_RESEARCH_MEMORY_ENABLED") == "true" and expected_config.get("PAKPERK_EVIDENCE_CARDS_ENABLED") != "true"',
            "if actual_config != expected_config:",
            "if actual_evidence != expected_evidence:",
        ),
        label,
    )
    for statement in (
        'if expected_config.get("PAKPERK_PAPER_TITLE_SEARCH_ENABLED") == "true" and expected_config.get("PAKPERK_ACCOUNTS_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_READING_FEED_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED") == "true" and expected_config.get("PAKPERK_READING_FEED_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_LIBRARY_V2_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_RECOMMENDATIONS_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_SEARCH_EXPLORE_ENABLED") == "true" and expected_config.get("PAKPERK_SEARCH_LOOKUP_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_SAVED_QUERIES_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_RESEARCH_PROFILES_ENABLED") == "true" and expected_config.get("PAKPERK_ACCOUNTS_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_READING_BRIEFS_ENABLED") == "true" and expected_config.get("PAKPERK_READING_FEED_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_SUBSCRIPTIONS_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_NOTIFICATIONS_ENABLED") == "true" and expected_config.get("PAKPERK_SUBSCRIPTIONS_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_DEEP_READER_ENABLED") == "true" and (',
        'if expected_config.get("PAKPERK_EVIDENCE_CARDS_ENABLED") == "true" and expected_config.get("PAKPERK_ANNOTATIONS_ENABLED") != "true":',
        'if expected_config.get("PAKPERK_RESEARCH_MEMORY_ENABLED") == "true" and expected_config.get("PAKPERK_EVIDENCE_CARDS_ENABLED") != "true":',
        'actual_config = json.loads(root.joinpath("mobile-release-config.json").read_text(encoding="utf-8"))',
    ):
        if block.count(f"\n          {statement}\n") != 1:
            raise RuntimeError(f"{label} statement is not at the re-attestation level")


def _validate_default_feature_configs() -> None:
    expected = {config_key: "false" for _, config_key, _ in MOBILE_RELEASE_FEATURES}
    for path in MOBILE_CONFIGS:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("mobile release config is unreadable") from error
        if not isinstance(value, dict) or any(
            value.get(key) != state for key, state in expected.items()
        ):
            raise RuntimeError("protected mobile release defaults must stay off")


def _validate_download(step: str, artifact_id: str, label: str) -> None:
    _require(
        step,
        (
            f"uses: {DOWNLOAD_ACTION} # v8.0.1",
            f"artifact-ids: {artifact_id}",
            "merge-multiple: true",
            "digest-mismatch: error",
            'NODE_OPTIONS: ""',
        ),
        label,
    )


def _validate_secret_step(
    job: str, step_name: str, expected: set[str], label: str
) -> None:
    step = _step_block(job, step_name)
    if _secrets(job) != expected or _secrets(step) != expected:
        raise RuntimeError(f"{label} credential family or scope changed")
    if any(
        job.count(f"secrets.{name}") != 1 or step.count(f"secrets.{name}") != 1
        for name in expected
    ):
        raise RuntimeError(f"{label} credential reference cardinality changed")
    _require_sanitized(step, label)


def _validate_helpers(workflow_source: str) -> None:
    for name, expected in EXPECTED_HELPER_SHA256.items():
        path = ROOT / "scripts" / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"reviewed helper changed: {name}")
        if name not in workflow_source or expected not in workflow_source:
            raise RuntimeError(f"workflow does not bind reviewed helper bytes: {name}")
    lock = ROOT / "mobile/Gemfile.lock"
    if hashlib.sha256(lock.read_bytes()).hexdigest() != EXPECTED_GEMFILE_LOCK_SHA256:
        raise RuntimeError("reviewed mobile/Gemfile.lock changed")
    _require(
        workflow_source,
        ("mobile/Gemfile.lock", EXPECTED_GEMFILE_LOCK_SHA256),
        "store-client lockfile transfer",
    )


def _validate_preparation(job: str) -> None:
    head = job[: job.index("    steps:\n")]
    if "    environment:" in head or _secrets(job):
        raise RuntimeError("candidate preparation must be credential-free")
    _require(
        job,
        (
            f"uses: {CHECKOUT_ACTION} # v7.0.1",
            "ref: ${{ inputs.source_revision }}",
            "persist-credentials: false",
            'if [[ "${{ inputs.upload_to_stores }}" == true && "$RELEASE_ENVIRONMENT" != production ]]; then',
            "      - name: Materialize protected mobile feature flags\n",
            "      - name: Retain immutable credential-free prepared mobile config\n",
            "          name: mobile-prepared-config-${{ github.run_id }}-${{ github.run_attempt }}",
            "          if-no-files-found: error",
            f"uses: {FLUTTER_ACTION} # v2.23.0",
            "      - name: Gate candidate on the complete Flutter test suite\n",
        ),
        "credential-free candidate preparation",
    )
    _ordered(
        job,
        (
            "Materialize protected mobile feature flags",
            "Retain immutable credential-free prepared mobile config",
            "Gate candidate on the complete Flutter test suite",
        ),
        "candidate preparation",
    )
    materialize = _step_block(job, "Materialize protected mobile feature flags")
    _require_sanitized(materialize, "prepared config materialization")
    _validate_mobile_feature_contract(
        materialize,
        materialization=True,
        label="prepared To Read First feature contract",
    )
    _require(
        materialize,
        ("          PATH: /usr/bin:/bin:/usr/sbin:/sbin", "/usr/bin/python3 -I -"),
        "prepared config isolation",
    )


def _validate_signer(job: str, *, platform: str) -> None:
    android = platform == "Android"
    download_name = (
        "Download immutable credential-free prepared config"
        if android
        else "Download immutable credential-free prepared config for iOS"
    )
    reattest_name = f"Re-attest {platform} prepared config before credentials"
    secret_step_name = (
        "Materialize Android-only signing credentials before repository code"
        if android
        else "Import Apple-only signing credentials before repository code"
    )
    expected_secrets = ANDROID_SIGNING_SECRETS if android else IOS_SIGNING_SECRETS
    _require(
        job,
        (
            "    needs: candidate-preparation\n",
            "    environment: ${{ inputs.environment }}\n",
            f"uses: {CHECKOUT_ACTION} # v7.0.1",
            "ref: ${{ inputs.source_revision }}",
            "persist-credentials: false",
            "EXPECTED_ARTIFACT_ID: ${{ needs.candidate-preparation.outputs.prepared_artifact_id }}",
            "EXPECTED_ARTIFACT_DIGEST: ${{ needs.candidate-preparation.outputs.prepared_artifact_digest }}",
            "EXPECTED_CONFIG_SHA256: ${{ needs.candidate-preparation.outputs.prepared_config_sha256 }}",
            "EXPECTED_FEATURE_EVIDENCE_SHA256: ${{ needs.candidate-preparation.outputs.prepared_feature_evidence_sha256 }}",
            "if-no-files-found: error",
        ),
        f"{platform} signer boundary",
    )
    _ordered(
        job, (download_name, reattest_name, secret_step_name), f"{platform} signer"
    )
    _validate_download(
        _step_block(job, download_name),
        "${{ needs.candidate-preparation.outputs.prepared_artifact_id }}",
        f"{platform} prepared-config transfer",
    )
    reattest = _step_block(job, reattest_name)
    _require_sanitized(reattest, f"{platform} prepared-config re-attestation")
    _validate_mobile_feature_contract(
        reattest,
        materialization=False,
        label=f"{platform} To Read First feature re-attestation",
    )
    _validate_secret_step(job, secret_step_name, expected_secrets, f"{platform} signer")
    first_secret = min(job.index(name) for name in expected_secrets)
    if first_secret < job.index(f"      - name: {reattest_name}\n"):
        raise RuntimeError(
            f"{platform} signing credentials appear before prepared-config re-attestation"
        )
    if android:
        _require(
            job,
            (
                "      - name: Build and inspect signed Android artifacts\n",
                "      - name: Remove Android-only signing material\n",
                "      - name: Retain isolated signed Android candidate\n",
            ),
            "Android signer product",
        )
    else:
        _require(
            job,
            (
                "      - name: Build and inspect signed iOS artifact\n",
                "      - name: Remove Apple-only signing material\n",
                "      - name: Retain isolated signed iOS candidate\n",
                EXPECTED_IOS_VERIFIER_SHA256,
            ),
            "iOS signer product",
        )


def _validate_aggregator(job: str) -> None:
    head = job[: job.index("    steps:\n")]
    _require(
        head,
        (
            "    needs: [candidate-preparation, android-signed-candidate, ios-signed-candidate]\n",
            "      artifact_digest: ${{ steps.signed_candidate_upload.outputs.artifact-digest }}\n",
            "      artifact_id: ${{ steps.signed_candidate_upload.outputs.artifact-id }}\n",
            "      candidate_id: ${{ steps.manifests.outputs.candidate_id }}\n",
            "      provenance_id: ${{ steps.manifests.outputs.provenance_id }}\n",
        ),
        "credential-free candidate aggregator",
    )
    if "    environment:" in head or _secrets(job):
        raise RuntimeError("candidate aggregator must be credential-free")
    _ordered(
        job,
        (
            "Verify credential-free aggregation identity",
            "Download immutable prepared config for aggregation",
            "Download immutable Android signer result for aggregation",
            "Download immutable iOS signer result for aggregation",
            "Assemble canonical credential-free signed candidate",
            "Retain canonical signed candidate",
            "Revalidate canonical candidate after retention",
        ),
        "candidate aggregator",
    )
    for step_name, artifact_id in (
        (
            "Download immutable prepared config for aggregation",
            "${{ needs.candidate-preparation.outputs.prepared_artifact_id }}",
        ),
        (
            "Download immutable Android signer result for aggregation",
            "${{ needs.android-signed-candidate.outputs.artifact_id }}",
        ),
        (
            "Download immutable iOS signer result for aggregation",
            "${{ needs.ios-signed-candidate.outputs.artifact_id }}",
        ),
    ):
        _validate_download(_step_block(job, step_name), artifact_id, step_name)
    identity = _step_block(job, "Verify credential-free aggregation identity")
    _require(
        identity,
        (
            '[[ "$PREPARED_ARTIFACT_ID" != "$ANDROID_ARTIFACT_ID" && \\\n',
            'for value in "$PREPARED_ARTIFACT_DIGEST" "$ANDROID_ARTIFACT_DIGEST" "$IOS_ARTIFACT_DIGEST"; do',
            '[[ "$checked_out" != "$REQUESTED_REVISION" || \\\n',
        ),
        "aggregator immutable identity",
    )
    assemble = _step_block(job, "Assemble canonical credential-free signed candidate")
    revalidate = _step_block(job, "Revalidate canonical candidate after retention")
    for block, verb in ((assemble, "assemble"), (revalidate, "verify")):
        _require_sanitized(block, f"candidate {verb}")
        _require(
            block,
            (
                EXPECTED_HELPER_SHA256["assemble_mobile_signed_candidate.py"],
                "/usr/bin/python3 -I",
                f'assemble_mobile_signed_candidate.py" {verb}',
            ),
            f"candidate {verb}",
        )
    _require(
        assemble,
        (
            '--feature-evidence-sha256 "${{ needs.candidate-preparation.outputs.prepared_feature_evidence_sha256 }}"',
        ),
        "candidate feature-evidence provenance binding",
    )
    _require(
        _step_block(job, "Retain canonical signed candidate"),
        (
            f"uses: {UPLOAD_ACTION} # v7.0.1",
            "name: pakperk-${{ inputs.environment }}-${{ needs.candidate-preparation.outputs.version_name }}-",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        "canonical candidate retention",
    )


def _validate_bootstrap(job: str) -> None:
    head = job[: job.index("    steps:\n")]
    _require(
        head,
        (
            "    needs: signed-candidate\n",
            "    if: inputs.upload_to_stores\n",
            "      archive_artifact_digest: ${{ steps.store_client_archive_upload.outputs.artifact-digest }}\n",
            "      archive_artifact_id: ${{ steps.store_client_archive_upload.outputs.artifact-id }}\n",
        ),
        "store-client bootstrap",
    )
    if "    environment:" in head or _secrets(job):
        raise RuntimeError("store-client bootstrap must be credential-free")
    _ordered(
        job,
        (
            "Verify isolated store-client bootstrap source",
            "Prepare bootstrap store client",
            "Package attested store client for isolated transfer",
            "Retain attested store-client transfer",
        ),
        "store-client bootstrap",
    )
    package = _step_block(job, "Package attested store client for isolated transfer")
    _require_sanitized(package, "store-client package")
    _require(
        package,
        (
            '"$GITHUB_WORKSPACE/scripts/validate_mobile_store_client.py" verify',
            '/usr/bin/tar -C "$STORE_CLIENT_ROOT" -czf "$archive"',
            "scripts/prepare_mobile_credentialed_upload.py",
            "scripts/generate_mobile_store_upload_handoff.py",
            "scripts/finalize_mobile_signed_release.py",
            "mobile/Gemfile.lock",
        ),
        "store-client control package",
    )


def _validate_upload(job: str, *, platform: str) -> None:
    android = platform == "Android"
    head = job[: job.index("    steps:\n")]
    _require(
        head,
        (
            "    needs: [signed-candidate, store-client-bootstrap]\n",
            "    if: inputs.upload_to_stores\n",
            "    environment: ${{ inputs.environment }}\n",
            f"      evidence_artifact_digest: ${{{{ steps.{platform.lower()}_evidence_upload.outputs.artifact-digest }}}}\n",
            f"      evidence_artifact_id: ${{{{ steps.{platform.lower()}_evidence_upload.outputs.artifact-id }}}}\n",
        ),
        f"{platform} store-upload boundary",
    )
    if (
        CHECKOUT_ACTION in job
        or "actions/checkout@" in job
        or "$GITHUB_WORKSPACE" in job
    ):
        raise RuntimeError(
            f"{platform} store upload must execute only transferred controls"
        )
    candidate_step = f"Download immutable {platform} signed candidate"
    controls_step = f"Download attested {platform} store controls and client"
    reattest_step = (
        f"Re-attest {platform} candidate controls and client before credentials"
    )
    if android:
        upload_step = "Upload Android candidate with Android-only credential"
        cleanup_step = "Remove isolated Android credential and client"
        outcome_step = "Record isolated Android upload outcome"
        retention_step = "Retain isolated Android upload evidence"
        fail_step = "Fail isolated Android upload after evidence retention"
        expected_secrets = ANDROID_STORE_SECRETS
        required_manager = "manage_google_play_rollout.rb"
        forbidden_manager = "manage_app_store_phased_release.rb"
    else:
        upload_step = "Upload and verify iOS candidate with iOS-only credentials"
        cleanup_step = "Remove isolated iOS credentials and client"
        outcome_step = "Record isolated iOS upload outcome"
        retention_step = "Retain isolated iOS upload evidence"
        fail_step = "Fail isolated iOS upload after evidence retention"
        expected_secrets = IOS_STORE_SECRETS
        required_manager = "manage_app_store_phased_release.rb"
        forbidden_manager = "manage_google_play_rollout.rb"
    _ordered(
        job,
        (
            candidate_step,
            controls_step,
            reattest_step,
            upload_step,
            cleanup_step,
            outcome_step,
            retention_step,
            fail_step,
        ),
        f"{platform} store upload",
    )
    _validate_download(
        _step_block(job, candidate_step),
        "${{ needs.signed-candidate.outputs.artifact_id }}",
        f"{platform} candidate transfer",
    )
    _validate_download(
        _step_block(job, controls_step),
        "${{ needs.store-client-bootstrap.outputs.archive_artifact_id }}",
        f"{platform} store-client transfer",
    )
    reattest = _step_block(job, reattest_step)
    _require_sanitized(reattest, f"{platform} pre-credential re-attestation")
    _require(
        reattest,
        (
            "EXPECTED_CANDIDATE_ARTIFACT_ID: ${{ needs.signed-candidate.outputs.artifact_id }}",
            "EXPECTED_CANDIDATE_ARTIFACT_DIGEST: ${{ needs.signed-candidate.outputs.artifact_digest }}",
            "EXPECTED_STORE_CLIENT_ARTIFACT_ID: ${{ needs.store-client-bootstrap.outputs.archive_artifact_id }}",
            "EXPECTED_STORE_CLIENT_ARTIFACT_DIGEST: ${{ needs.store-client-bootstrap.outputs.archive_artifact_digest }}",
            '[[ "$EXPECTED_CANDIDATE_ARTIFACT_ID" != "$EXPECTED_STORE_CLIENT_ARTIFACT_ID" ]] || exit 1',
            EXPECTED_HELPER_SHA256["prepare_mobile_credentialed_upload.py"],
            EXPECTED_HELPER_SHA256["validate_mobile_signed_release_run.py"],
            '/usr/bin/python3 -I - "$CONTROL_ROOT"',
        ),
        f"{platform} upload pre-attestation",
    )
    _validate_secret_step(
        job, upload_step, expected_secrets, f"{platform} store upload"
    )
    if job.index(next(iter(expected_secrets))) < job.index(
        f"      - name: {reattest_step}\n"
    ):
        raise RuntimeError(f"{platform} store credential appears before re-attestation")
    upload = _step_block(job, upload_step)
    if required_manager not in job or forbidden_manager in job:
        raise RuntimeError(f"{platform} store upload client family changed")
    _require(
        upload,
        (
            "CONTROL_ROOT: ${{ runner.temp }}/store-client-transfer/controls",
            '/usr/bin/env -i PATH="$PATH" HOME="$HOME"',
            '"$CONTROL_ROOT/materialize_mobile_release_secret.py" decode',
            "generate_mobile_store_upload_attempt.py",
            "validate_mobile_store_candidate.py",
            "validate_mobile_signed_release_run.py",
            "validate_mobile_store_client.py",
        ),
        f"{platform} isolated upload execution",
    )
    for step_name in (cleanup_step, outcome_step, retention_step, fail_step):
        block = _step_block(job, step_name)
        if "        if: always()\n" not in block:
            raise RuntimeError(
                f"{platform} evidence/cleanup step is not unconditional: {step_name}"
            )
    outcome = _step_block(job, outcome_step)
    _require(
        outcome,
        (
            '"classification": "isolated mobile store upload platform outcome"',
            f'"platform": "{platform.lower()}"',
            '"requested": True',
            '"status": "succeeded_verified"',
            "CANDIDATE_ARTIFACT_DIGEST: ${{ needs.signed-candidate.outputs.artifact_digest }}",
            "STORE_CLIENT_ARTIFACT_DIGEST: ${{ needs.store-client-bootstrap.outputs.archive_artifact_digest }}",
        ),
        f"{platform} canonical platform outcome",
    )
    _require(
        _step_block(job, retention_step),
        (
            f"uses: {UPLOAD_ACTION} # v7.0.1",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        f"{platform} evidence retention",
    )


def _validate_finalizer(job: str) -> None:
    head = job[: job.index("    steps:\n")]
    _require(
        head,
        (
            "    needs: [signed-candidate, store-client-bootstrap, android-store-upload, ios-store-upload]\n",
            "    if: always()\n",
            "      handoff_artifact_digest: ${{ steps.handoff_upload.outputs.artifact-digest }}\n",
            "      handoff_artifact_id: ${{ steps.handoff_upload.outputs.artifact-id }}\n",
            "      outcome_artifact_digest: ${{ steps.final_outcome_upload.outputs.artifact-digest }}\n",
            "      outcome_artifact_id: ${{ steps.final_outcome_upload.outputs.artifact-id }}\n",
        ),
        "signed-release finalizer",
    )
    if "    environment:" in head or _secrets(job):
        raise RuntimeError("signed-release finalizer must be credential-free")
    _ordered(
        job,
        (
            "Download final canonical signed candidate by artifact ID",
            "Download final attested store controls by artifact ID",
            "Download immutable Android upload outcome by artifact ID",
            "Download immutable iOS upload outcome by artifact ID",
            "Create verified cross-platform store handoff",
            "Retain immutable verified store handoff",
            "Create unconditional canonical signed-release outcome",
            "Retain unconditional aggregate signed-release evidence",
            "Enforce canonical final signed-release result after retention",
        ),
        "signed-release finalizer",
    )
    for step_name, artifact_id in (
        (
            "Download final canonical signed candidate by artifact ID",
            "${{ needs.signed-candidate.outputs.artifact_id }}",
        ),
        (
            "Download final attested store controls by artifact ID",
            "${{ needs.store-client-bootstrap.outputs.archive_artifact_id }}",
        ),
        (
            "Download immutable Android upload outcome by artifact ID",
            "${{ needs.android-store-upload.outputs.evidence_artifact_id }}",
        ),
        (
            "Download immutable iOS upload outcome by artifact ID",
            "${{ needs.ios-store-upload.outputs.evidence_artifact_id }}",
        ),
    ):
        _validate_download(_step_block(job, step_name), artifact_id, step_name)
    handoff = _step_block(job, "Create verified cross-platform store handoff")
    _require_sanitized(handoff, "cross-platform handoff")
    _require(
        handoff,
        (
            "if: inputs.upload_to_stores && needs.signed-candidate.result == 'success'",
            "needs.android-store-upload.result == 'success'",
            "needs.ios-store-upload.result == 'success'",
            EXPECTED_HELPER_SHA256["generate_mobile_store_upload_handoff.py"],
            EXPECTED_HELPER_SHA256["validate_mobile_signed_release_run.py"],
            '--tooling-root "$CONTROL_ROOT"',
            '/usr/bin/python3 -I - "$CONTROL_ROOT"',
        ),
        "cross-platform handoff",
    )
    outcome = _step_block(job, "Create unconditional canonical signed-release outcome")
    _require_sanitized(outcome, "canonical signed-release outcome")
    _require(
        outcome,
        (
            "        if: always()",
            EXPECTED_HELPER_SHA256["finalize_mobile_signed_release.py"],
            'finalize_mobile_signed_release.py"',
            '--requested-uploads "${{ inputs.upload_to_stores }}"',
            '--environment "${{ inputs.environment }}"',
            '--android-application-id "${{ needs.signed-candidate.outputs.bundle_id }}"',
            '--ios-application-id "${{ needs.signed-candidate.outputs.bundle_id }}"',
            '--candidate-job-result "${{ needs.signed-candidate.result }}"',
            '--bootstrap-job-result "${{ needs.store-client-bootstrap.result }}"',
            '--android-job-result "${{ needs.android-store-upload.result }}"',
            '--ios-job-result "${{ needs.ios-store-upload.result }}"',
            '--android-evidence-artifact-digest "${{ needs.android-store-upload.outputs.evidence_artifact_digest }}"',
            '--ios-evidence-artifact-digest "${{ needs.ios-store-upload.outputs.evidence_artifact_digest }}"',
            '--handoff-step-outcome "${{ steps.handoff.outcome }}"',
            '--handoff-upload-outcome "${{ steps.handoff_upload.outcome }}"',
        ),
        "canonical signed-release finalization",
    )
    retain = _step_block(job, "Retain unconditional aggregate signed-release evidence")
    _require(
        retain,
        (
            "        if: always()",
            f"uses: {UPLOAD_ACTION} # v7.0.1",
            "name: pakperk-${{ inputs.environment }}-store-outcome-",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        "aggregate signed-release evidence retention",
    )
    enforce = _step_block(
        job, "Enforce canonical final signed-release result after retention"
    )
    _require(
        enforce,
        (
            "        if: always()",
            "FINAL_OUTCOME: ${{ steps.final_outcome.outputs.overall_result }}",
            "RETENTION_STEP: ${{ steps.final_outcome_upload.outcome }}",
            '[[ "$FINALIZATION_STEP" == success && "$RETENTION_STEP" == success && \\\n',
            '"$FINAL_OUTCOME" == succeeded ]]',
        ),
        "post-retention final failure gate",
    )


def validate(
    workflow: pathlib.Path = WORKFLOW,
    security_workflow: pathlib.Path = SECURITY_WORKFLOW,
    ios_verifier: pathlib.Path = IOS_VERIFIER,
    secret_materializer: pathlib.Path = SECRET_MATERIALIZER,
) -> None:
    _validate_default_feature_configs()
    if (
        flutter_toolchain.EXPECTED_FLUTTER_VERSION,
        flutter_toolchain.EXPECTED_FRAMEWORK_REVISION,
        flutter_toolchain.EXPECTED_DART_SDK_VERSION,
    ) != ("3.44.8", "058e0af2c2b57e369d905a03ac9748b0ebf543c6", "3.12.2"):
        raise RuntimeError("reviewed Flutter release identity changed")

    source = workflow.read_text(encoding="utf-8")
    if "\t" in source or "\r" in source or re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("workflow contains non-canonical YAML structure")
    if _mapping_keys(source, 0) != [
        "name",
        "on",
        "permissions",
        "concurrency",
        "env",
        "jobs",
    ]:
        raise RuntimeError("signed-mobile root mapping changed")
    _require(
        source,
        (
            "name: signed-mobile-release\n",
            "on:\n  workflow_dispatch:\n",
            "permissions:\n  contents: read\n",
            "concurrency:\n  group: signed-mobile-${{ inputs.environment }}\n  cancel-in-progress: false\n",
            "  FLUTTER_VERSION: 3.44.8\n",
            "  PAKPERK_RUBY_VERSION: 3.4.10\n",
            "  PAKPERK_RUBYGEMS_VERSION: 4.0.17\n",
            "  BUNDLER_VERSION: 2.6.9\n",
        ),
        "signed-mobile root contract",
    )
    jobs_source = source[source.index("jobs:\n") :]
    if tuple(_mapping_keys(jobs_source, 2)) != JOB_IDS:
        raise RuntimeError("signed-mobile eight-job isolation surface changed")
    jobs = {name: _job_block(source, name) for name in JOB_IDS}
    for job_id, display_name in JOB_NAMES.items():
        if f"    name: {display_name}\n" not in jobs[job_id]:
            raise RuntimeError(f"signed-mobile display name changed: {job_id}")
    if source.count("    environment: ${{ inputs.environment }}\n") != 4:
        raise RuntimeError(
            "protected environment surface must contain exactly four jobs"
        )

    allowed_actions = {CHECKOUT_ACTION, DOWNLOAD_ACTION, UPLOAD_ACTION, FLUTTER_ACTION}
    actions = re.findall(r"(?m)^\s+uses: ([^\s#]+)", source)
    if not actions or any(action not in allowed_actions for action in actions):
        raise RuntimeError("workflow action pin surface changed")
    if (
        source.count(CHECKOUT_ACTION) != 6
        or source.count(DOWNLOAD_ACTION) != 13
        or source.count(UPLOAD_ACTION) != 9
    ):
        raise RuntimeError("workflow action boundary count changed")

    _validate_preparation(jobs["candidate-preparation"])
    _validate_signer(jobs["android-signed-candidate"], platform="Android")
    _validate_signer(jobs["ios-signed-candidate"], platform="iOS")
    _validate_aggregator(jobs["signed-candidate"])
    _validate_bootstrap(jobs["store-client-bootstrap"])
    _validate_upload(jobs["android-store-upload"], platform="Android")
    _validate_upload(jobs["ios-store-upload"], platform="iOS")
    _validate_finalizer(jobs["signed-release-finalizer"])

    expected_all_secrets = (
        ANDROID_SIGNING_SECRETS
        | IOS_SIGNING_SECRETS
        | ANDROID_STORE_SECRETS
        | IOS_STORE_SECRETS
    )
    if _secrets(source) != expected_all_secrets:
        raise RuntimeError("signed-mobile secret surface changed")
    _validate_helpers(source)
    if (
        hashlib.sha256(secret_materializer.read_bytes()).hexdigest()
        != EXPECTED_HELPER_SHA256["materialize_mobile_release_secret.py"]
    ):
        raise RuntimeError("secret materializer bytes changed")
    if (
        hashlib.sha256(ios_verifier.read_bytes()).hexdigest()
        != EXPECTED_IOS_VERIFIER_SHA256
    ):
        raise RuntimeError("signed iOS artifact verifier changed")

    security = security_workflow.read_text(encoding="utf-8")
    _require(
        security,
        (
            "  FLUTTER_VERSION: 3.44.8\n",
            "flutter-version: ${{ env.FLUTTER_VERSION }}",
            "PAKPERK_JDK_RUNTIME_VERSION: 17.0.19+10",
            "release-security-evidence-${{ github.sha }}",
            "if-no-files-found: error",
        ),
        "security workflow toolchain/evidence contract",
    )
    if "actions/setup-java" in security or "if-no-files-found: warn" in security:
        raise RuntimeError("security workflow contains a floating or fail-open path")
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != EXPECTED_WORKFLOW_SHA256:
        raise RuntimeError(
            "signed-mobile workflow bytes changed without validator review"
        )


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError) as error:
        print(f"signed mobile workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Signed mobile release workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
