#!/usr/bin/env python3
"""Validate the disposable live-comments workflow and its supply-chain locks."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/live-comments-acceptance.yml"
DEFAULT_REQUIREMENTS = ROOT / "scripts/requirements/live-comments.txt"
DEFAULT_COMPOSE = ROOT / "docker-compose.yml"
DEFAULT_REALM = ROOT / "deploy/keycloak/pakperk-realm.json"
DEFAULT_EVIDENCE_CONTRACT = ROOT / "scripts/live_comments_evidence.py"
DEFAULT_HELM_SCHEMA = ROOT / "deploy/helm/pakperk/values.schema.json"
DEFAULT_HARNESS = ROOT / "scripts/test_live_comments.sh"
DEFAULT_KEYCLOAK_README = ROOT / "deploy/keycloak/README.md"
DEFAULT_MODERATION_RUNBOOK = ROOT / "docs/runbooks/moderation.md"
DEFAULT_RELEASE_RUNBOOK = ROOT / "docs/runbooks/release.md"
DEFAULT_CI = ROOT / ".github/workflows/ci.yml"
DEFAULT_CHECK = ROOT / "scripts/check.sh"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
EXPECTED_SOURCE_STEP_SHA256 = (
    "f586094ef94bf80c2a41a342729b21a6691b2dccc4f7c5d5d12e8a9460a1fb6f"
)
EXPECTED_TRIGGER_SHA256 = (
    "9bef5dddf168d63576ae6113caf9d0eaa3f7adb4406f13f6cf656419fc67ab7b"
)
EXPECTED_STEP_ITEMS_SHA256 = (
    "b4a5239a1aac2d3df063e602d8ce6ee4713ab90a86c1bf49250a1913e555aea4"
)
EXPECTED_CHECKOUT_STEP_SHA256 = (
    "6bc05ec1a7fbb3a14b447485291230172fdfe398392d701d6fc4ec2a09b4ca50"
)
EXPECTED_ENFORCEMENT_STEP_SHA256 = (
    "b6ab966d9941c65763475ba780104259ac47f7bd4c3de95052ba9f504593e546"
)
EXPECTED_JOB_ENV_SHA256 = (
    "5bf081dc06c458901ecb4bf8202a8f865175950ebf11ac06e9e5cf4aa6791c8c"
)
EXPECTED_REQUIREMENTS = {
    "beautifulsoup4": (
        "4.13.4",
        "9bbbb14bfde9d79f38b8cd5f8c7c85f4b8f2523190ebed90e950a8dea4cb1c4b",
    ),
    "certifi": (
        "2026.7.22",
        "62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775",
    ),
    "charset-normalizer": (
        "3.4.9",
        "5e226f6218febc71f6c1fc2fafb91c226f75bdc1d8fb12d66823716e891608fd",
    ),
    "idna": (
        "3.18",
        "7f952cbe720b688055e3f87de14f5c3e5fdaa8bc3928985c4077ca689de849a2",
    ),
    "requests": (
        "2.32.4",
        "27babd3cda2a6d50b30443204ee89830707d396671944c998b5975b031ac2b2c",
    ),
    "soupsieve": (
        "2.9.1",
        "4f4477399246b7a0c720a88ca2454b11cd6bb9ae4c9d170140786e916776c14c",
    ),
    "typing-extensions": (
        "4.16.0",
        "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
    ),
    "urllib3": (
        "2.7.0",
        "9fb4c81ebbb1ce9531cce37674bbc6f1360472bc18ca9a553ede278ef7276897",
    ),
}
EXPECTED_COMPOSE_IMAGES = {
    "postgres": "pgvector/pgvector:0.8.2-pg16-bookworm@sha256:00ba258a66dac104fd5171074a0084462a64a1369d8513f3d0a634e2f24d15bc",
    "keycloak-postgres": "postgres:16.14-bookworm@sha256:92620daddcd947f8d5ab5ba66e848702fe443d87fed30c4cea8e389fd78dfc55",
    "mailpit": "axllent/mailpit:v1.30.6@sha256:7f33095f80e901f6ad08028f06ca284aa58fe84942be5496008d041d3b9f4d4d",
    "keycloak": "quay.io/keycloak/keycloak:26.7.0@sha256:0f198be292568439d700cdbfb893e69a6009bb43a94a06a945b1d3d506c76b13",
}
REQUIREMENT = re.compile(
    r"([a-z0-9]+(?:-[a-z0-9]+)*)==([A-Za-z0-9][A-Za-z0-9._-]*) "
    r"--hash=sha256:([0-9a-f]{64})"
)


def _require(source: str, fragment: str, label: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"{label} is missing: {fragment}")


def _step_block(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"workflow must contain exactly one {label}")
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


def _validate_requirements(path: pathlib.Path) -> None:
    resolved: dict[str, tuple[str, str]] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = REQUIREMENT.fullmatch(line)
        if match is None:
            raise RuntimeError(
                f"live-comments requirement line {line_number} is not one exact pin/hash"
            )
        name, version, digest = match.groups()
        if name in resolved:
            raise RuntimeError(f"live-comments requirement is duplicated: {name}")
        resolved[name] = (version, digest)
    if resolved != EXPECTED_REQUIREMENTS:
        raise RuntimeError(
            "live-comments Python dependency graph changed without review"
        )


def _validate_compose(path: pathlib.Path) -> None:
    images: dict[str, str] = {}
    current_service: str | None = None
    in_services = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line == "services:":
            in_services = True
            continue
        if not in_services:
            continue
        if raw_line and not raw_line.startswith(" "):
            break
        service_match = re.fullmatch(r"  ([a-z0-9][a-z0-9-]*):", raw_line)
        if service_match is not None:
            current_service = service_match.group(1)
            continue
        image_match = re.fullmatch(r"    image: ([^ #]+)", raw_line)
        if current_service is not None and image_match is not None:
            images[current_service] = image_match.group(1)
    for service, expected in EXPECTED_COMPOSE_IMAGES.items():
        if images.get(service) != expected:
            raise RuntimeError(
                f"Compose service {service} must use the reviewed tag and digest"
            )


def _validate_admin_client(path: pathlib.Path) -> None:
    document = json.loads(path.read_text(encoding="utf-8"))
    clients = document.get("clients")
    if not isinstance(clients, list):
        raise RuntimeError("Keycloak realm clients must be a list")
    matches = [
        client for client in clients if client.get("clientId") == "pakperk-admin-dev"
    ]
    if len(matches) != 1:
        raise RuntimeError("Keycloak realm must contain one dedicated admin client")
    client = matches[0]
    expected_scalars = {
        "enabled": True,
        "publicClient": True,
        "bearerOnly": False,
        "standardFlowEnabled": True,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": False,
        "protocol": "openid-connect",
        "redirectUris": ["pakperk-admin-dev://oauth/callback"],
        "webOrigins": [],
    }
    for key, expected in expected_scalars.items():
        if client.get(key) != expected:
            raise RuntimeError(f"dedicated admin client has an unsafe {key} boundary")
    if "secret" in client:
        raise RuntimeError("public admin client must not contain a secret")
    expected_attributes = {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "pakperk-admin-dev://oauth/logout",
        "oauth2.device.authorization.grant.enabled": "false",
        "oidc.ciba.grant.enabled": "false",
        "backchannel.logout.session.required": "true",
        "backchannel.logout.revoke.offline.tokens": "true",
        "use.refresh.tokens": "false",
    }
    if client.get("attributes") != expected_attributes:
        raise RuntimeError("dedicated admin client has unsafe grant attributes")
    expected_default_scopes = ["web-origins", "acr", "profile", "roles", "basic"]
    if client.get("defaultClientScopes") != expected_default_scopes:
        raise RuntimeError("dedicated admin client has unsafe default scopes")
    if client.get("optionalClientScopes") != []:
        raise RuntimeError("dedicated admin client must have no optional scopes")
    expected_mapper = {
        "name": "Pakperk admin audience",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-audience-mapper",
        "consentRequired": False,
        "config": {
            "included.custom.audience": "pakperk-admin-dev",
            "id.token.claim": "false",
            "access.token.claim": "true",
            "userinfo.token.claim": "false",
            "introspection.token.claim": "true",
        },
    }
    if client.get("protocolMappers") != [expected_mapper]:
        raise RuntimeError("dedicated admin client must emit only the admin audience")


def _validate_non_release_evidence_identity(
    evidence_contract: pathlib.Path, helm_schema: pathlib.Path
) -> None:
    source = evidence_contract.read_text(encoding="utf-8")
    if "protected_ci_disposable_reference" in source:
        raise RuntimeError("disposable evidence must not claim hosted protection")
    for fragment in (
        'CONTENT_ID = re.compile(r"reference-sha256:[0-9a-f]{64}")',
        '"disposable reference evidence; not staging or public-enablement approval"',
        'MANUAL_CI_ENVIRONMENT = "manual_ci_disposable_reference"',
    ):
        _require(source, fragment, "live-comments non-release evidence contract")

    schema = json.loads(helm_schema.read_text(encoding="utf-8"))
    try:
        release_pattern = schema["definitions"]["evidenceIdOrEmpty"]["pattern"]
    except (KeyError, TypeError) as error:
        raise RuntimeError("Helm release-evidence ID schema is unavailable") from error
    if release_pattern != r"^$|^sha256:[a-f0-9]{64}$":
        raise RuntimeError("Helm release-evidence ID pattern changed without review")
    reference_id = "reference-sha256:" + "a" * 64
    release_id = "sha256:" + "a" * 64
    if (
        re.fullmatch(release_pattern, reference_id) is not None
        or re.fullmatch(release_pattern, release_id) is None
    ):
        raise RuntimeError(
            "disposable reference evidence is not separated from release evidence"
        )


def _validate_manual_evidence_docs(
    keycloak_readme: pathlib.Path,
    moderation_runbook: pathlib.Path,
    release_runbook: pathlib.Path,
) -> None:
    documents = {
        "Keycloak acceptance runbook": keycloak_readme.read_text(encoding="utf-8"),
        "moderation runbook": moderation_runbook.read_text(encoding="utf-8"),
        "release runbook": release_runbook.read_text(encoding="utf-8"),
    }
    for label, source in documents.items():
        _require(source, "manual_ci_disposable_reference", label)
        if "protected_ci_disposable_reference" in source:
            raise RuntimeError(f"{label} claims protected disposable evidence")
    for fragment in (
        "required reviewers",
        "deployment-branch restriction",
        "cannot prove that the GitHub-hosted reviewer and deployment-branch rules exist",
    ):
        _require(
            documents["Keycloak acceptance runbook"], fragment, "hosted prerequisite"
        )
    for fragment in (
        "do not create or attest those out-of-band protection settings",
        "never a protected-environment claim",
    ):
        _require(
            documents["moderation runbook"], fragment, "truthful moderation evidence"
        )
    _require(
        documents["release runbook"],
        "it does not attest GitHub environment\nprotection",
        "truthful release evidence",
    )


def validate(
    workflow: pathlib.Path = DEFAULT_WORKFLOW,
    requirements: pathlib.Path = DEFAULT_REQUIREMENTS,
    compose: pathlib.Path = DEFAULT_COMPOSE,
    realm: pathlib.Path = DEFAULT_REALM,
    evidence_contract: pathlib.Path = DEFAULT_EVIDENCE_CONTRACT,
    helm_schema: pathlib.Path = DEFAULT_HELM_SCHEMA,
    harness: pathlib.Path = DEFAULT_HARNESS,
    keycloak_readme: pathlib.Path = DEFAULT_KEYCLOAK_README,
    moderation_runbook: pathlib.Path = DEFAULT_MODERATION_RUNBOOK,
    release_runbook: pathlib.Path = DEFAULT_RELEASE_RUNBOOK,
    ci: pathlib.Path = DEFAULT_CI,
    check: pathlib.Path = DEFAULT_CHECK,
) -> None:
    _validate_requirements(requirements)
    _validate_compose(compose)
    _validate_admin_client(realm)
    _validate_non_release_evidence_identity(evidence_contract, helm_schema)
    _validate_manual_evidence_docs(keycloak_readme, moderation_runbook, release_runbook)
    harness_source = harness.read_text(encoding="utf-8")
    _require(
        harness_source,
        'cargo build --locked --manifest-path "$project_dir/backend/Cargo.toml"',
        "locked live-comments Rust build",
    )

    source = workflow.read_text(encoding="utf-8")
    if _mapping_keys(source, 0) != [
        "name",
        "on",
        "permissions",
        "concurrency",
        "jobs",
    ]:
        raise RuntimeError("live-comments workflow root mapping changed")
    if re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("live-comments workflow must not use YAML merge keys")
    trigger_start = source.index("\non:\n") + 1
    trigger_end = source.index("\npermissions:", trigger_start)
    trigger = source[trigger_start:trigger_end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("live-comments acceptance must be manual-dispatch only")
    if hashlib.sha256(trigger.encode("utf-8")).hexdigest() != EXPECTED_TRIGGER_SHA256:
        raise RuntimeError("live-comments dispatch schema changed")
    for input_name in ("source_revision", "confirmation"):
        if trigger.count(f"      {input_name}:") != 1:
            raise RuntimeError(f"workflow must define one required {input_name} input")

    permissions_end = source.index("\nconcurrency:", trigger_end)
    permissions = source[trigger_end + 1 : permissions_end].strip()
    if permissions != "permissions:\n  contents: read":
        raise RuntimeError("live-comments workflow permissions are not least privilege")
    concurrency_end = source.index("\njobs:\n", permissions_end)
    if source[permissions_end + 1 : concurrency_end].strip() != (
        "concurrency:\n"
        "  group: live-comments-acceptance\n"
        "  cancel-in-progress: false"
    ):
        raise RuntimeError(
            "live-comments concurrency must be bounded and non-cancelling"
        )

    if source.count("\njobs:\n") != 1:
        raise RuntimeError("live-comments workflow job boundary is malformed")
    jobs = source[source.index("\njobs:\n") + len("\njobs:\n") :]
    if _mapping_keys(jobs, 2) != ["disposable-comments"]:
        raise RuntimeError(
            "live-comments workflow must contain exactly one bounded job"
        )
    job_start = source.index("  disposable-comments:\n", source.index("\njobs:\n"))
    env_start = source.index("    env:\n", job_start)
    expected_job_prefix = (
        "  disposable-comments:\n"
        "    runs-on: ubuntu-24.04\n"
        "    environment: live-comments-acceptance\n"
        "    timeout-minutes: 45\n"
    )
    if source[job_start:env_start] != expected_job_prefix:
        raise RuntimeError(
            "live-comments job execution boundary changed; job-level conditions are fail-open"
        )
    steps_start = source.index("    steps:\n", env_start)
    job_env = source[env_start:steps_start].removesuffix("\n")
    if hashlib.sha256(job_env.encode("utf-8")).hexdigest() != EXPECTED_JOB_ENV_SHA256:
        raise RuntimeError("live-comments inherited job environment changed")
    if _mapping_keys(source[job_start:], 4) != [
        "runs-on",
        "environment",
        "timeout-minutes",
        "env",
        "steps",
    ]:
        raise RuntimeError(
            "live-comments job contains an unexpected or reordered job-level key"
        )
    step_items = re.findall(r"(?m)^      -[^\n]*$", source[steps_start:])
    if any(
        re.fullmatch(r"      - (?:name: .+|uses: [^ #]+(?: # .+)?)", item) is None
        for item in step_items
    ):
        raise RuntimeError("live-comments workflow contains a non-canonical step item")
    step_item_contract = "\n".join(step_items) + "\n"
    if (
        hashlib.sha256(step_item_contract.encode("utf-8")).hexdigest()
        != EXPECTED_STEP_ITEMS_SHA256
    ):
        raise RuntimeError("live-comments workflow step surface changed")
    if step_items[:2] != [
        f"      - uses: {CHECKOUT_ACTION} # v7.0.1",
        "      - name: Verify exact reviewed main source",
    ]:
        raise RuntimeError(
            "live-comments workflow must establish source trust before executable work"
        )

    for fragment in (
        "group: live-comments-acceptance",
        "cancel-in-progress: false",
        "runs-on: ubuntu-24.04",
        "environment: live-comments-acceptance",
        "timeout-minutes: 45\n",
        "RUST_TOOLCHAIN: 1.91.1",
        "REQUESTED_REVISION: ${{ inputs.source_revision }}",
        "COMPOSE_PROJECT_NAME: pakperk-live-comments-${{ github.run_id }}-${{ github.run_attempt }}",
    ):
        _require(source, fragment, "live-comments workflow boundary")
    if "${{ secrets." in source:
        raise RuntimeError("disposable live-comments workflow must not consume secrets")

    checkout = _step_block(
        source,
        f"      - uses: {CHECKOUT_ACTION}",
        "reviewed checkout step",
    )
    if (
        hashlib.sha256(checkout.encode("utf-8")).hexdigest()
        != EXPECTED_CHECKOUT_STEP_SHA256
    ):
        raise RuntimeError("reviewed checkout step changed")
    if re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", checkout) != ["with"]:
        raise RuntimeError("reviewed checkout step has an unexpected step key")
    expected_checkout = (
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false\n"
    )
    if checkout[checkout.index("        with:\n") :] != expected_checkout:
        raise RuntimeError("reviewed checkout step inputs changed")

    source_step = _step_block(
        source,
        "      - name: Verify exact reviewed main source\n",
        "source verification step",
    )
    if (
        hashlib.sha256(source_step.encode("utf-8")).hexdigest()
        != EXPECTED_SOURCE_STEP_SHA256
    ):
        raise RuntimeError("exact reviewed source verification command changed")
    for fragment in (
        "DISPATCH_REF: ${{ github.ref }}",
        "DISPATCH_REVISION: ${{ github.sha }}",
        '[[ "$DISPATCH_REF" != "refs/heads/main" ]]',
        '[[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]',
        '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
        '[[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]',
        '[[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]',
        '"RUN_DISPOSABLE_LIVE_COMMENTS"',
    ):
        _require(source_step, fragment, "exact reviewed source verification")
    if "continue-on-error:" in source_step:
        raise RuntimeError("exact reviewed source verification must not be recoverable")

    dependency_step = _step_block(
        source,
        "      - name: Install bounded live-driver dependencies\n",
        "dependency installation step",
    )
    for fragment in (
        "sys.version_info[:2] != (3, 12)",
        "--require-hashes",
        "--only-binary=:all:",
        "--requirement scripts/requirements/live-comments.txt",
    ):
        _require(dependency_step, fragment, "bounded dependency installation")
    for forbidden in ("requests==", "beautifulsoup4=="):
        if forbidden in dependency_step:
            raise RuntimeError(
                f"workflow bypasses the complete live-comments hash lock: {forbidden}"
            )

    harness_step = _step_block(
        source,
        "      - name: Run disposable live-comments acceptance\n",
        "live-comments harness step",
    )
    for fragment in (
        "id: live-comments",
        "continue-on-error: true",
        'LIVE_COMMENTS_MANAGE_COMPOSE: "1"',
        "LIVE_COMMENTS_EVIDENCE_FILE: ${{ runner.temp }}/pakperk-live-comments-evidence/live-comments-evidence.json",
        "LIVE_COMMENTS_SOURCE_REVISION: ${{ inputs.source_revision }}",
        "LIVE_COMMENTS_EVIDENCE_ENVIRONMENT: manual_ci_disposable_reference",
        "LIVE_COMMENTS_ADMIN_OIDC_CLIENT_ID: pakperk-admin-dev",
        "LIVE_COMMENTS_ADMIN_OIDC_REDIRECT_URI: pakperk-admin-dev://oauth/callback",
        "LIVE_COMMENTS_ADMIN_OIDC_AUDIENCE: pakperk-admin-dev",
        "./scripts/test_live_comments.sh",
    ):
        _require(harness_step, fragment, "disposable live-comments harness")

    package_step = _step_block(
        source,
        "      - name: Validate and package sanitized disposable evidence\n",
        "evidence packaging step",
    )
    for fragment in (
        "if: always()",
        "LIVE_COMMENTS_OUTCOME: ${{ steps.live-comments.outcome }}",
        "COMPOSE_CLEANUP_OUTCOME: ${{ steps.compose-cleanup.outcome }}",
        "umask 077",
        '[[ "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
        "success) evidence_outcome=passed ;;",
        "failure) evidence_outcome=failed ;;",
        "python3 scripts/validate_live_comments_evidence.py",
        "--environment manual_ci_disposable_reference",
        '--expected-outcome "$evidence_outcome"',
        '[[ ! -s "$evidence_file" || -L "$evidence_file" ]]',
        'temporary_archive="$RUNNER_TEMP/.pakperk-live-comments-evidence.tar.partial"',
        '[[ -e "$archive" || -L "$archive" || -e "$temporary_archive" || -L "$temporary_archive" ]]',
        "sha256sum live-comments-evidence.json >SHA256SUMS",
        "chmod 0400 live-comments-evidence.json SHA256SUMS",
        "live-comments-evidence.json SHA256SUMS",
        '--file "$temporary_archive"',
        'chmod 0400 "$temporary_archive"',
        'mv -- "$temporary_archive" "$archive"',
    ):
        _require(package_step, fragment, "sanitized evidence packaging")

    summary_step = _step_block(
        source,
        "      - name: Record disposable evidence boundary\n",
        "evidence-boundary summary step",
    )
    for fragment in (
        "if: always()",
        "sanitized disposable reference-stack evidence",
        "not",
        "staging",
        "production",
        "public-comment enablement",
        "store-review",
        "signed-release-candidate approval",
    ):
        _require(summary_step, fragment, "truthful evidence classification")

    upload = _step_block(
        source,
        f"      - name: Upload sanitized disposable evidence\n",
        "sanitized evidence upload step",
    )
    for fragment in (
        "if: always()",
        f"uses: {UPLOAD_ACTION}",
        "name: live-comments-acceptance-${{ inputs.source_revision }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "path: ${{ runner.temp }}/pakperk-live-comments-evidence.tar",
        "if-no-files-found: error",
        "retention-days: 30",
    ):
        _require(upload, fragment, "sanitized evidence upload")
    if source.count(f"uses: {UPLOAD_ACTION}") != 1:
        raise RuntimeError("workflow must contain exactly one reviewed evidence upload")

    teardown = _step_block(
        source,
        "      - name: Tear down disposable services\n",
        "disposable service teardown step",
    )
    for fragment in (
        "id: compose-cleanup",
        "if: always()",
        "continue-on-error: true",
        "docker compose --profile accounts down --volumes --remove-orphans",
    ):
        _require(teardown, fragment, "disposable service teardown")

    enforce = _step_block(
        source,
        "      - name: Enforce live-comments acceptance result\n",
        "result enforcement step",
    )
    if (
        hashlib.sha256(enforce.encode("utf-8")).hexdigest()
        != EXPECTED_ENFORCEMENT_STEP_SHA256
    ):
        raise RuntimeError("live-comments result enforcement step changed")
    for fragment in (
        "if: always()",
        "LIVE_COMMENTS_OUTCOME: ${{ steps.live-comments.outcome }}",
        "COMPOSE_CLEANUP_OUTCOME: ${{ steps.compose-cleanup.outcome }}",
        '[[ "$LIVE_COMMENTS_OUTCOME" != "success" || "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
        "exit 1",
    ):
        _require(enforce, fragment, "live-comments result enforcement")

    positions = [
        source.index("Verify exact reviewed main source"),
        source.index("Run disposable live-comments acceptance"),
        source.index("Tear down disposable services"),
        source.index("Validate and package sanitized disposable evidence"),
        source.index("Upload sanitized disposable evidence"),
        source.index("Enforce live-comments acceptance result"),
    ]
    if positions != sorted(positions):
        raise RuntimeError(
            "live-comments trust, cleanup, evidence, and result steps reordered"
        )

    ci_source = ci.read_text(encoding="utf-8")
    check_source = check.read_text(encoding="utf-8")
    ci_commands = (
        "python3 scripts/test_live_comments_evidence.py",
        "python3 scripts/test_validate_live_comments_workflow.py",
        "python3 scripts/validate_live_comments_workflow.py",
    )
    check_commands = (
        'python3 "$project_dir/scripts/test_live_comments_evidence.py"',
        'python3 "$project_dir/scripts/test_validate_live_comments_workflow.py"',
        'python3 "$project_dir/scripts/validate_live_comments_workflow.py"',
    )
    for fragment in ci_commands:
        _require(ci_source, fragment, "CI live-comments contract wiring")
    for fragment in check_commands:
        _require(check_source, fragment, "local live-comments contract wiring")
    if "./scripts/test_live_comments.sh" in ci_source or (
        '"$project_dir/scripts/test_live_comments.sh"' in check_source
    ):
        raise RuntimeError("ordinary CI/check.sh must not run the Docker live harness")


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"live-comments workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Live-comments workflow, dependency, service, and OIDC locks validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
