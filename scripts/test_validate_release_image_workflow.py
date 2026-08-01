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

    def test_unprotected_branch_dispatch_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "    if: github.ref == 'refs/heads/main'\n", "", 1
        )
        with self.assertRaisesRegex(RuntimeError, "missing: if: github.ref"):
            self._validate_source(source)

    def test_source_ancestry_bypass_fails(self) -> None:
        source = validator.WORKFLOW.read_text(encoding="utf-8").replace(
            "git merge-base --is-ancestor", "git merge-base --is-shallow-repository", 1
        )
        with self.assertRaisesRegex(RuntimeError, "missing: .*git merge-base"):
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
        with self.assertRaisesRegex(RuntimeError, "missing:       source_revision"):
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
            "          if ! [[ \"$BACKEND_DIGEST\" =~ ^sha256:[0-9a-f]{64}$ ]] || \\\n",
            "          docker image inspect \"$BACKEND_REPOSITORY\"\n"
            "          if ! [[ \"$BACKEND_DIGEST\" =~ ^sha256:[0-9a-f]{64}$ ]] || \\\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "local.*bypass|trust/publication bypass"):
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
