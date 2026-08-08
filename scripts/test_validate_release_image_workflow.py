#!/usr/bin/env python3
"""Tamper regressions for the three-runner release-image trust boundary."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_release_image_workflow as validator


SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")


class ReleaseImageWorkflowTests(unittest.TestCase):
    def validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "release-images.yml"
            path.write_text(source, encoding="utf-8")
            validator.validate(path)

    def assert_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SOURCE)
        with self.assertRaises(RuntimeError):
            self.validate_source(SOURCE.replace(original, replacement, 1))

    def test_checked_in_workflow_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_fails(self) -> None:
        self.assert_tamper_rejected(
            "  workflow_dispatch:\n",
            "  workflow_dispatch:\n  repository_dispatch:\n",
        )

    def test_dispatch_environment_cannot_be_widened(self) -> None:
        self.assert_tamper_rejected(
            "        type: choice\n        options: [staging, production]",
            "        type: string",
        )

    def test_workflow_token_permissions_must_stay_closed(self) -> None:
        self.assert_tamper_rejected("permissions: {}\n", "permissions:\n  contents: read\n")

    def test_cancelling_concurrency_fails(self) -> None:
        self.assert_tamper_rejected("  cancel-in-progress: false\n", "  cancel-in-progress: true\n")

    def test_three_exact_jobs_are_required(self) -> None:
        self.assert_tamper_rejected("  scan:\n", "  inspect:\n")

    def test_sibling_job_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            self.validate_source(
                SOURCE
                + "\n  bypass:\n"
                + "    runs-on: ubuntu-24.04\n"
                + "    steps:\n"
                + "      - run: echo bypass\n"
            )

    def test_mutable_checkout_action_fails(self) -> None:
        self.assert_tamper_rejected(validator.CHECKOUT_ACTION, "actions/checkout@v7")

    def test_checkout_credentials_cannot_persist(self) -> None:
        self.assert_tamper_rejected(
            "          persist-credentials: false\n",
            "          persist-credentials: true\n",
        )

    def test_source_main_guard_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then\n',
            '          if [[ -z "$DISPATCH_REF" ]]; then\n',
        )

    def test_source_ancestry_guard_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '          if ! git merge-base --is-ancestor "$source_revision" origin/main; then\n',
            '          if ! git merge-base --is-shallow-repository; then\n',
        )

    def test_build_cannot_receive_packages_write(self) -> None:
        self.assert_tamper_rejected(
            "    permissions:\n      contents: read\n    env:\n",
            "    permissions:\n      contents: read\n      packages: write\n    env:\n",
        )

    def test_build_cannot_use_protected_environment(self) -> None:
        self.assert_tamper_rejected(
            "  build:\n    runs-on: ubuntu-24.04\n",
            "  build:\n    environment: ${{ inputs.environment }}\n    runs-on: ubuntu-24.04\n",
        )

    def test_build_cannot_run_trivy(self) -> None:
        build = validator._job_block(SOURCE, "build")
        tampered = build.replace(
            "      - name: Upload immutable untrusted build handoff\n",
            f"      - uses: {validator.TRIVY_ACTION}\n\n"
            "      - name: Upload immutable untrusted build handoff\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "fresh scan"):
            validator._validate_build_contract(tampered)

    def test_build_handoff_is_explicitly_untrusted(self) -> None:
        self.assert_tamper_rejected(
            '"classification": "untrusted release image build handoff",\n',
            '"classification": "trusted scanned handoff",\n',
        )

    def test_build_upload_must_expose_immutable_artifact_id(self) -> None:
        self.assert_tamper_rejected(
            "      build_artifact_id: ${{ steps.build-upload.outputs.artifact-id }}\n",
            "      build_artifact_id: release-image-build\n",
        )

    def test_build_artifact_is_uncompressed_and_short_lived(self) -> None:
        build = validator._job_block(SOURCE, "build")
        self.assertIn("compression-level: 0", build)
        self.assertIn("retention-days: 1", build)
        self.assert_tamper_rejected(
            "          name: release-image-build-${{ inputs.environment }}-",
            "          name: mutable-release-image-build-",
        )

    def test_scan_must_need_build(self) -> None:
        self.assert_tamper_rejected("  scan:\n    needs: build\n", "  scan:\n")

    def test_scan_has_zero_token_permissions(self) -> None:
        self.assert_tamper_rejected(
            "    timeout-minutes: 60\n    permissions: {}\n",
            "    timeout-minutes: 60\n    permissions:\n      contents: read\n",
        )

    def test_scan_cannot_use_protected_environment(self) -> None:
        self.assert_tamper_rejected(
            "  scan:\n    needs: build\n",
            "  scan:\n    environment: ${{ inputs.environment }}\n    needs: build\n",
        )

    def test_scan_download_must_use_build_artifact_id(self) -> None:
        self.assert_tamper_rejected(
            "          artifact-ids: ${{ needs.build.outputs.build_artifact_id }}\n",
            "          name: release-image-build-staging\n",
        )

    def test_scan_download_digest_mismatch_must_fail(self) -> None:
        first = SOURCE.index("          digest-mismatch: error\n")
        tampered = SOURCE[:first] + SOURCE[first:].replace(
            "          digest-mismatch: error\n",
            "          digest-mismatch: warn\n",
            1,
        )
        with self.assertRaises(RuntimeError):
            self.validate_source(tampered)

    def test_candidate_checkout_is_rejected_in_scan(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        marker = "    steps:\n"
        tampered = scan.replace(marker, marker + f"      - uses: {validator.CHECKOUT_ACTION}\n", 1)
        with self.assertRaisesRegex(RuntimeError, "candidate code"):
            validator._validate_scan_execution_boundary(tampered)

    def test_candidate_script_is_rejected_in_scan(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        marker = "          /usr/bin/python3 -I - \\\n"
        self.assertIn(marker, scan)
        tampered = scan.replace(marker, "          /usr/bin/python3 scripts/hook.py\n" + marker, 1)
        with self.assertRaisesRegex(RuntimeError, "candidate code"):
            validator._validate_scan_execution_boundary(tampered)

    def test_background_process_is_rejected_in_scan(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        marker = "          /usr/bin/python3 -I - \\\n"
        tampered = scan.replace(marker, "          /usr/bin/python3 -I - </dev/null &\n" + marker, 1)
        with self.assertRaisesRegex(RuntimeError, "background process"):
            validator._validate_scan_execution_boundary(tampered)

    def test_github_environment_poisoning_is_rejected_in_scan(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        marker = "          /usr/bin/python3 -I - \\\n"
        tampered = scan.replace(marker, '          echo "PATH=/candidate" >>"$GITHUB_ENV"\n' + marker, 1)
        with self.assertRaisesRegex(RuntimeError, "command files"):
            validator._validate_scan_execution_boundary(tampered)

    def test_scan_validation_rejects_extra_file_surface(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        tampered = scan.replace(
            "          if {entry.name for entry in os.scandir(root)} != expected_files:\n",
            "          if not any(os.scandir(root)):\n",
            1,
        )
        with self.assertRaises(RuntimeError):
            validator._validate_scan_contract(tampered)

    def test_scan_validation_requires_canonical_duplicate_safe_json(self) -> None:
        self.assert_tamper_rejected("              object_pairs_hook=reject_pairs,\n", "")
        self.assert_tamper_rejected("          if raw != canonical or not isinstance(payload, dict):\n", "")

    def test_scan_must_load_and_derive_archive_identity(self) -> None:
        self.assert_tamper_rejected(
            '["/usr/bin/docker", "load", "--input", str(root / archive_name)],\n',
            '["/usr/bin/docker", "pull", expected_tag],\n',
        )
        self.assert_tamper_rejected(
            '              if image_id != image["image_id"] or re.fullmatch',
            '              if re.fullmatch',
        )

    def test_all_trivy_operations_consume_downloaded_archives(self) -> None:
        scan = validator._job_block(SOURCE, "scan")
        self.assertEqual(
            scan.count("input: ${{ runner.temp }}/release-image-build-handoff/backend-image.tar"),
            2,
        )
        self.assertEqual(
            scan.count("input: ${{ runner.temp }}/release-image-build-handoff/site-image.tar"),
            2,
        )
        self.assertNotIn("image-ref:", scan)

    def test_archive_post_scan_digest_check_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "              backend_archive_sha256 != expected_backend_archive_sha256\n",
            "              False\n",
        )

    def test_scanned_manifest_binds_build_artifact(self) -> None:
        self.assert_tamper_rejected('                  "artifact_id": build_artifact_id,\n', "")
        self.assert_tamper_rejected('                  "artifact_digest": build_artifact_digest,\n', "")
        self.assert_tamper_rejected('                  "manifest_sha256": build_manifest_sha256,\n', "")

    def test_scan_handoff_upload_is_immutable_and_bounded(self) -> None:
        self.assert_tamper_rejected(
            "          path: ${{ runner.temp }}/release-image-handoff\n",
            "          path: ${{ github.workspace }}\n",
        )

    def test_publish_must_need_scan(self) -> None:
        self.assert_tamper_rejected("  publish:\n    needs: scan\n", "  publish:\n    needs: build\n")

    def test_publish_is_only_packages_writer_and_is_protected(self) -> None:
        self.assertEqual(SOURCE.count("packages: write"), 1)
        self.assertIn("environment: ${{ inputs.environment }}", validator._job_block(SOURCE, "publish"))

    def test_publish_download_must_use_scan_artifact_id(self) -> None:
        self.assert_tamper_rejected(
            "          artifact-ids: ${{ needs.scan.outputs.handoff_artifact_id }}\n",
            "          name: release-image-handoff-staging\n",
        )

    def test_candidate_checkout_is_rejected_in_publish(self) -> None:
        publish = validator._job_block(SOURCE, "publish")
        tampered = publish.replace(
            "    steps:\n",
            "    steps:\n" + f"      - uses: {validator.CHECKOUT_ACTION}\n",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "candidate code"):
            validator._validate_publish_execution_boundary(tampered)

    def test_background_process_is_rejected_in_publish(self) -> None:
        publish = validator._job_block(SOURCE, "publish")
        marker = '          registry_owner="$(printf \'%s\' "$REGISTRY_OWNER"'
        tampered = publish.replace(
            marker,
            "          /usr/bin/python3 -I - </dev/null &\n" + marker,
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "background process"):
            validator._validate_publish_execution_boundary(tampered)

    def test_registry_secret_cannot_bind_before_push(self) -> None:
        publish = validator._job_block(SOURCE, "publish")
        marker = "          HANDOFF_DIR: ${{ runner.temp }}/release-image-handoff\n"
        tampered = publish.replace(
            marker,
            "          TOKEN_ALIAS: ${{ secrets.GITHUB_TOKEN }}\n" + marker,
            1,
        )
        with self.assertRaises(RuntimeError):
            validator._validate_publish_execution_boundary(tampered)

    def test_publish_validates_external_build_provenance_binding(self) -> None:
        for fragment in (
            "          EXPECTED_BUILD_ARTIFACT_ID: ${{ needs.scan.outputs.build_artifact_id }}\n",
            "          EXPECTED_BUILD_ARTIFACT_DIGEST: ${{ needs.scan.outputs.build_artifact_digest }}\n",
            "          EXPECTED_BUILD_MANIFEST_SHA256: ${{ needs.scan.outputs.build_manifest_sha256 }}\n",
        ):
            self.assert_tamper_rejected(fragment, "")

    def test_loaded_image_identity_check_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '              if binding["tag"] != tag or binding["image_id"] != image_id:\n',
            '              if binding["tag"] != tag:\n',
        )

    def test_images_load_before_registry_secret_binding(self) -> None:
        publish = validator._job_block(SOURCE, "publish")
        self.assertLess(publish.index("/usr/bin/docker load"), publish.index("${{ secrets.GITHUB_TOKEN }}"))

    def test_only_exact_loaded_tags_are_pushed(self) -> None:
        self.assert_tamper_rejected(
            '          /usr/bin/docker push "$backend_tag" 2>&1 | /usr/bin/tee "$backend_push_log"\n',
            '          /usr/bin/docker push "ghcr.io/example/pakperk-backend:latest"\n',
        )

    def test_ambiguous_push_digest_acceptance_fails(self) -> None:
        self.assert_tamper_rejected("              if len(matches) != 1:\n", "              if not matches:\n")

    def test_promotion_binds_scanned_artifact_not_build_job(self) -> None:
        self.assertIn('"scan_handoff": {', SOURCE)
        self.assertNotIn("needs.build_scan", SOURCE)
        self.assert_tamper_rejected(
            '                  "manifest_sha256": hashlib.sha256(scanned_manifest).hexdigest(),\n',
            "",
        )

    def test_publication_retains_untrusted_build_manifest_and_checksums(self) -> None:
        publish = validator._job_block(SOURCE, "publish")
        self.assertIn("untrusted-build-handoff.json", publish)
        self.assertIn('/usr/bin/sha256sum -- * >SHA256SUMS', publish)

    def test_publish_bash_startup_file_is_pinned_closed(self) -> None:
        self.assert_tamper_rejected(
            "      BASH_ENV: /dev/null\n",
            "      BASH_ENV: ${{ runner.temp }}/candidate-hook\n",
        )


if __name__ == "__main__":
    unittest.main()
