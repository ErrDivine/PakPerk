#!/usr/bin/env python3
"""Validate the fail-closed release-image publication contract."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-images.yml"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
EXPECTED_TRIGGER_SHA256 = (
    "64d2db754827f103ec4f2875b2f663120f4125e4983072244c9661d941ed764a"
)
EXPECTED_STEP_ITEMS_SHA256 = (
    "7575bd9077f94d1efc5d8e61c71ff1154a45701bc78b7f862edc7792d6a753d1"
)
EXPECTED_CHECKOUT_STEP_SHA256 = (
    "6bc05ec1a7fbb3a14b447485291230172fdfe398392d701d6fc4ec2a09b4ca50"
)
EXPECTED_ROOT_ENV_SHA256 = (
    "35a1e0226cf58a54296e9bbffb76785830b80450d916aaf2c1fb8e20b1cfd54c"
)
EXPECTED_SOURCE_STEP_SHA256 = (
    "cad0a99127c50b45b6224de4dd4bb5b08740d7b9527e18328ce9a1e4ee39d91d"
)


def require(source: str, fragment: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"release image workflow is missing: {fragment}")


def _step_block(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"release image workflow must contain exactly one {label}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


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


def validate(path: pathlib.Path = WORKFLOW) -> None:
    source = path.read_text(encoding="utf-8")
    if _mapping_keys(source, 0) != [
        "name",
        "on",
        "permissions",
        "concurrency",
        "env",
        "jobs",
    ]:
        raise RuntimeError("release image workflow root mapping changed")
    if re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("release image workflow must not use YAML merge keys")
    trigger_start = source.index("\non:\n") + 1
    trigger_end = source.index("\npermissions:", trigger_start)
    trigger = source[trigger_start:trigger_end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("release images must be manual-dispatch only")
    if hashlib.sha256(trigger.encode("utf-8")).hexdigest() != EXPECTED_TRIGGER_SHA256:
        raise RuntimeError(
            "release image dispatch schema or environment choices changed"
        )

    permissions_end = source.index("\nconcurrency:", trigger_end)
    permissions = source[trigger_end + 1 : permissions_end].strip()
    if permissions != "permissions:\n  contents: read\n  packages: write":
        raise RuntimeError("release image workflow permissions are not least privilege")
    concurrency_end = source.index("\nenv:\n", permissions_end)
    if source[permissions_end + 1 : concurrency_end].strip() != (
        "concurrency:\n"
        "  group: release-images-${{ inputs.environment }}\n"
        "  cancel-in-progress: false"
    ):
        raise RuntimeError(
            "release image concurrency must be scoped and non-cancelling"
        )
    env_start = concurrency_end + 1
    env_end = source.index("\njobs:\n", env_start)
    root_env = source[env_start:env_end]
    if hashlib.sha256(root_env.encode("utf-8")).hexdigest() != EXPECTED_ROOT_ENV_SHA256:
        raise RuntimeError("release image inherited environment changed")

    if source.count("\njobs:\n") != 1:
        raise RuntimeError("release image workflow job boundary is malformed")
    jobs = source[source.index("\njobs:\n") + len("\njobs:\n") :]
    if _mapping_keys(jobs, 2) != ["publish"]:
        raise RuntimeError(
            "release image workflow must contain exactly one bounded job"
        )
    job_start = source.index("  publish:\n", env_end)
    steps_start = source.index("    steps:\n", job_start)
    expected_job_prefix = (
        "  publish:\n"
        "    runs-on: ubuntu-24.04\n"
        "    timeout-minutes: 120\n"
        "    environment: ${{ inputs.environment }}\n"
    )
    if source[job_start:steps_start] != expected_job_prefix:
        raise RuntimeError(
            "release image job execution boundary changed; job-level conditions are fail-open"
        )
    if _mapping_keys(source[job_start:], 4) != [
        "runs-on",
        "timeout-minutes",
        "environment",
        "steps",
    ]:
        raise RuntimeError(
            "release image job contains an unexpected or reordered job-level key"
        )
    step_items = re.findall(r"(?m)^      -[^\n]*$", source[steps_start:])
    if any(
        re.fullmatch(r"      - (?:name: .+|uses: [^ #]+(?: # .+)?)", item) is None
        for item in step_items
    ):
        raise RuntimeError("release image workflow contains a non-canonical step item")
    step_item_contract = "\n".join(step_items) + "\n"
    if (
        hashlib.sha256(step_item_contract.encode("utf-8")).hexdigest()
        != EXPECTED_STEP_ITEMS_SHA256
    ):
        raise RuntimeError("release image workflow step surface changed")
    if step_items[:2] != [
        f"      - uses: {CHECKOUT_ACTION} # v7.0.1",
        "      - name: Resolve reviewed source and immutable image names",
    ]:
        raise RuntimeError(
            "release image workflow must establish source trust before executable work"
        )

    checkout = _step_block(
        source,
        f"      - uses: {CHECKOUT_ACTION}",
        "reviewed checkout step",
    )
    if (
        hashlib.sha256(checkout.encode("utf-8")).hexdigest()
        != EXPECTED_CHECKOUT_STEP_SHA256
    ):
        raise RuntimeError("release image checkout step changed")
    if re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", checkout) != ["with"]:
        raise RuntimeError("release image checkout has an unexpected step key")
    expected_checkout = (
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false\n"
    )
    if checkout[checkout.index("        with:\n") :] != expected_checkout:
        raise RuntimeError("release image exact-source checkout inputs changed")

    for fragment in (
        "      source_revision:\n"
        "        description: Reviewed full commit SHA reachable from main\n"
        "        required: true\n"
        "        type: string",
        "environment: ${{ inputs.environment }}",
        "runs-on: ubuntu-24.04",
        "FLUTTER_VERSION: 3.44.8",
        "flutter-version: ${{ env.FLUTTER_VERSION }}",
        "ref: ${{ inputs.source_revision }}",
        "fetch-depth: 0",
        "persist-credentials: false",
        "Verify and record the exact reviewed Flutter SDK",
        "flutter --version --machine >release/metadata/flutter-toolchain.json",
        "python3 scripts/validate_flutter_toolchain.py",
        "SOURCE_REVISION: ${{ steps.release.outputs.source_revision }}",
        "backend/Dockerfile --target runtime",
        "site/Dockerfile",
        "Scan exact backend image",
        "Scan exact site image",
        "Generate exact backend image SBOM",
        "Generate exact site image SBOM",
        "Publish immutable images after successful scans",
        "id: publish",
        'docker push "$BACKEND_TAG" 2>&1 | tee "$backend_push_log"',
        'docker push "$SITE_TAG" 2>&1 | tee "$site_push_log"',
        'r"(?m)^[^:\\s]+: digest: (sha256:[0-9a-f]{64}) size: [1-9][0-9]*\\s*$"',
        "if len(matches) != 1:",
        "BACKEND_DIGEST: ${{ steps.publish.outputs.backend_digest }}",
        "SITE_DIGEST: ${{ steps.publish.outputs.site_digest }}",
        '[[ "$BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]',
        '[[ "$SITE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]',
        "printf 'backend_tag=%s:sha-%s",
        "printf 'site_tag=%s:sha-%s",
        "promotion-handoff.json",
        '"image": {"repository": backend_repository, "digest": backend_digest}',
        '"siteImage": {"repository": site_repository, "digest": site_digest}',
        "release/image-publication/flutter-toolchain.json",
        "(cd release/image-publication && sha256sum -- * >SHA256SUMS)",
        "name: release-images-${{ inputs.environment }}-${{ steps.release.outputs.source_revision }}",
        "if-no-files-found: error",
        "retention-days: 90",
    ):
        require(source, fragment)

    source_step = _step_block(
        source,
        "      - name: Resolve reviewed source and immutable image names\n",
        "source trust step",
    )
    if (
        hashlib.sha256(source_step.encode("utf-8")).hexdigest()
        != EXPECTED_SOURCE_STEP_SHA256
    ):
        raise RuntimeError("release image source trust step changed")
    for fragment in (
        "          DISPATCH_REF: ${{ github.ref }}",
        "          RELEASE_ENVIRONMENT: ${{ inputs.environment }}",
        "          REQUESTED_REVISION: ${{ inputs.source_revision }}",
        '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
        '          if [[ "$RELEASE_ENVIRONMENT" != "staging" && "$RELEASE_ENVIRONMENT" != "production" ]]; then',
        '          if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
        '          if [[ "$source_revision" != "$REQUESTED_REVISION" ]]; then',
        '          if ! git merge-base --is-ancestor "$source_revision" origin/main; then',
    ):
        require(source_step, fragment)
    if "continue-on-error:" in source_step:
        raise RuntimeError("release image source trust step must not be recoverable")
    for forbidden in (
        ":latest",
        "${{ github.sha }}",
        "docker push $BACKEND_REPOSITORY\n",
        "docker push $SITE_REPOSITORY\n",
        "docker image inspect",
        ".RepoDigests",
        "if-no-files-found: warn",
    ):
        if forbidden in source:
            raise RuntimeError(
                f"release image workflow contains a trust/publication bypass: {forbidden}"
            )
    if (
        source.count('docker push "$BACKEND_TAG"') != 1
        or source.count('docker push "$SITE_TAG"') != 1
    ):
        raise RuntimeError(
            "release workflow must push only the two reviewed commit tags"
        )
    publish_position = source.index("Publish immutable images after successful scans")
    for predecessor in (
        "Scan exact backend image",
        "Scan exact site image",
        "Generate exact backend image SBOM",
        "Generate exact site image SBOM",
    ):
        if source.index(predecessor) >= publish_position:
            raise RuntimeError(
                "release images must be scanned and inventoried before publication"
            )
    handoff_position = source.index(
        "Resolve published digests and create Helm promotion handoff"
    )
    if publish_position >= handoff_position:
        raise RuntimeError(
            "registry-confirmed push digests must precede the Helm handoff"
        )
    if (
        not source.index("Resolve reviewed source and immutable image names")
        < source.index("Verify and record the exact reviewed Flutter SDK")
        < source.index("Resolve locked Flutter dependencies")
    ):
        raise RuntimeError(
            "release image workflow must verify Flutter after source trust and before dependencies"
        )


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"release image workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Release image publication workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
