#!/usr/bin/env python3
"""Regressions for pre-send mobile store upload attempt journals."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import generate_mobile_store_upload_attempt as generator
import test_validate_mobile_store_candidate as fixtures
import validate_mobile_store_candidate as validator


class StoreUploadAttemptTests(unittest.TestCase):
    def generate(
        self,
        root: pathlib.Path,
        fixture: fixtures.Fixture,
        *,
        platform: str = "android",
        candidate_id: str | None = None,
    ) -> dict[str, object]:
        output_root = root / "attempt"
        output_root.mkdir(mode=0o700)
        artifact = fixture.artifact_paths[".aab" if platform == "android" else ".ipa"]
        return generator.generate(
            candidate_path=fixture.candidate_path,
            artifact_path=artifact,
            output_path=output_root / f"{platform}-upload-attempt.json",
            platform=platform,
            candidate_id=fixture.candidate_id if candidate_id is None else candidate_id,
            provenance_id=fixture.provenance_id,
            source_revision=fixtures.SOURCE_REVISION,
            app_version=fixtures.APP_VERSION,
            build_number=fixtures.BUILD_NUMBER,
            repository=validator.REPOSITORY,
            run_id=fixtures.SIGNED_RELEASE_RUN_ID,
            run_attempt=fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
        )

    def test_android_journal_binds_exact_candidate_bundle_before_send(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.Fixture(root)
            journal = self.generate(root, fixture)
            self.assertEqual(fixtures.ANDROID_AAB_SHA256, journal["artifact_sha256"])
            self.assertEqual(len(fixtures.ANDROID_AAB_BYTES), journal["artifact_size"])
            self.assertEqual("google_play_internal", journal["destination"])
            path = root / "attempt/android-upload-attempt.json"
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertEqual(
                validator.canonical_json_bytes(journal), path.read_bytes()
            )

    def test_ios_journal_binds_exact_candidate_archive_before_send(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.Fixture(root)
            journal = self.generate(root, fixture, platform="ios")
            self.assertEqual(fixtures.IOS_IPA_SHA256, journal["artifact_sha256"])
            self.assertEqual(len(fixtures.IOS_IPA_BYTES), journal["artifact_size"])
            self.assertEqual("app_store_connect", journal["destination"])

    def test_wrong_candidate_content_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.Fixture(root)
            with self.assertRaisesRegex(generator.UploadAttemptError, "content ID"):
                self.generate(root, fixture, candidate_id="sha256:" + "0" * 64)

    def test_changed_upload_bytes_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.Fixture(root)
            fixture.artifact_paths[".aab"].write_bytes(b"different signed bundle")
            with self.assertRaisesRegex(generator.UploadAttemptError, "digest"):
                self.generate(root, fixture)

    def test_output_is_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.Fixture(root)
            self.generate(root, fixture)
            with self.assertRaisesRegex(generator.UploadAttemptError, "already exists"):
                generator.generate(
                    candidate_path=fixture.candidate_path,
                    artifact_path=fixture.artifact_paths[".aab"],
                    output_path=root / "attempt/android-upload-attempt.json",
                    platform="android",
                    candidate_id=fixture.candidate_id,
                    provenance_id=fixture.provenance_id,
                    source_revision=fixtures.SOURCE_REVISION,
                    app_version=fixtures.APP_VERSION,
                    build_number=fixtures.BUILD_NUMBER,
                    repository=validator.REPOSITORY,
                    run_id=fixtures.SIGNED_RELEASE_RUN_ID,
                    run_attempt=fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
                )


if __name__ == "__main__":
    unittest.main()
