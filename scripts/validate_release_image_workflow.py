#!/usr/bin/env python3
"""Validate the three-runner, fail-closed release-image publication contract."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-images.yml"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
FLUTTER_ACTION = "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2"
TRIVY_ACTION = "aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
DOWNLOAD_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"

EXPECTED_TRIGGER_SHA256 = (
    "64d2db754827f103ec4f2875b2f663120f4125e4983072244c9661d941ed764a"
)
EXPECTED_JOB_SHA256 = {
    "build": "67aa84fcef24e7f6722cb72a8f65a212b41d9da08f0bcfeb5921e9eff4ee3896",
    "scan": "d4aa72e34bb0e9806d84add11aaad332c4cf537b2df0007d855b2952c8b8793f",
    "publish": "36522b3a9a2c62b29293879f4ba23ca306d9a61dfa3e43aba3d47987567795d5",
}

BUILD_STEPS = (
    f"uses: {CHECKOUT_ACTION} # v7.0.1",
    "name: Resolve reviewed source and immutable image names",
    "name: Install pinned Rust toolchain",
    f"uses: {FLUTTER_ACTION} # v2.23.0",
    "name: Verify and record the exact reviewed Flutter SDK",
    "name: Resolve locked Flutter dependencies",
    "name: Generate exact-revision dependency evidence and curated site",
    "name: Build commit-addressed release images",
    "name: Upload immutable untrusted build handoff",
)
SCAN_STEPS = (
    "name: Download exact immutable untrusted build handoff",
    "name: Validate untrusted build handoff on fresh scan runner",
    "name: Prepare fresh scan output directory",
    "name: Scan exact backend image",
    "name: Scan exact site image",
    "name: Generate exact backend image SBOM",
    "name: Generate exact site image SBOM",
    "name: Create closed scanned-image publication handoff",
    "name: Upload immutable scanned-image handoff",
)
PUBLISH_STEPS = (
    "name: Download exact immutable scanned-image handoff",
    "name: Validate closed scanned-image handoff before loading",
    "name: Load exact scanned images without executing candidate code",
    "name: Publish only the loaded scanned images",
    "name: Create digest-only Helm promotion handoff and publication evidence",
    "name: Upload immutable image publication evidence",
)


def require(source: str, fragment: str, label: str = "release image workflow") -> None:
    if fragment not in source:
        raise RuntimeError(f"{label} is missing: {fragment}")


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


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


def _job_block(source: str, job_id: str) -> str:
    marker = f"  {job_id}:\n"
    if source.count(marker) != 1:
        raise RuntimeError(f"workflow must contain exactly one {job_id} job")
    start = source.index(marker)
    following = source[start + len(marker) :]
    next_job = re.search(r"(?m)^  [a-z][a-z0-9_]*:\n", following)
    if next_job is None:
        return source[start:]
    return source[start : start + len(marker) + next_job.start()]


def _step_block(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"release image workflow must contain exactly one {label}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def _named_step(source: str, name: str) -> str:
    return _step_block(source, f"      - name: {name}\n", f"step named {name!r}")


def _step_items(job: str) -> tuple[str, ...]:
    items = re.findall(r"(?m)^      - (.+)$", job)
    if any(
        re.fullmatch(r"(?:name: .+|uses: [^ #]+(?: # .+)?)", item) is None
        for item in items
    ):
        raise RuntimeError("release image workflow contains a non-canonical step item")
    return tuple(items)


def _validate_trigger_and_root(source: str) -> None:
    if "\r" in source or "\t" in source:
        raise RuntimeError("release image workflow must use canonical LF/spaces")
    if _mapping_keys(source, 0) != ["name", "on", "permissions", "concurrency", "jobs"]:
        raise RuntimeError("release image workflow root mapping changed")
    if re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("release image workflow must not use YAML merge keys")
    trigger_start = source.index("\non:\n") + 1
    trigger_end = source.index("\npermissions:", trigger_start)
    trigger = source[trigger_start:trigger_end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("release images must be manual-dispatch only")
    if _digest(trigger) != EXPECTED_TRIGGER_SHA256:
        raise RuntimeError("release image dispatch schema or choices changed")
    permissions_end = source.index("\nconcurrency:", trigger_end)
    if source[trigger_end + 1 : permissions_end].strip() != "permissions: {}":
        raise RuntimeError("workflow-level token permissions must be closed")
    concurrency_end = source.index("\njobs:\n", permissions_end)
    expected = (
        "concurrency:\n"
        "  group: release-images-${{ inputs.environment }}\n"
        "  cancel-in-progress: false"
    )
    if source[permissions_end + 1 : concurrency_end].strip() != expected:
        raise RuntimeError("release image concurrency must be scoped and non-cancelling")


def _validate_job_boundaries(source: str, build: str, scan: str, publish: str) -> None:
    jobs = source[source.index("\njobs:\n") + len("\njobs:\n") :]
    if _mapping_keys(jobs, 2) != ["build", "scan", "publish"]:
        raise RuntimeError("release image workflow must contain three exact jobs")
    build_prefix = (
        "  build:\n"
        "    runs-on: ubuntu-24.04\n"
        "    timeout-minutes: 120\n"
        "    permissions:\n"
        "      contents: read\n"
        "    env:\n"
        "      RUST_TOOLCHAIN: 1.91.1\n"
        "      FLUTTER_VERSION: 3.44.8\n"
        "    outputs:\n"
        "      source_revision: ${{ steps.release.outputs.source_revision }}\n"
        "      build_artifact_id: ${{ steps.build-upload.outputs.artifact-id }}\n"
        "      build_artifact_digest: ${{ steps.build-upload.outputs.artifact-digest }}\n"
    )
    scan_prefix = (
        "  scan:\n"
        "    needs: build\n"
        "    runs-on: ubuntu-24.04\n"
        "    timeout-minutes: 60\n"
        "    permissions: {}\n"
        "    env:\n"
        "      PATH: /usr/bin:/bin\n"
        "      BASH_ENV: /dev/null\n"
        "      ENV: /dev/null\n"
        "    outputs:\n"
        "      source_revision: ${{ needs.build.outputs.source_revision }}\n"
        "      build_artifact_id: ${{ needs.build.outputs.build_artifact_id }}\n"
        "      build_artifact_digest: ${{ needs.build.outputs.build_artifact_digest }}\n"
        "      build_manifest_sha256: ${{ steps.validate-build.outputs.build_manifest_sha256 }}\n"
        "      handoff_artifact_id: ${{ steps.handoff-upload.outputs.artifact-id }}\n"
        "      handoff_artifact_digest: ${{ steps.handoff-upload.outputs.artifact-digest }}\n"
    )
    publish_prefix = (
        "  publish:\n"
        "    needs: scan\n"
        "    runs-on: ubuntu-24.04\n"
        "    timeout-minutes: 45\n"
        "    environment: ${{ inputs.environment }}\n"
        "    permissions:\n"
        "      packages: write\n"
        "    env:\n"
        "      PATH: /usr/bin:/bin\n"
        "      BASH_ENV: /dev/null\n"
        "      ENV: /dev/null\n"
    )
    if not build.startswith(build_prefix):
        raise RuntimeError("candidate build job contract changed")
    if not scan.startswith(scan_prefix):
        raise RuntimeError("fresh uncredentialed scan job contract changed")
    if not publish.startswith(publish_prefix):
        raise RuntimeError("fresh protected publish job contract changed")
    if source.count("packages: write") != 1 or "packages: write" not in publish:
        raise RuntimeError("packages write permission must exist only in publish")
    if source.count("contents: read") != 1 or "contents: read" not in build:
        raise RuntimeError("source read permission must exist only in build")
    if "environment:" in build or "environment:" in scan or publish.count("environment:") != 1:
        raise RuntimeError("only publish may use the protected environment")
    for name, block in (("build", build), ("scan", scan), ("publish", publish)):
        if _digest(block) != EXPECTED_JOB_SHA256[name]:
            raise RuntimeError(f"{name} complete job block changed")


def _validate_step_surface(build: str, scan: str, publish: str) -> None:
    if _step_items(build) != BUILD_STEPS:
        raise RuntimeError("candidate build step surface changed")
    if _step_items(scan) != SCAN_STEPS:
        raise RuntimeError("fresh scan step surface changed")
    if _step_items(publish) != PUBLISH_STEPS:
        raise RuntimeError("protected publish step surface changed")
    actions = re.findall(r"(?m)^\s+(?:- )?uses: ([^ #]+)", build + scan + publish)
    expected = [
        CHECKOUT_ACTION,
        FLUTTER_ACTION,
        UPLOAD_ACTION,
        DOWNLOAD_ACTION,
        TRIVY_ACTION,
        TRIVY_ACTION,
        TRIVY_ACTION,
        TRIVY_ACTION,
        UPLOAD_ACTION,
        DOWNLOAD_ACTION,
        UPLOAD_ACTION,
    ]
    if actions != expected:
        raise RuntimeError("release image workflow action surface changed")
    checkout = _step_block(build, f"      - uses: {CHECKOUT_ACTION}", "checkout")
    expected_checkout = (
        f"      - uses: {CHECKOUT_ACTION} # v7.0.1\n"
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false\n"
    )
    if checkout != expected_checkout:
        raise RuntimeError("release image exact-source checkout inputs changed")


def _validate_build_contract(build: str) -> None:
    source_step = _named_step(build, "Resolve reviewed source and immutable image names")
    for fragment in (
        "DISPATCH_REF: ${{ github.ref }}",
        "RELEASE_ENVIRONMENT: ${{ inputs.environment }}",
        "REQUESTED_REVISION: ${{ inputs.source_revision }}",
        '[[ "$DISPATCH_REF" != "refs/heads/main" ]]',
        '[[ "$RELEASE_ENVIRONMENT" != "staging" && "$RELEASE_ENVIRONMENT" != "production" ]]',
        '[[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]',
        'git merge-base --is-ancestor "$source_revision" origin/main',
        "printf 'backend_tag=%s:sha-%s",
        "printf 'site_tag=%s:sha-%s",
    ):
        require(source_step, fragment, "reviewed source gate")
    for fragment in (
        "python3 scripts/validate_flutter_toolchain.py",
        "flutter pub get --enforce-lockfile",
        "backend/Dockerfile --target runtime",
        "site/Dockerfile",
        'docker save --output "$build_dir/backend-image.tar" "$BACKEND_TAG"',
        'docker save --output "$build_dir/site-image.tar" "$SITE_TAG"',
        '"classification": "untrusted release image build handoff"',
        '"archive_sha256": backend_archive_sha256',
        '"image_id": backend_image_id',
        "release-image-build.json",
        "name: release-image-build-",
        "compression-level: 0",
        "include-hidden-files: false",
        "retention-days: 1",
    ):
        require(build, fragment, "candidate build handoff")
    for forbidden in (
        TRIVY_ACTION,
        "Scan exact",
        "Generate exact backend image SBOM",
        "packages: write",
        "secrets.",
        "docker login",
        "docker push",
    ):
        if forbidden in build:
            raise RuntimeError(f"build crosses the fresh scan/credential boundary: {forbidden}")


def _validate_scan_execution_boundary(scan: str) -> None:
    for forbidden in (
        "actions/checkout",
        "scripts/",
        "working-directory:",
        "docker build",
        "flutter ",
        "cargo ",
        "npm ",
        "nohup ",
        "disown",
        "setsid ",
        "eval ",
        "$GITHUB_WORKSPACE",
        "${{ github.workspace }}",
        "${{ github.token }}",
        "secrets.",
    ):
        if forbidden in scan:
            raise RuntimeError(f"scan job may not execute candidate code: {forbidden}")
    for match in re.finditer(r"(?m)^ {10}/usr/bin/python3(?P<tail>[^\n]*)$", scan):
        if not match.group("tail").strip().startswith("-I -"):
            raise RuntimeError("scan Python must be isolated inline workflow code")
    if re.search(r"(?m)^ {10}[^#\n]*[^&]&[ \t]*$", scan):
        raise RuntimeError("scan job may not persist a background process")
    if "GITHUB_ENV" in scan or "GITHUB_PATH" in scan:
        raise RuntimeError("scan may not mutate GitHub cross-step command files")
    if "packages: write" in scan or "contents: read" in scan or "environment:" in scan:
        raise RuntimeError("scan job must remain uncredentialed and unprotected")


def _validate_scan_contract(scan: str) -> None:
    for fragment in (
        "artifact-ids: ${{ needs.build.outputs.build_artifact_id }}",
        "EXPECTED_ARTIFACT_DIGEST: ${{ needs.build.outputs.build_artifact_digest }}",
        "digest-mismatch: error",
        "object_pairs_hook=reject_pairs",
        "parse_constant=reject_constant",
        "build manifest is not canonical JSON",
        "if {entry.name for entry in os.scandir(root)} != expected_files:",
        'subprocess.run(\n                  ["/usr/bin/docker", "load"',
        "loaded build image identity does not match",
        "os.chmod(root / name, 0o400)",
        "Prepare fresh scan output directory",
        "input: ${{ runner.temp }}/release-image-build-handoff/backend-image.tar",
        "input: ${{ runner.temp }}/release-image-build-handoff/site-image.tar",
        "output: ${{ runner.temp }}/release-image-scan/backend-trivy.sarif",
        "output: ${{ runner.temp }}/release-image-scan/site-trivy.sarif",
        'backend_archive_sha256 != expected_backend_archive_sha256',
        'site_archive_sha256 != expected_site_archive_sha256',
        "a scanned image archive changed after its scans",
        '"build_handoff": {',
        '"artifact_id": build_artifact_id',
        '"artifact_digest": build_artifact_digest',
        '"manifest_sha256": build_manifest_sha256',
        '"classification": "scanned release image publication handoff"',
        '"archive_sha256": backend_archive_sha256',
        '"image_id": backend_image_id',
        "untrusted-build-handoff.json",
        "path: ${{ runner.temp }}/release-image-handoff",
        "compression-level: 0",
        "include-hidden-files: false",
        "retention-days: 1",
    ):
        require(scan, fragment, "fresh scan handoff")
    if scan.count(TRIVY_ACTION) != 4:
        raise RuntimeError("fresh scan job must run four exact pinned Trivy operations")
    if scan.count("input: ${{ runner.temp }}/release-image-build-handoff/backend-image.tar") != 2:
        raise RuntimeError("backend vulnerability/SBOM scans must consume the downloaded archive")
    if scan.count("input: ${{ runner.temp }}/release-image-build-handoff/site-image.tar") != 2:
        raise RuntimeError("site vulnerability/SBOM scans must consume the downloaded archive")
    if "image-ref:" in scan:
        raise RuntimeError("fresh scans may not consume mutable daemon tags")
    ordered = (
        "Download exact immutable untrusted build handoff",
        "Validate untrusted build handoff on fresh scan runner",
        "Prepare fresh scan output directory",
        "Scan exact backend image",
        "Scan exact site image",
        "Generate exact backend image SBOM",
        "Generate exact site image SBOM",
        "Create closed scanned-image publication handoff",
        "Upload immutable scanned-image handoff",
    )
    if [scan.index(name) for name in ordered] != sorted(scan.index(name) for name in ordered):
        raise RuntimeError("fresh scan steps are reordered")


def _validate_publish_execution_boundary(publish: str) -> None:
    for forbidden in (
        "actions/checkout",
        "scripts/",
        "working-directory:",
        "docker build",
        "flutter ",
        "cargo ",
        "npm ",
        "nohup ",
        "disown",
        "setsid ",
        "subprocess",
        "os.system",
        "Popen",
        "eval ",
        "$GITHUB_WORKSPACE",
        "${{ github.workspace }}",
        "${{ github.token }}",
    ):
        if forbidden in publish:
            raise RuntimeError(f"publish job may not execute candidate code: {forbidden}")
    for match in re.finditer(r"(?m)^ {10}/usr/bin/python3(?P<tail>[^\n]*)$", publish):
        if not match.group("tail").strip().startswith("-I -"):
            raise RuntimeError("publish Python must be isolated inline workflow code")
    if re.search(r"(?m)^ {10}[^#\n]*[^&]&[ \t]*$", publish):
        raise RuntimeError("publish job may not persist a background process")
    if publish.count("${{ secrets.GITHUB_TOKEN }}") != 1:
        raise RuntimeError("registry credential binding count changed")
    if "GITHUB_ENV" in publish or "GITHUB_PATH" in publish:
        raise RuntimeError("publish may not mutate GitHub cross-step command files")
    push = _named_step(publish, "Publish only the loaded scanned images")
    outside_push = publish.replace(push, "", 1)
    if "secrets." in outside_push or "REGISTRY_TOKEN" in outside_push:
        raise RuntimeError("registry credential must be bound only to exact push step")
    if publish.count("/usr/bin/docker load") != 2:
        raise RuntimeError("publish must load exactly two scanned archives")
    if publish.count("/usr/bin/docker push") != 2:
        raise RuntimeError("publish must push exactly two loaded images")
    if publish.index("/usr/bin/docker load") >= publish.index("${{ secrets.GITHUB_TOKEN }}"):
        raise RuntimeError("images must be loaded and identity-checked before credential binding")


def _validate_publication_contract(publish: str) -> None:
    for fragment in (
        "artifact-ids: ${{ needs.scan.outputs.handoff_artifact_id }}",
        "EXPECTED_ARTIFACT_DIGEST: ${{ needs.scan.outputs.handoff_artifact_digest }}",
        "SCAN_SOURCE_REVISION: ${{ needs.scan.outputs.source_revision }}",
        "EXPECTED_BUILD_ARTIFACT_ID: ${{ needs.scan.outputs.build_artifact_id }}",
        "EXPECTED_BUILD_ARTIFACT_DIGEST: ${{ needs.scan.outputs.build_artifact_digest }}",
        "EXPECTED_BUILD_MANIFEST_SHA256: ${{ needs.scan.outputs.build_manifest_sha256 }}",
        "digest-mismatch: error",
        "object_pairs_hook=reject_pairs",
        "parse_constant=reject_constant",
        "scanned-image manifest is not canonical JSON",
        '"build_handoff"',
        "scanned-image build provenance binding does not match",
        'evidence["untrusted-build-handoff.json"]["sha256"]',
        "/usr/bin/docker load --input \"$HANDOFF_DIR/backend-image.tar\"",
        "/usr/bin/docker load --input \"$HANDOFF_DIR/site-image.tar\"",
        'binding["image_id"] != image_id',
        'docker push "$backend_tag"',
        'docker push "$site_tag"',
        "if len(matches) != 1:",
        '"scan_handoff": {',
        '"artifact_id": artifact_id',
        '"artifact_digest": artifact_digest',
        '"manifest_sha256": hashlib.sha256(scanned_manifest).hexdigest()',
        "untrusted-build-handoff.json",
        "/usr/bin/sha256sum -- * >SHA256SUMS",
        "name: release-images-${{ inputs.environment }}-${{ inputs.source_revision }}",
        "if-no-files-found: error",
        "retention-days: 90",
    ):
        require(publish, fragment, "fresh immutable publication")
    ordered = (
        "Download exact immutable scanned-image handoff",
        "Validate closed scanned-image handoff before loading",
        "Load exact scanned images without executing candidate code",
        "Publish only the loaded scanned images",
        "Create digest-only Helm promotion handoff",
        "Upload immutable image publication evidence",
    )
    if [publish.index(name) for name in ordered] != sorted(publish.index(name) for name in ordered):
        raise RuntimeError("fresh publication steps are reordered")


def validate(path: pathlib.Path = WORKFLOW) -> None:
    source = path.read_text(encoding="utf-8")
    _validate_trigger_and_root(source)
    build = _job_block(source, "build")
    scan = _job_block(source, "scan")
    publish = _job_block(source, "publish")
    _validate_job_boundaries(source, build, scan, publish)
    _validate_step_surface(build, scan, publish)
    _validate_build_contract(build)
    _validate_scan_execution_boundary(scan)
    _validate_scan_contract(scan)
    _validate_publish_execution_boundary(publish)
    _validate_publication_contract(publish)
    for forbidden in (
        ":latest",
        "if-no-files-found: warn",
        ".RepoDigests",
        "continue-on-error:",
    ):
        if forbidden in source:
            raise RuntimeError(f"release image workflow contains a bypass: {forbidden}")


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"release image workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Three-runner release image publication workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
