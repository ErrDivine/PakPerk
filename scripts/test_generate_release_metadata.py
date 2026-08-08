#!/usr/bin/env python3
"""Regression tests for deterministic release-metadata inputs."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

import generate_release_metadata as metadata


class FlutterSdkMetadataTests(unittest.TestCase):
    def test_application_version_sources_are_synchronized(self) -> None:
        version_name, build_number = metadata.application_version()
        self.assertRegex(version_name, r"^\d+\.\d+\.\d+$")
        self.assertRegex(build_number, r"^[1-9]\d*$")

    def test_sdk_package_without_pubspec_version_uses_pinned_sdk_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sdk_root = pathlib.Path(directory) / "flutter"
            package_root = sdk_root / "packages/flutter_test"
            package_root.mkdir(parents=True)
            (package_root / "pubspec.yaml").write_text(
                "name: flutter_test\n", encoding="utf-8"
            )
            cache = sdk_root / "bin/cache"
            cache.mkdir(parents=True)
            (cache / "flutter.version.json").write_text(
                json.dumps(
                    {
                        "flutterVersion": "3.44.8",
                        "frameworkRevision": "a" * 40,
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                metadata.flutter_sdk_metadata(package_root),
                ("3.44.8", "a" * 40),
            )

    def test_non_sdk_package_without_version_still_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            package_root = pathlib.Path(directory) / "ordinary_package"
            package_root.mkdir()
            pubspec = package_root / "pubspec.yaml"
            pubspec.write_text("name: ordinary_package\n", encoding="utf-8")

            self.assertIsNone(metadata.flutter_sdk_metadata(package_root))
            with self.assertRaisesRegex(RuntimeError, "no safe parseable version"):
                metadata.pubspec_version(pubspec)

    def test_full_check_resolves_locked_flutter_packages_before_metadata(self) -> None:
        check_script = (metadata.ROOT / "scripts/check.sh").read_text(encoding="utf-8")
        dependency_offset = check_script.index(
            "flutter --no-version-check pub get --enforce-lockfile"
        )
        generation_offset = check_script.index(
            '"$project_dir/scripts/generate_release_metadata.py" \\\n'
            "      --flutter-sdk-version 3.44.8 \\\n"
            '      --output-dir "$temporary_dir/metadata-a"'
        )
        self.assertLess(dependency_offset, generation_offset)

    def test_full_check_verifies_exact_flutter_before_dependency_resolution(self) -> None:
        check_script = (metadata.ROOT / "scripts/check.sh").read_text(encoding="utf-8")
        identity_offset = check_script.index(
            'python3 "$project_dir/scripts/validate_flutter_toolchain.py"'
        )
        dependency_offset = check_script.index(
            "flutter --no-version-check pub get --enforce-lockfile"
        )
        self.assertLess(identity_offset, dependency_offset)


class SourceIdentityTests(unittest.TestCase):
    def test_configured_revision_must_match_checkout(self) -> None:
        completed = mock.Mock(stdout="a" * 40 + "\n")
        with mock.patch.object(metadata.subprocess, "run", return_value=completed):
            with mock.patch.dict(
                metadata.os.environ, {"SOURCE_REVISION": "b" * 40}, clear=False
            ):
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    metadata.revision()

    def test_matching_configured_revision_passes(self) -> None:
        completed = mock.Mock(stdout="a" * 40 + "\n")
        with mock.patch.object(metadata.subprocess, "run", return_value=completed):
            with mock.patch.dict(
                metadata.os.environ, {"SOURCE_REVISION": "a" * 40}, clear=False
            ):
                self.assertEqual(metadata.revision(), "a" * 40)


class SwiftPackageMetadataTests(unittest.TestCase):
    def _write_fixture(
        self,
        root: pathlib.Path,
        *,
        first_version: str = "2.0.0",
        second_version: str = "2.0.0",
        revision: str = "145104f5ea9d58ae21b60add007c33c1cc0c948e",
    ) -> None:
        first, second = metadata.SWIFTPM_LOCKFILES
        pin = {
            "pins": [
                {
                    "identity": "appauth-ios",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/openid/AppAuth-iOS",
                    "state": {"revision": revision, "version": "2.0.0"},
                }
            ],
            "version": 2,
        }
        for relative, version in ((first, first_version), (second, second_version)):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            pin["pins"][0]["state"]["version"] = version
            destination.write_text(json.dumps(pin), encoding="utf-8")
        license_path = root / metadata.SWIFTPM_REVIEWED_PACKAGES["appauth-ios"][
            "license_file"
        ]
        license_path.parent.mkdir(parents=True, exist_ok=True)
        license_path.write_text("Apache License Version 2.0", encoding="utf-8")

    def test_checked_in_swift_package_is_pinned_and_licensed(self) -> None:
        components = metadata.swiftpm_components()
        self.assertEqual(len(components), 1)
        self.assertEqual(components[0]["name"], "appauth-ios")
        self.assertEqual(components[0]["declared_license"], "Apache-2.0")
        self.assertIn("?commit=145104f5ea9d58ae21b60add007c33c1cc0c948e", components[0]["purl"])

    def test_disagreeing_swift_package_lockfiles_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self._write_fixture(root, second_version="2.0.1")
            with mock.patch.object(metadata, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "lockfiles disagree"):
                    metadata.swiftpm_components()

    def test_unreviewed_swift_package_version_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self._write_fixture(
                root, first_version="2.0.1", second_version="2.0.1"
            )
            with mock.patch.object(metadata, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "changed without review"):
                    metadata.swiftpm_components()

    def test_unreviewed_swift_package_revision_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self._write_fixture(root, revision="b" * 40)
            with mock.patch.object(metadata, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "changed without review"):
                    metadata.swiftpm_components()

    def test_unreviewed_swift_package_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self._write_fixture(root)
            for relative in metadata.SWIFTPM_LOCKFILES:
                path = root / relative
                payload = json.loads(path.read_text(encoding="utf-8"))
                payload["pins"][0]["identity"] = "unreviewed-package"
                path.write_text(json.dumps(payload), encoding="utf-8")
            with mock.patch.object(metadata, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "no reviewed license mapping"):
                    metadata.swiftpm_components()


if __name__ == "__main__":
    unittest.main()
