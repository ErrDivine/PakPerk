#!/usr/bin/env python3
"""Tamper regressions for release-image publication trust boundaries."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_release_image_workflow as validator


class ReleaseImageWorkflowTests(unittest.TestCase):
    def _validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "release-images.yml"
            path.write_text(source, encoding="utf-8")
            validator.validate(path)

    def test_checked_in_workflow_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  workflow_dispatch:\n",
            "  workflow_dispatch:\n  repository_dispatch:\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "manual-dispatch only"):
            self._validate_source(source)

    def test_quoted_automatic_trigger_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  workflow_dispatch:\n",
            '  workflow_dispatch:\n  "push": {}\n',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "manual-dispatch only"):
            self._validate_source(source)

    def test_job_level_main_guard_is_rejected_as_fail_open(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  publish:\n    runs-on: ubuntu-24.04",
            "  publish:\n"
            "    if: github.ref == 'refs/heads/main'\n"
            "    runs-on: ubuntu-24.04",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "job execution boundary"):
            self._validate_source(source)

    def test_job_level_continue_on_error_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  publish:\n    runs-on: ubuntu-24.04",
            "  publish:\n" "    continue-on-error: true\n" "    runs-on: ubuntu-24.04",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "job execution boundary"):
            self._validate_source(source)

    def test_trailing_job_level_if_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8") + "    if: false\n"
        with self.assertRaisesRegex(RuntimeError, "job-level key"):
            self._validate_source(source)

    def test_quoted_sibling_job_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8") + (
            '  "bypass":\n'
            "    runs-on: ubuntu-24.04\n"
            "    steps:\n"
            '      - run: "true"\n'
        )
        with self.assertRaisesRegex(RuntimeError, "exactly one bounded job"):
            self._validate_source(source)

    def test_executable_step_before_source_trust_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "          persist-credentials: false\n\n"
            "      - name: Resolve reviewed source and immutable image names",
            "          persist-credentials: false\n\n"
            "      - run: echo bypass\n\n"
            "      - name: Resolve reviewed source and immutable image names",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "non-canonical step item"):
            self._validate_source(source)

    def test_dispatch_environment_cannot_be_widened(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "        type: choice\n        options: [staging, production]",
            "        type: string",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "dispatch schema"):
            self._validate_source(source)

    def test_inherited_bash_environment_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  RUST_TOOLCHAIN: 1.91.1\n",
            "  BASH_ENV: ${{ github.workspace }}/pretrust.sh\n"
            "  RUST_TOOLCHAIN: 1.91.1\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "inherited environment"):
            self._validate_source(source)

    def test_inflight_publication_cannot_be_cancelled(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "cancel-in-progress: false", "cancel-in-progress: true", 1
        )
        with self.assertRaisesRegex(RuntimeError, "non-cancelling"):
            self._validate_source(source)

    def test_quoted_checkout_key_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "        with:\n",
            '        "uses": attacker/execute@deadbeef\n        with:\n',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "checkout step changed"):
            self._validate_source(source)

    def test_bare_sequence_step_before_source_trust_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "    steps:\n",
            "    steps:\n      -\n        run: echo bypass\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "non-canonical step item"):
            self._validate_source(source)

    def test_dispatch_ref_must_be_bound_to_github_context(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "          DISPATCH_REF: ${{ github.ref }}\n",
            "          DISPATCH_REF: refs/heads/main\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_release_environment_must_be_bound_to_dispatch_input(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "          RELEASE_ENVIRONMENT: ${{ inputs.environment }}\n",
            "          RELEASE_ENVIRONMENT: staging\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_runtime_environment_allowlist_cannot_be_weakened(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            'if [[ "$RELEASE_ENVIRONMENT" != "staging" && "$RELEASE_ENVIRONMENT" != "production" ]]; then',
            'if [[ -z "$RELEASE_ENVIRONMENT" ]]; then',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_non_main_guard_cannot_be_short_circuited(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            '          true || if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_non_main_guard_cannot_be_commented_out(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            '          # if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_source_ancestry_bypass_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "git merge-base --is-ancestor", "git merge-base --is-shallow-repository", 1
        )
        with self.assertRaisesRegex(RuntimeError, "source trust step changed"):
            self._validate_source(source)

    def test_optional_source_revision_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "      source_revision:\n"
            "        description: Reviewed full commit SHA reachable from main\n"
            "        required: true\n"
            "        type: string",
            "      source_revision:\n"
            "        description: Reviewed full commit SHA reachable from main\n"
            "        required: false\n"
            "        type: string",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "dispatch schema"):
            self._validate_source(source)

    def test_mutable_tag_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "printf 'backend_tag=%s:sha-%s", "printf 'backend_tag=%s:latest", 1
        )
        with self.assertRaisesRegex(RuntimeError, "missing: printf 'backend_tag"):
            self._validate_source(source)

    def test_flutter_identity_gate_removal_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: python3 scripts/validate"):
            self._validate_source(source)

    def test_permission_expansion_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "  packages: write\n", "  packages: write\n  actions: write\n", 1
        )
        with self.assertRaisesRegex(RuntimeError, "not least privilege"):
            self._validate_source(source)

    def test_uncaptured_push_digest_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            'docker push "$BACKEND_TAG" 2>&1 | tee "$backend_push_log"',
            'docker push "$BACKEND_TAG" > /dev/null',
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: docker push"):
            self._validate_source(source)

    def test_ambiguous_push_digest_acceptance_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "if len(matches) != 1:",
            "if not matches:",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: if len"):
            self._validate_source(source)

    def test_unbound_handoff_digest_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "BACKEND_DIGEST: ${{ steps.publish.outputs.backend_digest }}",
            "BACKEND_DIGEST: sha256:${{ steps.release.outputs.source_revision }}",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: BACKEND_DIGEST"):
            self._validate_source(source)

    def test_local_repo_digest_fallback_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            '          if ! [[ "$BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \\\n',
            '          docker image inspect "$BACKEND_REPOSITORY"\n'
            '          if ! [[ "$BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \\\n',
            1,
        )
        with self.assertRaisesRegex(
            RuntimeError, "local.*bypass|trust/publication bypass"
        ):
            self._validate_source(source)

    def test_missing_publication_artifact_is_not_a_warning(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "if-no-files-found: error", "if-no-files-found: warn", 1
        )
        with self.assertRaisesRegex(RuntimeError, "missing: if-no-files-found: error"):
            self._validate_source(source)

    def test_publication_evidence_checksum_removal_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "(cd release/image-publication && sha256sum -- * >SHA256SUMS)",
            "touch release/image-publication/SHA256SUMS",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: .*sha256sum"):
            self._validate_source(source)


if __name__ == "__main__":
    unittest.main()
