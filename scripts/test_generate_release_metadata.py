#!/usr/bin/env python3
"""Regression tests for deterministic release-metadata inputs."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

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
        dependency_offset = check_script.index("flutter pub get --enforce-lockfile")
        generation_offset = check_script.index(
            '"$project_dir/scripts/generate_release_metadata.py" \\\n'
            '      --output-dir "$temporary_dir/metadata-a"'
        )
        self.assertLess(dependency_offset, generation_offset)


if __name__ == "__main__":
    unittest.main()
