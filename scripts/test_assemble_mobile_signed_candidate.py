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
                    "PAKPERK_ACCOUNTS_ENABLED": "true",
                    "PAKPERK_LIBRARY_ENABLED": "true",
                    "PAKPERK_COMMENTS_ENABLED": "false",
                    "PAKPERK_PAPER_TITLE_SEARCH_ENABLED": "true",
                    "PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED": "true",
                    "PAKPERK_READING_FEED_ENABLED": "true",
                    "PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED": "true",
                    "PAKPERK_LIBRARY_V2_ENABLED": "true",
                    "PAKPERK_RECOMMENDATIONS_ENABLED": "true",
                    "PAKPERK_RECOMMENDATION_EVENTS_ENABLED": "true",
                    "PAKPERK_SEARCH_LOOKUP_ENABLED": "true",
                    "PAKPERK_SEARCH_EXPLORE_ENABLED": "true",
                    "PAKPERK_SAVED_QUERIES_ENABLED": "true",
                    "PAKPERK_RESEARCH_PROFILES_ENABLED": "true",
                    "PAKPERK_READING_BRIEFS_ENABLED": "true",
                    "PAKPERK_SUBSCRIPTIONS_ENABLED": "true",
                    "PAKPERK_NOTIFICATIONS_ENABLED": "true",
                    "PAKPERK_DEEP_READER_ENABLED": "true",
                    "PAKPERK_PAPER_PASSPORT_ENABLED": "true",
                    "PAKPERK_SEMANTIC_FACETS_ENABLED": "true",
                    "PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED": "true",
                    "PAKPERK_READING_CHECKPOINTS_ENABLED": "true",
                    "PAKPERK_ANNOTATIONS_ENABLED": "true",
                    "PAKPERK_EVIDENCE_CARDS_ENABLED": "true",
                    "PAKPERK_RESEARCH_MEMORY_ENABLED": "true",
                    "PAKPERK_VERSION_DIFF_ENABLED": "true",
                    "PAKPERK_ASSISTANT_V2_ENABLED": "true",
                    "PAKPERK_TERMS_DOCUMENT_VERSION": "2026-08-01",
                    "PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION": "2026-08-01",
                },
                sort_keys=True,
            ).encode()
            + b"\n",
        )
        self._write(
            self.prepared / "evidence/mobile-feature-flags.json",
            json.dumps(
                {
                    "schema": 6,
                    "environment": "production",
                    "accounts": True,
                    "library": True,
                    "comments": False,
                    "paperTitleSearch": True,
                    "libraryImportWrites": True,
                    "readingFeed": True,
                    "toReadFirstEnforcement": True,
                    "libraryV2": True,
                    "recommendations": True,
                    "recommendationEvents": True,
                    "searchLookup": True,
                    "searchExplore": True,
                    "savedQueries": True,
                    "researchProfiles": True,
                    "readingBriefs": True,
                    "subscriptions": True,
                    "notifications": True,
                    "deepReader": True,
                    "paperPassport": True,
                    "semanticFacets": True,
                    "documentVisualObjects": True,
                    "readingCheckpoints": True,
                    "annotations": True,
                    "evidenceCards": True,
                    "researchMemory": True,
                    "versionDiff": True,
                    "assistantV2": True,
                    "termsDocumentVersion": "2026-08-01",
                    "communityGuidelinesDocumentVersion": "2026-08-01",
                },
                indent=2,
                sort_keys=True,
            ).encode()
            + b"\n",
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

    def replace_feature_evidence(self, value: object) -> None:
        path = self.prepared / "evidence/mobile-feature-flags.json"
        self._write(path, json.dumps(value, indent=2, sort_keys=True).encode() + b"\n")
        self.feature_sha256 = self._digest(path)
        self.arguments.feature_evidence_sha256 = self.feature_sha256
        for root, platform in (
            (self.android, "android"),
            (self.ios, "ios"),
        ):
            boundary_path = (
                root / f"evidence/{platform}-prepared-config-boundary.json"
            )
            boundary = json.loads(boundary_path.read_text(encoding="utf-8"))
            boundary["featureEvidenceSha256"] = self.feature_sha256
            self._write(boundary_path, assembler.canonical_json_bytes(boundary))


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
            provenance = json.loads(
                (
                    fixture.output / "evidence/mobile-release-provenance.json"
                ).read_text()
            )
            self.assertTrue(candidate["strict_full_text"])
            self.assertEqual(candidate["schema"], 4)
            self.assertEqual(provenance["schema"], 4)
            expected_feature_binding = {
                "schema": 6,
                "sha256": fixture.feature_sha256,
                "paperTitleSearch": True,
                "libraryImportWrites": True,
                "readingFeed": True,
                "toReadFirstEnforcement": True,
                "libraryV2": True,
                "recommendations": True,
                "recommendationEvents": True,
                "searchLookup": True,
                "searchExplore": True,
                "savedQueries": True,
                "researchProfiles": True,
                "readingBriefs": True,
                "subscriptions": True,
                "notifications": True,
                "deepReader": True,
                "paperPassport": True,
                "semanticFacets": True,
                "documentVisualObjects": True,
                "readingCheckpoints": True,
                "annotations": True,
                "evidenceCards": True,
                "researchMemory": True,
                "versionDiff": True,
                "assistantV2": True,
            }
            self.assertEqual(
                candidate["mobile_feature_evidence"], expected_feature_binding
            )
            self.assertEqual(
                provenance["mobile_feature_evidence"], expected_feature_binding
            )
            self.assertEqual(
                candidate["android"]["aab_sha256"],
                hashlib.sha256(b"aab").hexdigest(),
            )

    def test_feature_evidence_schema_downgrade_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            path = fixture.prepared / "evidence/mobile-feature-flags.json"
            value = json.loads(path.read_text(encoding="utf-8"))
            value["schema"] = 5
            fixture.replace_feature_evidence(value)
            with self.assertRaisesRegex(assembler.AssemblyError, "exactly 6"):
                assembler.assemble(fixture.arguments)

    def test_each_bound_feature_flag_must_derive_from_prepared_config(self) -> None:
        for key in assembler.MOBILE_FEATURE_BINDING_KEYS:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = self.fixture(directory)
                path = fixture.prepared / "evidence/mobile-feature-flags.json"
                value = json.loads(path.read_text(encoding="utf-8"))
                value[key] = not value[key]
                fixture.replace_feature_evidence(value)
                with self.assertRaisesRegex(assembler.AssemblyError, "derive from config"):
                    assembler.assemble(fixture.arguments)

    def test_feature_evidence_flags_require_exact_booleans(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            path = fixture.prepared / "evidence/mobile-feature-flags.json"
            value = json.loads(path.read_text(encoding="utf-8"))
            value["readingFeed"] = 1
            fixture.replace_feature_evidence(value)
            with self.assertRaisesRegex(assembler.AssemblyError, "exact booleans"):
                assembler.assemble(fixture.arguments)

    def test_every_mobile_feature_dependency_is_fail_closed(self) -> None:
        for feature, _dependencies in assembler.MOBILE_FEATURE_DEPENDENCIES:
            with self.subTest(feature=feature), tempfile.TemporaryDirectory() as directory:
                fixture = self.fixture(directory)
                config = json.loads(
                    (fixture.prepared / "mobile-release-config.json").read_text(
                        encoding="utf-8"
                    )
                )
                evidence = json.loads(
                    (
                        fixture.prepared / "evidence/mobile-feature-flags.json"
                    ).read_text(encoding="utf-8")
                )
                for evidence_key, config_key in assembler.MOBILE_FEATURE_CONFIG_KEYS.items():
                    config[config_key] = "false"
                    evidence[evidence_key] = False
                config_key = assembler.MOBILE_FEATURE_CONFIG_KEYS[feature]
                config[config_key] = "true"
                evidence[feature] = True
                with self.assertRaisesRegex(
                    assembler.AssemblyError, "dependency graph"
                ):
                    assembler._mobile_feature_evidence_binding(
                        evidence=evidence,
                        config=config,
                        environment="production",
                        feature_sha256="1" * 64,
                    )

    def test_feature_evidence_byte_tamper_is_rejected_by_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            path = fixture.prepared / "evidence/mobile-feature-flags.json"
            path.write_bytes(path.read_bytes() + b" ")
            with self.assertRaisesRegex(assembler.AssemblyError, "digest does not match"):
                assembler.assemble(fixture.arguments)

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
