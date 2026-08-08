#!/usr/bin/env python3
"""Validate the platform-isolated protected mobile-store rollout workflow."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/mobile-store-rollout.yml"
DEFAULT_CI = ROOT / ".github/workflows/ci.yml"
DEFAULT_CHECK = ROOT / "scripts/check.sh"

CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
DOWNLOAD_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
EXPECTED_WORKFLOW_SHA256 = "f35f29bd2e0aa25c85d7dfd302c32ed07a5f50d3dfe49ee91ea25215f3c68c03"
EXPECTED_HELPERS = {
    "capture_mobile_credentialed_runtime.py": "2d51f03bd21f2afa2af0396e801e0e950172210814a229ca50df67c5a8d135cd",
    "extract_mobile_store_client.py": "f1f2b989dd433223114c85451147404ad4e65992d1f5a86ed3f3c6937ea1fd3a",
    "generate_mobile_store_rollout_receipt.py": "38133d7c8a9fc5c4ade2935e6340754d8a94c60bf15fbad463a88d96190c0f5c",
    "manage_app_store_phased_release.rb": "ee7e55a902bfe4f1f9fe2f933871e44d51c1f8906eff93aad8c8aa6c3f05b68c",
    "manage_google_play_rollout.rb": "2fb30a5ed3341e22254d2e6548d22b9b10e235176317b7b403d48d49d445c3ac",
    "materialize_mobile_release_secret.py": "1f82f4ae7a6771c19f963f42436d1cc1bc196b4d55fa88261b368b6356c204d4",
    "prepare_mobile_credentialed_upload.py": "b6c4597b55db335fc46af14e0ba9c6969e99ca8ec29d43c817d699045fe12498",
    "prepare_mobile_store_client.sh": "2346df0d861df39b5b0b6f580b6afb49648e9d7f6468c22dd47948f84a0ec076",
    "validate_mobile_signed_release_run.py": "e0581035290e5b8fbf8236863a8f4c2c6914569f1e23a9571cc482b6f070cf93",
    "validate_mobile_store_candidate.py": "c70e38987495be0ad6cde2c180e01fa1e938117d8686512048c9d285691dd107",
    "validate_mobile_store_client.py": "6172367be00718dce1beff7523bfa0988502b0860e6752912864817a92d2e4bf",
}
TRANSFER_HELPERS = {
    name: digest
    for name, digest in EXPECTED_HELPERS.items()
    if name != "prepare_mobile_store_client.sh"
}
GOOGLE_SECRET = "PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64"
APPLE_SECRETS = (
    "PAKPERK_APP_STORE_CONNECT_ISSUER_ID",
    "PAKPERK_APP_STORE_CONNECT_KEY_ID",
    "PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64",
)
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
    return source[start:] if match is None else source[start : start + len(marker) + match.start()]


def _step_block(job: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if job.count(marker) != 1:
        raise RuntimeError(f"job must contain exactly one {name!r} step")
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


def _validate_always_step(
    job: str,
    name: str,
    *,
    label: str,
    continue_on_error: bool,
) -> str:
    block = _step_block(job, name)
    if "        if: always()\n" not in block:
        raise RuntimeError(f"{label} must run under always()")
    continuation = "        continue-on-error: true\n"
    if continue_on_error and continuation not in block:
        raise RuntimeError(f"{label} must preserve later retention steps on failure")
    if not continue_on_error and continuation in block:
        raise RuntimeError(f"{label} must fail the job")
    return block


def _literal_transfer_pairs(package: str) -> dict[str, str]:
    pairs: dict[str, str] = {}
    pattern = re.compile(
        r'^"([0-9a-f]{64}) ([A-Za-z0-9_.-]+)"(?: \\|; do)$'
    )
    for line in package.splitlines():
        match = pattern.fullmatch(line.strip())
        if match is None:
            continue
        digest, name = match.groups()
        if name in pairs:
            raise RuntimeError("rollout transfer helper closure contains duplicates")
        pairs[name] = digest
    return pairs


def _literal_control_dictionary(step: str) -> dict[str, str]:
    matches = re.findall(
        r'(?m)^              "([A-Za-z0-9_.-]+)": "([0-9a-f]{64})",$',
        step,
    )
    controls: dict[str, str] = {}
    for name, digest in matches:
        if name in controls:
            raise RuntimeError("credential job control closure contains duplicates")
        controls[name] = digest
    return controls


def _validate_ci_and_check(ci: str, check: str) -> None:
    ci_commands = (
        "          python3 scripts/test_prepare_mobile_credentialed_upload.py\n",
        "          python3 scripts/test_generate_mobile_store_rollout_receipt.py\n",
        "          python3 scripts/test_validate_mobile_store_rollout_workflow.py\n",
        "          python3 scripts/validate_mobile_store_rollout_workflow.py\n",
    )
    check_commands = (
        'python3 "$project_dir/scripts/test_prepare_mobile_credentialed_upload.py"\n',
        'python3 "$project_dir/scripts/test_generate_mobile_store_rollout_receipt.py"\n',
        'python3 "$project_dir/scripts/test_validate_mobile_store_rollout_workflow.py"\n',
        'python3 "$project_dir/scripts/validate_mobile_store_rollout_workflow.py"\n',
    )
    for source, commands, label in (
        (ci, ci_commands, "CI rollout validation"),
        (check, check_commands, "local rollout validation"),
    ):
        positions = []
        for command in commands:
            if source.count(command) != 1:
                raise RuntimeError(f"{label} must run exactly one {command.strip()!r}")
            positions.append(source.index(command))
        if positions != sorted(positions):
            raise RuntimeError(f"{label} ordering changed")
        covered = source[max(0, positions[0] - 256) : positions[-1] + len(commands[-1]) + 256]
        if re.search(r"(?m)^\s*(?:if\s+false|for\s+\S+\s+in\s*;|exit\s+0)\b", covered):
            raise RuntimeError(f"{label} is guarded or exits early")
    if "set -euo pipefail" not in check:
        raise RuntimeError("local rollout validation is not fail-fast")


def _validate_helper_closure(
    source: str,
    *,
    bootstrap: str,
    android: str,
    ios: str,
) -> None:
    for name, expected in EXPECTED_HELPERS.items():
        path = ROOT / "scripts" / name
        observed = hashlib.sha256(path.read_bytes()).hexdigest()
        if observed != expected:
            raise RuntimeError(f"reviewed rollout helper changed: {name}")
        if name not in source or expected not in source:
            raise RuntimeError(f"workflow does not bind reviewed helper bytes: {name}")

    package = _step_block(
        bootstrap, "Package literal-hashed rollout controls and client"
    )
    if _literal_transfer_pairs(package) != TRANSFER_HELPERS:
        raise RuntimeError("rollout transfer helper closure is not exact and literal")
    for job, step_name, label in (
        (
            android,
            "Re-attest Android artifacts controls and local client before credentials",
            "Android",
        ),
        (
            ios,
            "Re-attest iOS artifacts controls and local client before credentials",
            "iOS",
        ),
    ):
        if _literal_control_dictionary(_step_block(job, step_name)) != TRANSFER_HELPERS:
            raise RuntimeError(
                f"{label} downloaded rollout control closure is not exact and literal"
            )


def _validate_platform_job(job: str, platform: str) -> None:
    if CHECKOUT_ACTION in job or "uses: ./" in job or "candidate-source" in job:
        raise RuntimeError(f"{platform} credential job executes candidate or checkout code")
    uses = re.findall(r"(?m)^\s+uses: (\S+)", job)
    if any(value not in {DOWNLOAD_ACTION, UPLOAD_ACTION} for value in uses):
        raise RuntimeError(f"{platform} credential job has an unreviewed action")
    if "    environment: production-store\n" not in job:
        raise RuntimeError(f"{platform} credential job is not protected")
    if "    runs-on: macos-26\n" not in job:
        raise RuntimeError(f"{platform} credential job runner changed")
    expected_condition = (
        "    needs: store-client-bootstrap\n"
        "    if: >-\n"
        "      always() &&\n"
        "      (inputs.platforms == 'android' || inputs.platforms == 'both')\n"
        if platform == "android"
        else "    needs: [store-client-bootstrap, android-rollout]\n"
        "    if: >-\n"
        "      always() &&\n"
        "      (inputs.platforms == 'ios' ||\n"
        "       (inputs.platforms == 'both' && needs.android-rollout.result == 'success'))\n"
    )
    if expected_condition not in job:
        raise RuntimeError(f"{platform} credential job selection gate changed")
    if "$GITHUB_ENV" in job or "GITHUB_ENV:" in job:
        raise RuntimeError(f"{platform} credential job mutates shared step environment")
    for output in (
        "      evidence_artifact_id: ${{ steps.evidence_upload.outputs.artifact-id }}\n",
        "      evidence_artifact_digest: ${{ steps.evidence_upload.outputs.artifact-digest }}\n",
    ):
        if job.count(output) != 1:
            raise RuntimeError(f"{platform} outcome identity output changed")
    if re.search(
        r"(?:^|[;&|])\s*(?:source|\.)\s+[^\n]*release-candidate|"
        r"^\s*(?:chmod|xattr)\b[^\n]*release-candidate|"
        r"runpy\.run_path\([^\n]*release-candidate|"
        r"sys\.path\.(?:insert|append)\([^\n]*release-candidate|"
        r"^\s*(?:(?:/usr/bin/)?env\s+[^\n]*\s+)?"
        r"(?:(?:/usr)?/bin/)?(?:bash|sh|python3?|ruby|dart|flutter|java|gradle|xcodebuild)"
        r"(?:\s+-[A-Za-z0-9_-]+)*\s+[\"']?[^\s\"']*release-candidate",
        job,
        flags=re.IGNORECASE | re.MULTILINE,
    ):
        raise RuntimeError(f"{platform} credential job executes downloaded candidate code")
    for fragment in (
        "          BASH_ENV: /dev/null",
        '          DYLD_INSERT_LIBRARIES: ""',
        '          DYLD_LIBRARY_PATH: ""',
        "          ENV: /dev/null",
        '          LD_LIBRARY_PATH: ""',
        '          LD_PRELOAD: ""',
    ):
        if fragment not in job:
            raise RuntimeError(f"{platform} credential boundary misses hook clearing")
    preparation_name = (
        "Re-attest Android artifacts controls and local client before credentials"
        if platform == "android"
        else "Re-attest iOS artifacts controls and local client before credentials"
    )
    preparation = _step_block(job, preparation_name)
    prepare_entrypoint = (
        'target = os.path.join(controls, "prepare_mobile_credentialed_upload.py")'
    )
    candidate_validator = (
        'target = os.path.join(controls, "validate_mobile_store_candidate.py")'
    )
    if (
        preparation.count(prepare_entrypoint) != 1
        or preparation.count(candidate_validator) != 1
        or preparation.index(prepare_entrypoint)
        >= preparation.index(candidate_validator)
    ):
        raise RuntimeError(
            f"{platform} preparation must finish exact candidate validation"
        )
    _require(
        preparation,
        (
            "root = pathlib.Path(os.path.realpath(sys.argv[1]))",
            "{item.name for item in root.iterdir()} != set(expected)",
            'os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))',
            "hashlib.sha256(data).hexdigest() != digest",
            "sys.path.insert(0, controls)",
            "runpy.run_path(target, run_name=\"__main__\")",
        ),
        f"{platform} literal-hashed downloaded control closure",
    )
    _require(
        job,
        (
            "outputs:\n      evidence_artifact_id: ${{ steps.evidence_upload.outputs.artifact-id }}\n",
            "      evidence_artifact_digest: ${{ steps.evidence_upload.outputs.artifact-digest }}\n",
            f"uses: {DOWNLOAD_ACTION} # v8.0.1",
            "          digest-mismatch: error",
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.candidate_artifact_id }}",
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.handoff_artifact_id }}",
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.transfer_artifact_id }}",
            "prepare_mobile_credentialed_upload.py",
            "validate_mobile_store_candidate.py",
            "--store-handoff-id \"$STORE_HANDOFF_ID\"",
            "--root-device \"$CLIENT_DEVICE\" --root-inode \"$CLIENT_INODE\"",
            "      - name: Upload immutable " + ("Android" if platform == "android" else "iOS") + " outcome after cleanup\n",
            f"uses: {UPLOAD_ACTION} # v7.0.1",
            "          retention-days: 90",
        ),
        f"isolated {platform} artifact boundary",
    )

    title = "Android" if platform == "android" else "iOS"
    mutation_name = (
        "Apply exact Google Play transition with Android-only credential"
        if platform == "android"
        else "Apply exact App Store transition with iOS-only credentials"
    )
    mutation = _step_block(job, mutation_name)
    expected_secrets = (
        (GOOGLE_SECRET,) if platform == "android" else APPLE_SECRETS
    )
    outside_mutation = job.replace(mutation, "", 1)
    for secret in expected_secrets:
        reference = "${{ secrets." + secret + " }}"
        if mutation.count(reference) != 1 or secret in outside_mutation:
            raise RuntimeError(
                f"{title} secret is not confined to its sole mutation step"
            )

    cleanup = (
        "Remove Android credential and local client"
        if platform == "android"
        else "Remove iOS credentials and local client"
    )
    receipt = f"Generate closed {title} platform receipt after cleanup"
    record = f"Record unconditional {title} job outcome"
    upload = f"Upload immutable {title} outcome after cleanup"
    fail = f"Fail {title} job after immutable evidence retention"
    _validate_always_step(
        job, cleanup, label=f"{title} cleanup", continue_on_error=True
    )
    _validate_always_step(
        job, receipt, label=f"{title} receipt generation", continue_on_error=True
    )
    _validate_always_step(
        job, record, label=f"{title} outcome recording", continue_on_error=False
    )
    upload_block = _validate_always_step(
        job, upload, label=f"{title} outcome upload", continue_on_error=True
    )
    _validate_always_step(
        job, fail, label=f"{title} terminal enforcement", continue_on_error=False
    )
    _require(
        upload_block,
        (
            f"          name: mobile-{'android' if platform == 'android' else 'ios'}-rollout-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}\n",
            "          path: ${{ steps.evidence.outputs.root }}/retention\n",
            "          if-no-files-found: error\n",
        ),
        f"{title} unconditional immutable outcome upload",
    )


def validate(
    workflow: pathlib.Path = DEFAULT_WORKFLOW,
    ci: pathlib.Path = DEFAULT_CI,
    check: pathlib.Path = DEFAULT_CHECK,
) -> None:
    source = workflow.read_text(encoding="utf-8")
    if (
        "\t" in source
        or "\r" in source
        or re.search(r"(?m)^\s*[^#\n]*:\s*[&*][A-Za-z0-9_-]+", source)
        or re.search(r"(?m)^\s*<<\s*:", source)
    ):
        raise RuntimeError("rollout workflow contains non-canonical YAML")
    if _mapping_keys(source, 0) != ["name", "on", "permissions", "concurrency", "env", "jobs"]:
        raise RuntimeError("rollout root mapping changed")
    jobs_source = source[source.index("jobs:\n") :]
    if _mapping_keys(jobs_source, 2) != [
        "store-client-bootstrap",
        "android-rollout",
        "ios-rollout",
        "finalize",
    ]:
        raise RuntimeError("rollout isolation job surface changed")
    _require(
        source,
        (
            "on:\n  workflow_dispatch:\n",
            "permissions:\n  actions: read\n  contents: read\n",
            "concurrency:\n  group: production-mobile-store-rollout\n  cancel-in-progress: false\n",
            "options: [start, advance, halt, complete, rollback]",
            "MUTATE_PRODUCTION_MOBILE_STORES",
        ),
        "rollout dispatch contract",
    )
    if re.search(r"(?m)^\s+(?:push|pull_request|schedule):", source):
        raise RuntimeError("rollout workflow has an automatic trigger")
    if "$GITHUB_ENV" in source or "GITHUB_ENV:" in source:
        raise RuntimeError("rollout workflow must not use mutable cross-step environment")

    bootstrap = _job_block(source, "store-client-bootstrap")
    android = _job_block(source, "android-rollout")
    ios = _job_block(source, "ios-rollout")
    finalizer = _job_block(source, "finalize")
    if "    environment:" in bootstrap or "${{ secrets." in bootstrap:
        raise RuntimeError("store-client bootstrap must remain credential-free")
    bootstrap_uses = re.findall(r"(?m)^\s+uses: (\S+)", bootstrap)
    if (
        bootstrap_uses.count(CHECKOUT_ACTION) != 2
        or bootstrap_uses.count(UPLOAD_ACTION) != 1
        or any(
            value not in {CHECKOUT_ACTION, UPLOAD_ACTION}
            for value in bootstrap_uses
        )
    ):
        raise RuntimeError("store-client bootstrap action closure changed")
    _require(
        bootstrap,
        (
            f"uses: {CHECKOUT_ACTION} # v7.0.1",
            "          ref: ${{ github.workflow_sha }}",
            "          ref: ${{ inputs.source_revision }}",
            "          persist-credentials: false",
            "      transfer_artifact_id: ${{ steps.transfer_upload.outputs.artifact-id }}",
            "      transfer_artifact_digest: ${{ steps.transfer_upload.outputs.artifact-digest }}",
            "      candidate_artifact_id: ${{ steps.release_run.outputs.candidate_artifact_id }}",
            "      handoff_artifact_id: ${{ steps.release_run.outputs.store_handoff_artifact_id }}",
            "      - name: Package literal-hashed rollout controls and client\n",
            "            bundle config download gem-home home manifest",
            "          path: ${{ steps.package.outputs.transfer_root }}",
        ),
        "credential-free bootstrap",
    )
    _validate_platform_job(android, "android")
    _validate_platform_job(ios, "ios")
    if GOOGLE_SECRET not in android or any(secret in android for secret in APPLE_SECRETS):
        raise RuntimeError("Android job secret family is not isolated")
    if GOOGLE_SECRET in ios or any(secret not in ios for secret in APPLE_SECRETS):
        raise RuntimeError("iOS job secret family is not isolated")
    if source.count(GOOGLE_SECRET) != 1 or any(source.count(secret) != 1 for secret in APPLE_SECRETS):
        raise RuntimeError("store secret references escaped their sole platform step")

    _ordered(
        android,
        (
            "Re-attest Android artifacts controls and local client before credentials",
            "Apply exact Google Play transition with Android-only credential",
            "Remove Android credential and local client",
            "Generate closed Android platform receipt after cleanup",
            "Upload immutable Android outcome after cleanup",
            "Fail Android job after immutable evidence retention",
        ),
        "Android rollout",
    )
    _ordered(
        ios,
        (
            "Download exact Android proof before combined iOS mutation",
            "Re-attest iOS artifacts controls and local client before credentials",
            "Validate immutable Android proof before combined iOS credentials",
            "Apply exact App Store transition with iOS-only credentials",
            "Remove iOS credentials and local client",
            "Generate closed iOS platform receipt after cleanup",
            "Upload immutable iOS outcome after cleanup",
            "Fail iOS job after immutable evidence retention",
        ),
        "iOS rollout",
    )
    _require(
        ios,
        (
            "    needs: [store-client-bootstrap, android-rollout]\n",
            "(inputs.platforms == 'both' && needs.android-rollout.result == 'success')",
            "artifact-ids: ${{ needs.android-rollout.outputs.evidence_artifact_id }}",
            "/usr/bin/python3 -I \"$CONTROL_ROOT/generate_mobile_store_rollout_receipt.py\" verify-platform",
            "steps.android_proof.outcome == 'success'",
            "--platform android",
        ),
        "sequential Android-to-iOS proof gate",
    )
    ios_secret_position = min(ios.index(secret) for secret in APPLE_SECRETS)
    if ios.index("Validate immutable Android proof before combined iOS credentials") > ios_secret_position:
        raise RuntimeError("iOS credentials appear before the Android proof gate")

    if "    environment:" in finalizer or "${{ secrets." in finalizer:
        raise RuntimeError("rollout finalizer must remain credential-free")
    finalizer_uses = re.findall(r"(?m)^\s+uses: (\S+)", finalizer)
    if any(
        value not in {CHECKOUT_ACTION, DOWNLOAD_ACTION, UPLOAD_ACTION}
        for value in finalizer_uses
    ):
        raise RuntimeError("rollout finalizer has an unreviewed action")
    _require(
        finalizer,
        (
            "    needs: [store-client-bootstrap, android-rollout, ios-rollout]\n",
            "    if: always()\n",
            "artifact-ids: ${{ needs.android-rollout.outputs.evidence_artifact_id }}",
            "artifact-ids: ${{ needs.ios-rollout.outputs.evidence_artifact_id }}",
            '/usr/bin/python3 -I "$helper" aggregate',
            "--android-artifact-digest \"${{ needs.android-rollout.outputs.evidence_artifact_digest }}\"",
            "--ios-artifact-digest \"${{ needs.ios-rollout.outputs.evidence_artifact_digest }}\"",
            "      - name: Fail requested skipped cancelled failed or missing outcomes\n",
            "A requested platform was skipped, cancelled, failed, or lacked exact immutable evidence.",
        ),
        "credential-free finalizer",
    )
    for download_name in (
        "Download Android outcome strictly by immutable artifact ID",
        "Download iOS outcome strictly by immutable artifact ID",
    ):
        download = _step_block(finalizer, download_name)
        _require(
            download,
            (
                "        if: >-\n          always() &&\n",
                "        continue-on-error: true\n",
                f"uses: {DOWNLOAD_ACTION} # v8.0.1",
                "          digest-mismatch: error\n",
            ),
            f"always-run finalizer {download_name}",
        )
    _validate_always_step(
        finalizer,
        "Aggregate exact platform evidence without credentials",
        label="credential-free aggregate receipt",
        continue_on_error=True,
    )
    _validate_always_step(
        finalizer,
        "Upload canonical credential-free rollout receipt",
        label="credential-free aggregate upload",
        continue_on_error=True,
    )
    terminal = _validate_always_step(
        finalizer,
        "Fail requested skipped cancelled failed or missing outcomes",
        label="credential-free terminal enforcement",
        continue_on_error=False,
    )
    _require(
        terminal,
        (
            '[[ "$ANDROID_RESULT" == success ]] || failed=1',
            '[[ "$ANDROID_RESULT" == skipped ]] || failed=1',
            '[[ "$IOS_RESULT" == success ]] || failed=1',
            '[[ "$IOS_RESULT" == skipped ]] || failed=1',
            "(( failed == 0 )) || {",
        ),
        "exact requested and unselected platform result semantics",
    )

    for label, block in (
        ("Android store mutation", _step_block(android, "Apply exact Google Play transition with Android-only credential")),
        ("iOS store mutation", _step_block(ios, "Apply exact App Store transition with iOS-only credentials")),
    ):
        _require(
            block,
            (
                SANITIZED_SHELL.rstrip("\n"),
                "          BASH_ENV: /dev/null",
                '          DYLD_INSERT_LIBRARIES: ""',
                '          DYLD_LIBRARY_PATH: ""',
                "          ENV: /dev/null",
                '          LD_LIBRARY_PATH: ""',
                '          LD_PRELOAD: ""',
                '          ALL_PROXY: ""',
                '          HTTPS_PROXY: ""',
                '          HTTP_PROXY: ""',
                '          NO_PROXY: "*"',
                '          all_proxy: ""',
                '          https_proxy: ""',
                '          http_proxy: ""',
                '          no_proxy: "*"',
                '          CURL_CA_BUNDLE: ""',
                '          SSL_CERT_DIR: ""',
                '          SSL_CERT_FILE: ""',
            ),
            label,
        )

    _validate_helper_closure(
        source, bootstrap=bootstrap, android=android, ios=ios
    )
    _validate_ci_and_check(ci.read_text(encoding="utf-8"), check.read_text(encoding="utf-8"))
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != EXPECTED_WORKFLOW_SHA256:
        raise RuntimeError("rollout workflow bytes changed without validator review")


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError) as error:
        print(f"mobile store rollout workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Platform-isolated mobile store rollout workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
