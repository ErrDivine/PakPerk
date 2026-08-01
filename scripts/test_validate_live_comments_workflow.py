#!/usr/bin/env python3
"""Tamper regressions for the disposable live-comments workflow contract."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

import validate_live_comments_workflow as validator


class LiveCommentsWorkflowTests(unittest.TestCase):
    def _validate(
        self,
        *,
        workflow_source: str | None = None,
        requirements_source: str | None = None,
        compose_source: str | None = None,
        realm_source: str | None = None,
        evidence_contract_source: str | None = None,
        helm_schema_source: str | None = None,
        harness_source: str | None = None,
        keycloak_readme_source: str | None = None,
        moderation_runbook_source: str | None = None,
        release_runbook_source: str | None = None,
        ci_source: str | None = None,
        check_source: str | None = None,
    ) -> None:
        defaults = {
            "workflow": validator.DEFAULT_WORKFLOW,
            "requirements": validator.DEFAULT_REQUIREMENTS,
            "compose": validator.DEFAULT_COMPOSE,
            "realm": validator.DEFAULT_REALM,
            "evidence_contract": validator.DEFAULT_EVIDENCE_CONTRACT,
            "helm_schema": validator.DEFAULT_HELM_SCHEMA,
            "harness": validator.DEFAULT_HARNESS,
            "keycloak_readme": validator.DEFAULT_KEYCLOAK_README,
            "moderation_runbook": validator.DEFAULT_MODERATION_RUNBOOK,
            "release_runbook": validator.DEFAULT_RELEASE_RUNBOOK,
            "ci": validator.DEFAULT_CI,
            "check": validator.DEFAULT_CHECK,
        }
        overrides = {
            "workflow": workflow_source,
            "requirements": requirements_source,
            "compose": compose_source,
            "realm": realm_source,
            "evidence_contract": evidence_contract_source,
            "helm_schema": helm_schema_source,
            "harness": harness_source,
            "keycloak_readme": keycloak_readme_source,
            "moderation_runbook": moderation_runbook_source,
            "release_runbook": release_runbook_source,
            "ci": ci_source,
            "check": check_source,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            paths: dict[str, pathlib.Path] = {}
            for name, default in defaults.items():
                path = root / name
                source = overrides[name]
                path.write_text(
                    default.read_text(encoding="utf-8") if source is None else source,
                    encoding="utf-8",
                )
                paths[name] = path
            validator.validate(
                paths["workflow"],
                paths["requirements"],
                paths["compose"],
                paths["realm"],
                paths["evidence_contract"],
                paths["helm_schema"],
                paths["harness"],
                paths["keycloak_readme"],
                paths["moderation_runbook"],
                paths["release_runbook"],
                paths["ci"],
                paths["check"],
            )

    def _workflow(self) -> str:
        return validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8")

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_fails(self) -> None:
        source = self._workflow().replace(
            "  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n", 1
        )
        with self.assertRaisesRegex(RuntimeError, "manual-dispatch only"):
            self._validate(workflow_source=source)

    def test_write_permission_fails(self) -> None:
        source = self._workflow().replace("contents: read", "contents: write", 1)
        with self.assertRaisesRegex(RuntimeError, "least privilege"):
            self._validate(workflow_source=source)

    def test_secret_consumption_fails(self) -> None:
        source = self._workflow().replace(
            "RUST_TOOLCHAIN: 1.91.1",
            "RUST_TOOLCHAIN: 1.91.1\n      UNSAFE: ${{ secrets.UNSAFE }}",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "must not consume secrets"):
            self._validate(workflow_source=source)

    def test_non_main_dispatch_fails(self) -> None:
        source = self._workflow().replace(
            "if: github.ref == 'refs/heads/main'",
            "if: github.ref != ''",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "boundary is missing"):
            self._validate(workflow_source=source)

    def test_dispatch_sha_equality_removal_fails(self) -> None:
        source = self._workflow().replace(
            '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
            '[[ -z "$REQUESTED_REVISION" ]]',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source verification"):
            self._validate(workflow_source=source)

    def test_mutable_checkout_fails(self) -> None:
        source = self._workflow().replace(
            "ref: ${{ inputs.source_revision }}", "ref: main", 1
        )
        with self.assertRaisesRegex(RuntimeError, "checkout step is missing"):
            self._validate(workflow_source=source)

    def test_unprotected_environment_fails(self) -> None:
        source = self._workflow().replace(
            "environment: live-comments-acceptance", "environment: development", 1
        )
        with self.assertRaisesRegex(RuntimeError, "boundary is missing"):
            self._validate(workflow_source=source)

    def test_unbounded_timeout_fails(self) -> None:
        source = self._workflow().replace("timeout-minutes: 45", "timeout-minutes: 450", 1)
        with self.assertRaisesRegex(RuntimeError, "boundary is missing"):
            self._validate(workflow_source=source)

    def test_missing_dependency_hash_fails(self) -> None:
        requirements = validator.DEFAULT_REQUIREMENTS.read_text(encoding="utf-8")
        requirements = requirements.replace(
            "requests==2.32.4 --hash=sha256:", "requests==2.32.4 # sha256:", 1
        )
        with self.assertRaisesRegex(RuntimeError, "not one exact pin/hash"):
            self._validate(requirements_source=requirements)

    def test_direct_dependency_install_fails(self) -> None:
        source = self._workflow().replace(
            "--requirement scripts/requirements/live-comments.txt",
            "requests==2.32.4",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "bounded dependency installation"):
            self._validate(workflow_source=source)

    def test_mutable_compose_image_fails(self) -> None:
        compose = validator.DEFAULT_COMPOSE.read_text(encoding="utf-8").replace(
            validator.EXPECTED_COMPOSE_IMAGES["keycloak"],
            "quay.io/keycloak/keycloak:26.7.0",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "reviewed tag and digest"):
            self._validate(compose_source=compose)

    def test_admin_api_audience_fails(self) -> None:
        realm = validator.DEFAULT_REALM.read_text(encoding="utf-8").replace(
            '"included.custom.audience": "pakperk-admin-dev"',
            '"included.custom.audience": "pakperk-api"',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "emit only the admin audience"):
            self._validate(realm_source=realm)

    def test_admin_direct_grant_fails(self) -> None:
        document = json.loads(validator.DEFAULT_REALM.read_text(encoding="utf-8"))
        admin = next(
            client
            for client in document["clients"]
            if client["clientId"] == "pakperk-admin-dev"
        )
        admin["directAccessGrantsEnabled"] = True
        with self.assertRaisesRegex(RuntimeError, "unsafe directAccessGrantsEnabled"):
            self._validate(realm_source=json.dumps(document))

    def test_admin_device_grant_fails(self) -> None:
        document = json.loads(validator.DEFAULT_REALM.read_text(encoding="utf-8"))
        admin = next(
            client
            for client in document["clients"]
            if client["clientId"] == "pakperk-admin-dev"
        )
        admin["attributes"]["oauth2.device.authorization.grant.enabled"] = "true"
        with self.assertRaisesRegex(RuntimeError, "unsafe grant attributes"):
            self._validate(realm_source=json.dumps(document))

    def test_admin_default_scope_widening_fails(self) -> None:
        document = json.loads(validator.DEFAULT_REALM.read_text(encoding="utf-8"))
        admin = next(
            client
            for client in document["clients"]
            if client["clientId"] == "pakperk-admin-dev"
        )
        admin["defaultClientScopes"].append("email")
        with self.assertRaisesRegex(RuntimeError, "unsafe default scopes"):
            self._validate(realm_source=json.dumps(document))

    def test_public_admin_secret_fails(self) -> None:
        document = json.loads(validator.DEFAULT_REALM.read_text(encoding="utf-8"))
        admin = next(
            client
            for client in document["clients"]
            if client["clientId"] == "pakperk-admin-dev"
        )
        admin["secret"] = "not-allowed"
        with self.assertRaisesRegex(RuntimeError, "must not contain a secret"):
            self._validate(realm_source=json.dumps(document))

    def test_missing_admin_client_workflow_binding_fails(self) -> None:
        source = self._workflow().replace(
            "LIVE_COMMENTS_ADMIN_OIDC_CLIENT_ID: pakperk-admin-dev",
            "LIVE_COMMENTS_ADMIN_OIDC_CLIENT_ID: pakperk-mobile-dev",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "harness is missing"):
            self._validate(workflow_source=source)

    def test_release_shaped_reference_content_id_fails(self) -> None:
        contract = validator.DEFAULT_EVIDENCE_CONTRACT.read_text(encoding="utf-8")
        contract = contract.replace(
            'CONTENT_ID = re.compile(r"reference-sha256:[0-9a-f]{64}")',
            'CONTENT_ID = re.compile(r"sha256:[0-9a-f]{64}")',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "non-release evidence contract"):
            self._validate(evidence_contract_source=contract)

    def test_artifact_can_not_claim_hosted_protection(self) -> None:
        contract = validator.DEFAULT_EVIDENCE_CONTRACT.read_text(encoding="utf-8")
        contract = contract.replace(
            'MANUAL_CI_ENVIRONMENT = "manual_ci_disposable_reference"',
            'MANUAL_CI_ENVIRONMENT = "protected_ci_disposable_reference"',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "must not claim hosted protection"):
            self._validate(evidence_contract_source=contract)

    def test_docs_can_not_claim_protected_artifact(self) -> None:
        runbook = validator.DEFAULT_MODERATION_RUNBOOK.read_text(encoding="utf-8")
        runbook = runbook.replace(
            "manual_ci_disposable_reference",
            "protected_ci_disposable_reference",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "moderation runbook is missing"):
            self._validate(moderation_runbook_source=runbook)

    def test_helm_accepting_reference_content_id_fails(self) -> None:
        schema = validator.DEFAULT_HELM_SCHEMA.read_text(encoding="utf-8").replace(
            "^$|^sha256:[a-f0-9]{64}$",
            "^$|^(?:reference-)?sha256:[a-f0-9]{64}$",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "pattern changed without review"):
            self._validate(helm_schema_source=schema)

    def test_harness_failure_masking_fails(self) -> None:
        source = self._workflow().replace("continue-on-error: true", "continue-on-error: false", 1)
        with self.assertRaisesRegex(RuntimeError, "harness is missing"):
            self._validate(workflow_source=source)

    def test_unlocked_rust_build_fails(self) -> None:
        harness = validator.DEFAULT_HARNESS.read_text(encoding="utf-8").replace(
            "cargo build --locked --manifest-path",
            "cargo build --manifest-path",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "locked live-comments Rust build"):
            self._validate(harness_source=harness)

    def test_missing_evidence_validation_fails(self) -> None:
        source = self._workflow().replace(
            "python3 scripts/validate_live_comments_evidence.py",
            "python3 -m json.tool",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "packaging is missing"):
            self._validate(workflow_source=source)

    def test_owner_only_packaging_umask_is_required(self) -> None:
        source = self._workflow().replace(
            "        run: |\n          umask 077\n          evidence_dir=\"$RUNNER_TEMP/pakperk-live-comments-evidence\"",
            "        run: |\n          evidence_dir=\"$RUNNER_TEMP/pakperk-live-comments-evidence\"",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "packaging is missing"):
            self._validate(workflow_source=source)

    def test_empty_evidence_acceptance_fails(self) -> None:
        source = self._workflow().replace(
            '[[ ! -s "$evidence_file" || -L "$evidence_file" ]]',
            '[[ ! -e "$evidence_file" ]]',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "packaging is missing"):
            self._validate(workflow_source=source)

    def test_broad_artifact_path_fails(self) -> None:
        source = self._workflow().replace(
            "path: ${{ runner.temp }}/pakperk-live-comments-evidence.tar",
            "path: ${{ runner.temp }}",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "upload is missing"):
            self._validate(workflow_source=source)

    def test_partial_archive_can_not_use_canonical_upload_path(self) -> None:
        source = self._workflow().replace(
            '--file "$temporary_archive"',
            '--file "$archive"',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "packaging is missing"):
            self._validate(workflow_source=source)

    def test_artifact_name_must_include_exact_source(self) -> None:
        source = self._workflow().replace(
            "name: live-comments-acceptance-${{ inputs.source_revision }}-${{ github.run_id }}-${{ github.run_attempt }}",
            "name: live-comments-acceptance-${{ github.run_id }}-${{ github.run_attempt }}",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "upload is missing"):
            self._validate(workflow_source=source)

    def test_missing_artifact_warning_fails(self) -> None:
        source = self._workflow().replace(
            "if-no-files-found: error", "if-no-files-found: warn", 1
        )
        with self.assertRaisesRegex(RuntimeError, "upload is missing"):
            self._validate(workflow_source=source)

    def test_long_retention_fails(self) -> None:
        source = self._workflow().replace("retention-days: 30", "retention-days: 365", 1)
        with self.assertRaisesRegex(RuntimeError, "upload is missing"):
            self._validate(workflow_source=source)

    def test_non_disposable_cleanup_fails(self) -> None:
        source = self._workflow().replace("down --volumes --remove-orphans", "stop", 1)
        with self.assertRaisesRegex(RuntimeError, "teardown is missing"):
            self._validate(workflow_source=source)

    def test_cleanup_failure_can_not_be_packaged(self) -> None:
        source = self._workflow().replace(
            '[[ "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
            '[[ -z "$COMPOSE_CLEANUP_OUTCOME" ]]',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "packaging is missing"):
            self._validate(workflow_source=source)

    def test_teardown_outcome_masking_fails(self) -> None:
        source = self._workflow().replace(
            "continue-on-error: true\n        shell: bash\n        run: docker compose",
            "continue-on-error: false\n        shell: bash\n        run: docker compose",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "teardown is missing"):
            self._validate(workflow_source=source)

    def test_evidence_before_teardown_fails(self) -> None:
        source = self._workflow()
        teardown_marker = "      - name: Tear down disposable services\n"
        package_marker = (
            "      - name: Validate and package sanitized disposable evidence\n"
        )
        summary_marker = "      - name: Record disposable evidence boundary\n"
        teardown_start = source.index(teardown_marker)
        package_start = source.index(package_marker)
        summary_start = source.index(summary_marker)
        teardown = source[teardown_start:package_start]
        package = source[package_start:summary_start]
        reordered = (
            source[:teardown_start]
            + package
            + teardown
            + source[summary_start:]
        )
        with self.assertRaisesRegex(RuntimeError, "steps reordered"):
            self._validate(workflow_source=reordered)

    def test_final_result_must_enforce_teardown(self) -> None:
        source = self._workflow().replace(
            '[[ "$LIVE_COMMENTS_OUTCOME" != "success" || "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
            '[[ "$LIVE_COMMENTS_OUTCOME" != "success" ]]',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "result enforcement"):
            self._validate(workflow_source=source)

    def test_evidence_scope_overclaim_fails(self) -> None:
        source = self._workflow().replace(
            "sanitized disposable reference-stack evidence",
            "production approval evidence",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "classification is missing"):
            self._validate(workflow_source=source)

    def test_result_enforcement_removal_fails(self) -> None:
        source = self._workflow().replace(
            '[[ "$LIVE_COMMENTS_OUTCOME" != "success" || "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
            '[[ "$LIVE_COMMENTS_OUTCOME" == "success" || "$COMPOSE_CLEANUP_OUTCOME" != "success" ]]',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "result enforcement"):
            self._validate(workflow_source=source)

    def test_ci_cannot_drop_tamper_regressions(self) -> None:
        ci = validator.DEFAULT_CI.read_text(encoding="utf-8").replace(
            "          python3 scripts/test_validate_live_comments_workflow.py\n",
            "",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "CI live-comments contract wiring"):
            self._validate(ci_source=ci)


if __name__ == "__main__":
    unittest.main()
