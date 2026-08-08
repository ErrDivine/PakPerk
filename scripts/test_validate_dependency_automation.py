#!/usr/bin/env python3
"""Regression tests for dependency-update automation coverage."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_dependency_automation as validator


SOURCE = validator.CONFIG.read_text(encoding="utf-8")
TRACKED = {path.as_posix() for path in validator.tracked_files()}


def entry(ecosystem: str, directory: str, limit: int) -> str:
    return (
        f"  - package-ecosystem: {ecosystem}\n"
        f"    directory: {directory}\n"
        "    schedule: { interval: weekly, day: monday }\n"
        f"    open-pull-requests-limit: {limit}\n"
    )


class DependencyAutomationTests(unittest.TestCase):
    def validate(
        self,
        source: str = SOURCE,
        *,
        tracked_paths: set[str] = TRACKED,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = pathlib.Path(temporary) / "dependabot.yml"
            config.write_text(source, encoding="utf-8")
            validator.validate(config=config, tracked_paths=tracked_paths)

    def test_checked_in_coverage_passes(self) -> None:
        self.validate()

    def test_every_required_ecosystem_directory_is_enforced(self) -> None:
        configured = validator.configured_updates(SOURCE)
        for ecosystem, directory in sorted(validator.REQUIRED_UPDATES):
            block = entry(ecosystem, directory, configured[(ecosystem, directory)])
            with self.subTest(ecosystem=ecosystem, directory=directory):
                self.assertIn(block, SOURCE)
                with self.assertRaisesRegex(RuntimeError, "automation is missing"):
                    self.validate(SOURCE.replace(block, "", 1))

    def test_duplicate_update_entry_is_rejected(self) -> None:
        block = entry("cargo", "/backend", 10)
        self.assertIn(block, SOURCE)
        with self.assertRaisesRegex(RuntimeError, "repeats"):
            self.validate(SOURCE + block)

    def test_ecosystem_without_directory_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "has no canonical directory"):
            self.validate(SOURCE + "  - package-ecosystem: npm\n")

    def test_new_committed_graph_requires_its_own_update_entry(self) -> None:
        expanded = TRACKED | {"tools/report/package-lock.json"}
        with self.assertRaisesRegex(
            RuntimeError,
            r"automation is missing: npm:/tools/report",
        ):
            self.validate(tracked_paths=expanded)
        self.validate(
            SOURCE + entry("npm", "/tools/report", 5),
            tracked_paths=expanded,
        )

    def test_new_committed_pip_graph_requires_its_own_update_entry(self) -> None:
        expanded = TRACKED | {"tools/acceptance/live-report.txt"}
        with self.assertRaisesRegex(
            RuntimeError,
            r"automation is missing: pip:/tools/acceptance",
        ):
            self.validate(tracked_paths=expanded)
        self.validate(
            SOURCE + entry("pip", "/tools/acceptance", 5),
            tracked_paths=expanded,
        )

    def test_supported_python_project_roots_require_pip_updates(self) -> None:
        for filename in ("pyproject.toml", "setup.py"):
            with self.subTest(filename=filename):
                root = f"tools/{filename.removesuffix('.toml').removesuffix('.py')}"
                graph = f"{root}/{filename}"
                expanded = TRACKED | {graph}
                with self.assertRaisesRegex(
                    RuntimeError,
                    rf"automation is missing: pip:/{root}",
                ):
                    self.validate(tracked_paths=expanded)
                self.validate(
                    SOURCE + entry("pip", f"/{root}", 5),
                    tracked_paths=expanded,
                )

    def test_android_purl_inventory_is_outside_pip_and_not_discovered(self) -> None:
        inventory = validator.ROOT / "scripts/android-prod-runtime-purls.txt"
        self.assertTrue(inventory.is_file())
        self.assertFalse(
            (validator.ROOT / "scripts/requirements/android-prod-runtime-purls.txt").exists()
        )
        self.assertEqual(
            validator.discover_dependency_updates(
                {"evidence/android-prod-runtime-purls.txt"}
            ),
            set(),
        )

    def test_discovery_covers_every_supported_ecosystem(self) -> None:
        paths = {
            "rust/Cargo.lock",
            "rust/Cargo.toml",
            "rust/crate/Cargo.toml",
            "dart/pubspec.lock",
            "ruby/Gemfile.lock",
            "web/package-lock.json",
            "python/live-integration.txt",
            "python/pyproject.toml",
            "python/setup.py",
            "python/android-prod-runtime-purls.txt",
            "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "android/settings.gradle.kts",
            "android/app/build.gradle.kts",
            "local/docker-compose.yaml",
            "images/api.Dockerfile",
            ".github/workflows/ci.yml",
        }
        self.assertEqual(
            validator.discover_dependency_updates(paths),
            {
                ("bundler", "/ruby"),
                ("cargo", "/rust"),
                ("docker", "/images"),
                ("docker-compose", "/local"),
                ("github-actions", "/"),
                ("gradle", "/android"),
                ("npm", "/web"),
                ("pip", "/python"),
                ("pub", "/dart"),
                ("swift", "/ios"),
            },
        )

    def test_compose_manifest_has_only_the_compose_update_owner(self) -> None:
        self.assertEqual(
            validator.discover_dependency_updates({"docker-compose.yml"}),
            {("docker-compose", "/")},
        )
        self.assertNotIn(("docker", "/"), validator.REQUIRED_UPDATES)

    def test_schedule_drift_is_rejected(self) -> None:
        tampered = SOURCE.replace(
            "schedule: { interval: weekly, day: monday }",
            "schedule: { interval: monthly }",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "weekly on Monday"):
            self.validate(tampered)

    def test_open_pull_request_limit_must_be_bounded(self) -> None:
        for invalid in (0, 11):
            with self.subTest(invalid=invalid):
                tampered = SOURCE.replace(
                    "open-pull-requests-limit: 10",
                    f"open-pull-requests-limit: {invalid}",
                    1,
                )
                with self.assertRaisesRegex(RuntimeError, "must be between 1 and 10"):
                    self.validate(tampered)

    def test_required_graph_must_remain_tracked(self) -> None:
        for missing in (
            "mobile/Gemfile.lock",
            "scripts/requirements/live-comments.txt",
        ):
            with self.subTest(missing=missing):
                self.assertIn(missing, TRACKED)
                with self.assertRaisesRegex(
                    RuntimeError,
                    "committed dependency graph is missing",
                ):
                    self.validate(tracked_paths=TRACKED - {missing})


if __name__ == "__main__":
    unittest.main()
