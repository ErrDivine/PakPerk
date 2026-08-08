#!/usr/bin/env python3
"""Adversarial tests for the verified mobile-store upload handoff."""

from __future__ import annotations

import json
import hashlib
import pathlib
import shutil
import tempfile
import unittest

import generate_mobile_store_upload_handoff as generator
import test_validate_mobile_store_candidate as candidate_fixtures
import validate_mobile_store_candidate as validator


def write_canonical(path: pathlib.Path, value: object) -> None:
    path.write_bytes(validator.canonical_json_bytes(value))


class StoreUploadHandoffTests(unittest.TestCase):
    def prepare(self, root: pathlib.Path) -> tuple[candidate_fixtures.Fixture, pathlib.Path, pathlib.Path]:
        fixture = candidate_fixtures.Fixture(root)
        google = root / "google.json"
        apple = root / "apple.json"
        write_canonical(
            google,
            {
                "application_id": validator.PRODUCTION_APPLICATION_ID,
                "bundle": {
                    "sha256": candidate_fixtures.ANDROID_AAB_SHA256,
                    "version_code": candidate_fixtures.BUILD_NUMBER,
                },
                "internal_target": {
                    "status": "completed",
                    "user_fraction": None,
                    "version_codes": [candidate_fixtures.BUILD_NUMBER],
                },
                "schema": 1,
                "verification_status": "succeeded_verified",
                "version_code": candidate_fixtures.BUILD_NUMBER,
            },
        )
        write_canonical(
            apple,
            {
                "app_version": candidate_fixtures.APP_VERSION,
                "application_id": validator.PRODUCTION_APPLICATION_ID,
                "build_number": candidate_fixtures.BUILD_NUMBER,
                "operation": "verify-build",
                "schema": 1,
                "upload_verification": {
                    "app_id": "app-1",
                    "build": {
                        "build_id": "build-42",
                        "build_number": candidate_fixtures.BUILD_NUMBER,
                        "pre_release_version_id": "pre-1",
                        "processing_state": "VALID",
                    },
                    "build_upload": {
                        "asset_file": {
                            "asset_delivery_state": "COMPLETE",
                            "asset_type": "ASSET",
                            "build_upload_file_id": "upload-file-1",
                            "file_size": len(candidate_fixtures.IOS_IPA_BYTES),
                            "source_file_checksum": {
                                "algorithm": "SHA_256",
                                "hash": candidate_fixtures.IOS_IPA_SHA256,
                            },
                            "uti": "com.apple.ipa",
                        },
                        "build_id": "build-42",
                        "build_upload_id": "build-upload-1",
                        "state": "COMPLETE",
                    },
                },
                "verification_status": "succeeded_verified",
            },
        )
        return fixture, google, apple

    def generate(
        self,
        root: pathlib.Path,
        fixture: candidate_fixtures.Fixture,
        google: pathlib.Path,
        apple: pathlib.Path,
        tooling_root: pathlib.Path | None = None,
    ) -> tuple[str, pathlib.Path]:
        output = root / "generated-handoff"
        identifier = generator.generate(
            candidate_path=fixture.candidate_path,
            provenance_path=fixture.provenance_path,
            google_verification_path=google,
            apple_verification_path=apple,
            output_root=output,
            candidate_id=fixture.candidate_id,
            provenance_id=fixture.provenance_id,
            source_revision=candidate_fixtures.SOURCE_REVISION,
            app_version=candidate_fixtures.APP_VERSION,
            build_number=candidate_fixtures.BUILD_NUMBER,
            repository=validator.REPOSITORY,
            run_id=candidate_fixtures.SIGNED_RELEASE_RUN_ID,
            run_attempt="2",
            ruby_version="3.4.10",
            rubygems_version="4.0.17",
            bundler_version="2.6.9",
            tooling_root=tooling_root,
        )
        return identifier, output

    def test_verified_readbacks_create_a_validator_accepted_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            identifier, output = self.generate(root, fixture, google, apple)
            validator.validate_store_candidate(
                fixture.candidate_path,
                fixture.provenance_path,
                fixture.artifact_root,
                output / "mobile-store-upload-handoff.json",
                output / "mobile-store-upload-handoff.sha256",
                fixture.run_verification_path,
                candidate_id=fixture.candidate_id,
                provenance_id=fixture.provenance_id,
                source_revision=candidate_fixtures.SOURCE_REVISION,
                app_version=candidate_fixtures.APP_VERSION,
                build_number=candidate_fixtures.BUILD_NUMBER,
                signed_release_run_id=candidate_fixtures.SIGNED_RELEASE_RUN_ID,
                signed_release_run_attempt=candidate_fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
                store_handoff_id=identifier,
            )

    def test_play_readback_must_be_succeeded_verified(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            value = json.loads(google.read_text(encoding="utf-8"))
            value["verification_status"] = "unknown_reconcile_required"
            write_canonical(google, value)
            with self.assertRaisesRegex(generator.HandoffError, "authoritatively verified"):
                self.generate(root, fixture, google, apple)

    def test_play_readback_must_bind_the_exact_candidate_bundle_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            value = json.loads(google.read_text(encoding="utf-8"))
            value["bundle"]["sha256"] = "0" * 64
            write_canonical(google, value)
            with self.assertRaisesRegex(generator.HandoffError, "authoritatively verified"):
                self.generate(root, fixture, google, apple)

    def test_apple_readback_must_bind_exact_version_and_processed_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            value = json.loads(apple.read_text(encoding="utf-8"))
            value["upload_verification"]["build"]["processing_state"] = "PROCESSING"
            write_canonical(apple, value)
            with self.assertRaisesRegex(generator.HandoffError, "authoritatively verified"):
                self.generate(root, fixture, google, apple)

    def test_apple_readback_closes_and_retains_remote_app_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            value = json.loads(apple.read_text(encoding="utf-8"))
            value["upload_verification"]["unexpected"] = "other-app"
            write_canonical(apple, value)
            with self.assertRaisesRegex(generator.HandoffError, "closed key contract"):
                self.generate(root, fixture, google, apple)

    def test_apple_readback_must_bind_candidate_ipa_checksum_and_size(self) -> None:
        mutations = (
            ("source_file_checksum", {"algorithm": "SHA_256", "hash": "0" * 64}),
            ("file_size", 0),
            ("uti", "com.apple.pkg"),
        )
        for key, replacement in mutations:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                fixture, google, apple = self.prepare(root)
                value = json.loads(apple.read_text(encoding="utf-8"))
                value["upload_verification"]["build_upload"]["asset_file"][
                    key
                ] = replacement
                write_canonical(apple, value)
                with self.assertRaisesRegex(
                    generator.HandoffError, "authoritatively verified"
                ):
                    self.generate(root, fixture, google, apple)

    def test_apple_readback_must_link_build_upload_to_verified_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            value = json.loads(apple.read_text(encoding="utf-8"))
            value["upload_verification"]["build_upload"]["build_id"] = "other-build"
            write_canonical(apple, value)
            with self.assertRaisesRegex(generator.HandoffError, "authoritatively verified"):
                self.generate(root, fixture, google, apple)

    def test_handoff_output_is_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            self.generate(root, fixture, google, apple)
            with self.assertRaises(FileExistsError):
                self.generate(root, fixture, google, apple)

    def test_downloaded_tooling_root_is_the_only_hashed_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture, google, apple = self.prepare(root)
            controls = root / "controls"
            controls.mkdir()
            repository_root = pathlib.Path(__file__).resolve().parents[1]
            sources = {
                "manage_app_store_phased_release.rb": repository_root
                / "scripts/manage_app_store_phased_release.rb",
                "Gemfile.lock": repository_root / "mobile/Gemfile.lock",
                "manage_google_play_rollout.rb": repository_root
                / "scripts/manage_google_play_rollout.rb",
                "generate_mobile_store_upload_handoff.py": repository_root
                / "scripts/generate_mobile_store_upload_handoff.py",
            }
            for name, source in sources.items():
                shutil.copyfile(source, controls / name)
            _, output = self.generate(
                root, fixture, google, apple, tooling_root=controls
            )
            handoff = json.loads(
                (output / "mobile-store-upload-handoff.json").read_text()
            )
            expected = {
                "app_store_client_sha256": hashlib.sha256(
                    (controls / "manage_app_store_phased_release.rb").read_bytes()
                ).hexdigest(),
                "fastlane_lock_sha256": hashlib.sha256(
                    (controls / "Gemfile.lock").read_bytes()
                ).hexdigest(),
                "google_play_client_sha256": hashlib.sha256(
                    (controls / "manage_google_play_rollout.rb").read_bytes()
                ).hexdigest(),
                "handoff_generator_sha256": hashlib.sha256(
                    (controls / "generate_mobile_store_upload_handoff.py").read_bytes()
                ).hexdigest(),
            }
            for key, digest in expected.items():
                self.assertEqual(digest, handoff["tooling"][key])


if __name__ == "__main__":
    unittest.main()
