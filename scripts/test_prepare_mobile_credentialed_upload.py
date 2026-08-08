#!/usr/bin/env python3
"""Adversarial tests for the credential-boundary rollout preparation helper."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import prepare_mobile_credentialed_upload as preparation


SCRIPT = pathlib.Path(preparation.__file__).resolve()


class CredentialedUploadPreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.candidate_root = self.base / "candidate"
        (self.candidate_root / "evidence").mkdir(parents=True)
        self.archive = self.base / "store-client.tar.gz"
        self.archive.write_bytes(b"reviewed store client archive")
        self.output = self.base / "github-output"
        self.source_revision = "a" * 40
        self.candidate = self._manifest()
        self.provenance = self._manifest()
        self._write_candidate_manifests()
        self._write_checksum_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _manifest(self) -> dict[str, object]:
        return {
            "android": {"application_id": "app.pakperk.pakperk"},
            "app_version": "1.2.3",
            "build_number": "42",
            "ios": {"application_id": "app.pakperk.pakperk"},
            "source_revision": self.source_revision,
        }

    def _write_json(self, path: pathlib.Path, value: object) -> None:
        path.write_text(
            json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n",
            encoding="ascii",
        )
        path.chmod(0o600)

    def _write_candidate_manifests(self) -> None:
        self._write_json(
            self.candidate_root / "evidence/mobile-candidate.json",
            self.candidate,
        )
        self._write_json(
            self.candidate_root / "evidence/mobile-release-provenance.json",
            self.provenance,
        )

    def _write_checksum_manifest(self) -> None:
        entries = []
        for path in sorted((self.candidate_root / "evidence").iterdir()):
            relative = path.relative_to(self.candidate_root).as_posix()
            entries.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}")
        manifest = self.candidate_root / "release-sha256.txt"
        manifest.write_text("\n".join(entries) + "\n", encoding="ascii")
        manifest.chmod(0o600)

    def _arguments(self, **updates: object) -> argparse.Namespace:
        candidate_path = self.candidate_root / "evidence/mobile-candidate.json"
        provenance_path = (
            self.candidate_root / "evidence/mobile-release-provenance.json"
        )
        values: dict[str, object] = {
            "candidate_root": self.candidate_root,
            "archive": self.archive,
            "temp_root": self.base,
            "source_revision": self.source_revision,
            "candidate_id": "sha256:"
            + hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
            "provenance_id": "sha256:"
            + hashlib.sha256(provenance_path.read_bytes()).hexdigest(),
            "version_name": "1.2.3",
            "build_number": "42",
            "bundle_id": "app.pakperk.pakperk",
            "archive_sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "bundle_sha256": "b" * 64,
            "tree_sha256": "c" * 64,
            "github_output": self.output,
        }
        values.update(updates)
        return argparse.Namespace(**values)

    def _prepare_with_reviewed_dependencies(
        self, arguments: argparse.Namespace | None = None
    ) -> tuple[mock.Mock, mock.Mock, mock.Mock]:
        restored = self.base / "restored-client"
        restored.mkdir(exist_ok=True)
        extract = mock.patch.object(
            preparation.extractor,
            "extract",
            autospec=True,
            return_value=restored,
        )
        attest = mock.patch.object(
            preparation.client_validator,
            "attest",
            autospec=True,
            return_value=types.SimpleNamespace(
                bundle_sha256="b" * 64,
                tree_sha256="c" * 64,
                root_device=11,
                root_inode=22,
            ),
        )
        capture = mock.patch.object(
            preparation.runtime_capture,
            "capture",
            autospec=True,
            return_value={
                "reviewed_path": "/usr/bin:/bin",
                "ruby_bin": "/usr/bin/ruby",
                "ruby_sha256": "d" * 64,
            },
        )
        with extract as extract_mock, attest as attest_mock, capture as capture_mock:
            preparation.prepare(arguments or self._arguments())
            return extract_mock, attest_mock, capture_mock

    def test_isolated_mode_entrypoint_imports_only_its_reviewed_siblings(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--help"],
            cwd=self.base,
            env={"PATH": "/usr/bin:/bin"},
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("--candidate-root", result.stdout)

    def test_happy_path_binds_candidate_archive_client_and_runtime_outputs(self) -> None:
        extract, attest, capture = self._prepare_with_reviewed_dependencies()
        extract.assert_called_once()
        attest.assert_called_once()
        capture.assert_called_once_with(output=self.output)
        outputs = self.output.read_text(encoding="utf-8")
        self.assertIn("candidate_id=sha256:", outputs)
        self.assertIn("provenance_id=sha256:", outputs)
        self.assertIn("client_root_device=11\n", outputs)
        self.assertIn("client-root-inode=22\n", outputs)
        self.assertIn("reviewed-path=/usr/bin:/bin\n", outputs)

    def test_candidate_tamper_after_checksum_manifest_fails_before_extraction(self) -> None:
        path = self.candidate_root / "evidence/mobile-candidate.json"
        path.write_bytes(path.read_bytes() + b" ")
        path.chmod(0o600)
        with mock.patch.object(
            preparation.extractor, "extract", autospec=True
        ) as extract:
            with self.assertRaisesRegex(
                preparation.PreparationError,
                "checksum manifest does not match exact files",
            ):
                preparation.prepare(self._arguments())
        extract.assert_not_called()

    def test_rehashed_candidate_identity_tamper_is_rejected(self) -> None:
        self.candidate["source_revision"] = "f" * 40
        self._write_candidate_manifests()
        self._write_checksum_manifest()
        with self.assertRaisesRegex(
            preparation.PreparationError, "candidate release identity changed"
        ):
            preparation.prepare(self._arguments())

    def test_archive_tamper_is_rejected_before_restore(self) -> None:
        arguments = self._arguments()
        self.archive.write_bytes(b"tampered after reviewed digest")
        with mock.patch.object(
            preparation.extractor, "extract", autospec=True
        ) as extract:
            with self.assertRaisesRegex(
                preparation.PreparationError, "store-client archive digest changed"
            ):
                preparation.prepare(arguments)
        extract.assert_not_called()

    def test_restored_client_attestation_mismatch_fails_closed(self) -> None:
        restored = self.base / "restored-client"
        restored.mkdir()
        with (
            mock.patch.object(
                preparation.extractor,
                "extract",
                autospec=True,
                return_value=restored,
            ),
            mock.patch.object(
                preparation.client_validator,
                "attest",
                autospec=True,
                return_value=types.SimpleNamespace(
                    bundle_sha256="e" * 64,
                    tree_sha256="c" * 64,
                    root_device=11,
                    root_inode=22,
                ),
            ),
            mock.patch.object(
                preparation.runtime_capture, "capture", autospec=True
            ) as capture,
        ):
            with self.assertRaisesRegex(
                preparation.PreparationError,
                "restored store-client content identity changed",
            ):
                preparation.prepare(self._arguments())
        capture.assert_not_called()


if __name__ == "__main__":
    unittest.main()
