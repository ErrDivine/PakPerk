#!/usr/bin/env python3
"""Adversarial tests for credential-free signed-candidate aggregation."""

from __future__ import annotations

import hashlib
import json
import pathlib
import tempfile
import types
import unittest

import assemble_mobile_signed_candidate as assembler


SOURCE = "a" * 40
FINGERPRINT = ":".join(["AB"] * 32)


class Fixture:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root.resolve()
        self.prepared = self._directory("prepared")
        self.android = self._directory("android")
        self.ios = self._directory("ios")
        self.output = self.root / "candidate"
        self.github_output = self.root / "github-output"
        self.summary = self.root / "summary"
        self.github_output.write_text("", encoding="utf-8")
        self.summary.write_text("", encoding="utf-8")

        self._write(
            self.prepared / "mobile-release-config.json",
            json.dumps(
                {
                    "PAKPERK_ENV": "production",
                    "PAKPERK_FULLTEXT_POLICY": "strict",
                },
                sort_keys=True,
            ).encode()
            + b"\n",
        )
        self._write(
            self.prepared / "evidence/mobile-feature-flags.json",
            b'{"schema":2}\n',
        )
        self.config_sha256 = self._digest(
            self.prepared / "mobile-release-config.json"
        )
        self.feature_sha256 = self._digest(
            self.prepared / "evidence/mobile-feature-flags.json"
        )
        boundary = {
            "artifactDigest": "1" * 64,
            "artifactId": 101,
            "configSha256": self.config_sha256,
            "featureEvidenceSha256": self.feature_sha256,
            "schema": 1,
        }

        self._write(self.android / "artifacts/app-prod-release.aab", b"aab")
        self._write(self.android / "artifacts/app-prod-release.apk", b"apk")
        aab = self._digest(self.android / "artifacts/app-prod-release.aab")
        apk = self._digest(self.android / "artifacts/app-prod-release.apk")
        self._write(
            self.android / "evidence/android-upload-identity.txt",
            (
                "android_package=app.pakperk.pakperk\n"
                "android_version_name=0.2.0\n"
                "android_version_code=9\n"
                f"android_upload_sha256={FINGERPRINT}\n"
            ).encode(),
        )
        self._write(
            self.android / "evidence/android-retained-digests.txt",
            (
                f"android_aab_artifact_sha256={aab}\n"
                f"android_apk_artifact_sha256={apk}\n"
            ).encode(),
        )
        self._write(
            self.android / "evidence/android-prepared-config-boundary.json",
            assembler.canonical_json_bytes(boundary),
        )
        for name in (
            "android-flutter-toolchain.json",
            "android-native.cdx.json",
            "android-installed-identity.txt",
        ):
            self._write(self.android / "evidence" / name, b"evidence\n")
        self._write(self.android / "symbols/android-aab/symbols", b"symbol\n")

        self._write(self.ios / "artifacts/PakPerk.ipa", b"ipa")
        ipa = self._digest(self.ios / "artifacts/PakPerk.ipa")
        self._write(
            self.ios / "evidence/apple-installed-identity.txt",
            (
                "apple_bundle_id=app.pakperk.pakperk\n"
                "apple_version=0.2.0\n"
                "apple_build=9\n"
                f"apple_ipa_sha256={ipa}\n"
                f"apple_signer_sha256={'2' * 64}\n"
                "apple_team_id=ABCDEFGHIJ\n"
            ).encode(),
        )
        self._write(
            self.ios / "evidence/ios-retained-digest.txt",
            f"ios_ipa_artifact_sha256={ipa}\n".encode(),
        )
        self._write(
            self.ios / "evidence/ios-prepared-config-boundary.json",
            assembler.canonical_json_bytes(boundary),
        )
        for name in (
            "ios-flutter-toolchain.json",
            "ios-native-toolchain.txt",
        ):
            self._write(self.ios / "evidence" / name, b"evidence\n")
        self._write(self.ios / "symbols/ios/symbols", b"symbol\n")
        self._write(self.ios / "native-symbols/Runner.dSYM/data", b"symbol\n")

        self.arguments = types.SimpleNamespace(
            environment="production",
            source_revision=SOURCE,
            workflow_sha=SOURCE,
            app_version="0.2.0",
            android_version_name="0.2.0",
            build_number="9",
            application_id="app.pakperk.pakperk",
            repository=assembler.REPOSITORY,
            run_id="1234",
            run_attempt="1",
            prepared_artifact_id="101",
            prepared_artifact_digest="1" * 64,
            android_artifact_id="102",
            android_artifact_digest="2" * 64,
            ios_artifact_id="103",
            ios_artifact_digest="3" * 64,
            config_sha256=self.config_sha256,
            feature_evidence_sha256=self.feature_sha256,
            prepared_root=self.prepared,
            android_root=self.android,
            ios_root=self.ios,
            output_root=self.output,
            github_output=self.github_output,
            github_step_summary=self.summary,
        )

    def _directory(self, name: str) -> pathlib.Path:
        path = self.root / name
        path.mkdir(mode=0o700)
        return path

    @staticmethod
    def _write(path: pathlib.Path, raw: bytes) -> None:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(0o600)

    @staticmethod
    def _digest(path: pathlib.Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


class AssembleMobileSignedCandidateTests(unittest.TestCase):
    def fixture(self, directory: str) -> Fixture:
        return Fixture(pathlib.Path(directory))

    def test_checked_in_contract_assembles_and_revalidates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            candidate_id, provenance_id = assembler.assemble(fixture.arguments)
            assembler.verify(
                fixture.output,
                candidate_id=candidate_id,
                provenance_id=provenance_id,
            )
            candidate = json.loads(
                (fixture.output / "evidence/mobile-candidate.json").read_text()
            )
            self.assertTrue(candidate["strict_full_text"])
            self.assertEqual(
                candidate["android"]["aab_sha256"],
                hashlib.sha256(b"aab").hexdigest(),
            )

    def test_upstream_ids_and_raw_digests_are_canonical_and_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            assembler.assemble(fixture.arguments)
            binding_path = fixture.output / "evidence/mobile-signing-transfers.json"
            raw = binding_path.read_bytes()
            value = json.loads(raw)
            self.assertEqual(raw, assembler.canonical_json_bytes(value))
            self.assertEqual(value["prepared"]["artifact_id"], 101)
            self.assertEqual(value["android"]["artifact_digest"], "2" * 64)
            self.assertEqual(value["ios"]["artifact_digest"], "3" * 64)

    def test_duplicate_upstream_artifact_ids_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            fixture.arguments.ios_artifact_id = fixture.arguments.android_artifact_id
            with self.assertRaisesRegex(assembler.AssemblyError, "must be distinct"):
                assembler.assemble(fixture.arguments)

    def test_noncanonical_prepared_boundary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            path = fixture.android / "evidence/android-prepared-config-boundary.json"
            value = json.loads(path.read_text())
            path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(assembler.AssemblyError, "canonical binding"):
                assembler.assemble(fixture.arguments)

    def test_signer_raw_digest_disagreement_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            path = fixture.android / "evidence/android-retained-digests.txt"
            path.write_text(
                f"android_aab_artifact_sha256={'0' * 64}\n"
                f"android_apk_artifact_sha256={hashlib.sha256(b'apk').hexdigest()}\n",
                encoding="ascii",
            )
            with self.assertRaisesRegex(assembler.AssemblyError, "raw digest"):
                assembler.assemble(fixture.arguments)

    def test_unexpected_signer_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            Fixture._write(fixture.ios / "execute-me.py", b"raise SystemExit\n")
            with self.assertRaisesRegex(assembler.AssemblyError, "unexpected root"):
                assembler.assemble(fixture.arguments)

    def test_workflow_and_candidate_revision_must_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            fixture.arguments.workflow_sha = "b" * 40
            with self.assertRaisesRegex(assembler.AssemblyError, "does not equal"):
                assembler.assemble(fixture.arguments)

    def test_post_assembly_artifact_mutation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            candidate_id, provenance_id = assembler.assemble(fixture.arguments)
            artifact = fixture.output / "artifacts/app-prod-release.aab"
            artifact.chmod(0o600)
            artifact.write_bytes(b"tampered")
            artifact.chmod(0o400)
            with self.assertRaisesRegex(assembler.AssemblyError, "does not match"):
                assembler.verify(
                    fixture.output,
                    candidate_id=candidate_id,
                    provenance_id=provenance_id,
                )


if __name__ == "__main__":
    unittest.main()
