#!/usr/bin/env python3
"""Validate the fail-closed release-image publication contract."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-images.yml"


def require(source: str, fragment: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"release image workflow is missing: {fragment}")


def validate(path: pathlib.Path = WORKFLOW) -> None:
    source = path.read_text(encoding="utf-8")
    trigger_end = source.index("\npermissions:")
    trigger = source[:trigger_end]
    if "workflow_dispatch:" not in trigger or re.search(
        r"(?m)^  (?:pull_request|push|schedule|workflow_run):", trigger
    ):
        raise RuntimeError("release images must be manual-dispatch only")

    permissions_end = source.index("\nconcurrency:", trigger_end)
    permissions = source[trigger_end + 1 : permissions_end].strip()
    if permissions != "permissions:\n  contents: read\n  packages: write":
        raise RuntimeError("release image workflow permissions are not least privilege")

    for fragment in (
            "      source_revision:\n"
            "        description: Reviewed full commit SHA reachable from main\n"
            "        required: true\n"
            "        type: string",
            "environment: ${{ inputs.environment }}",
            "if: github.ref == 'refs/heads/main'",
            "runs-on: ubuntu-24.04",
            "FLUTTER_VERSION: 3.44.8",
            "flutter-version: ${{ env.FLUTTER_VERSION }}",
            "ref: ${{ inputs.source_revision }}",
            "fetch-depth: 0",
            "persist-credentials: false",
            '          if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]',
            '          if [[ "$source_revision" != "$REQUESTED_REVISION" ]]',
            '          if ! git merge-base --is-ancestor "$source_revision" origin/main',
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
            'if len(matches) != 1:',
            'BACKEND_DIGEST: ${{ steps.publish.outputs.backend_digest }}',
            'SITE_DIGEST: ${{ steps.publish.outputs.site_digest }}',
            '[[ "$BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]',
            '[[ "$SITE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]',
            "printf 'backend_tag=%s:sha-%s",
            "printf 'site_tag=%s:sha-%s",
            "promotion-handoff.json",
            '"image": {"repository": backend_repository, "digest": backend_digest}',
            '"siteImage": {"repository": site_repository, "digest": site_digest}',
            "release/image-publication/flutter-toolchain.json",
            "if-no-files-found: error",
    ):
        require(source, fragment)
    for forbidden in (
        ":latest",
        "${{ github.sha }}",
        "docker push $BACKEND_REPOSITORY\n",
        "docker push $SITE_REPOSITORY\n",
        "docker image inspect",
        ".RepoDigests",
    ):
        if forbidden in source:
            raise RuntimeError(f"release image workflow contains a trust/publication bypass: {forbidden}")
    if source.count('docker push "$BACKEND_TAG"') != 1 or source.count(
        'docker push "$SITE_TAG"'
    ) != 1:
        raise RuntimeError("release workflow must push only the two reviewed commit tags")
    publish_position = source.index("Publish immutable images after successful scans")
    for predecessor in (
        "Scan exact backend image",
        "Scan exact site image",
        "Generate exact backend image SBOM",
        "Generate exact site image SBOM",
    ):
        if source.index(predecessor) >= publish_position:
            raise RuntimeError("release images must be scanned and inventoried before publication")
    handoff_position = source.index(
        "Resolve published digests and create Helm promotion handoff"
    )
    if publish_position >= handoff_position:
        raise RuntimeError("registry-confirmed push digests must precede the Helm handoff")
    if not source.index("Resolve reviewed source and immutable image names") < source.index(
        "Verify and record the exact reviewed Flutter SDK"
    ) < source.index("Resolve locked Flutter dependencies"):
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
