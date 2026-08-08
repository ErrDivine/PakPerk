#!/usr/bin/env python3
"""Require canonical automated-update coverage for every committed dependency graph."""

from __future__ import annotations

import pathlib
import re
import subprocess
from collections.abc import Iterable


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".github" / "dependabot.yml"

# These entries are deliberate release-policy roots in addition to the graphs
# found by discovery. Dockerfile and Compose manifests remain separate update
# ecosystems so one committed graph has exactly one owner.
REQUIRED_UPDATES = {
    ("bundler", "/mobile"),
    ("cargo", "/backend"),
    ("docker", "/backend"),
    ("docker", "/site"),
    ("docker-compose", "/"),
    ("github-actions", "/"),
    ("gradle", "/mobile/android"),
    ("npm", "/site"),
    ("pip", "/scripts/requirements"),
    ("pub", "/mobile"),
    ("swift", "/mobile/ios"),
}

REQUIRED_GRAPH_FILES = {
    "backend/Cargo.lock",
    "docker-compose.yml",
    "mobile/Gemfile.lock",
    "mobile/android/build.gradle.kts",
    "mobile/android/gradle/wrapper/gradle-wrapper.properties",
    "mobile/android/settings.gradle.kts",
    "mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "mobile/pubspec.lock",
    "scripts/requirements/live-account-deletion.txt",
    "scripts/requirements/live-comments.txt",
    "site/package-lock.json",
}

_ECOSYSTEM = re.compile(r"^  - package-ecosystem: ([a-z0-9-]+)$")
_DIRECTORY = re.compile(r"^    directory: (/[A-Za-z0-9._/-]*)$")
_LIMIT = re.compile(r"^    open-pull-requests-limit: ([0-9]+)$")
_SCHEDULE = "    schedule: { interval: weekly, day: monday }"
_MINIMUM_OPEN_PULL_REQUESTS = 1
_MAXIMUM_OPEN_PULL_REQUESTS = 10
_PIP_REQUIREMENT = re.compile(
    r"^(?:requirements(?:[-_.][A-Za-z0-9_.-]+)?|live-[A-Za-z0-9_.-]+)\.txt$"
)
_PIP_PROJECT_FILES = {"pyproject.toml", "setup.py"}


def _canonical_path(raw_path: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(raw_path)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise RuntimeError(f"dependency graph has a non-canonical tracked path: {raw_path!r}")
    return path


def tracked_files(root: pathlib.Path = ROOT) -> set[pathlib.PurePosixPath]:
    """Return the Git index when available, falling back only outside a repository."""

    completed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode == 0:
        try:
            names = completed.stdout.decode("utf-8").split("\0")
        except UnicodeDecodeError as error:
            raise RuntimeError("tracked dependency paths must be UTF-8") from error
        return {_canonical_path(name) for name in names if name}

    return {
        _canonical_path(path.relative_to(root).as_posix())
        for path in root.rglob("*")
        if path.is_file() and ".git" not in path.relative_to(root).parts
    }


def _directory(path: pathlib.PurePosixPath) -> str:
    rendered = path.as_posix()
    return "/" if rendered == "." else f"/{rendered}"


def _is_within(path: pathlib.PurePosixPath, root: pathlib.PurePosixPath) -> bool:
    return path == root or root in path.parents


def _swift_root(path: pathlib.PurePosixPath) -> pathlib.PurePosixPath:
    parts = path.parts
    for index, part in enumerate(parts[:-1]):
        if part.endswith((".xcodeproj", ".xcworkspace")):
            return pathlib.PurePosixPath(*parts[:index])
    return path.parent


def discover_dependency_updates(
    raw_paths: Iterable[str | pathlib.PurePosixPath],
) -> set[tuple[str, str]]:
    """Map committed manifests/locks to their Dependabot ecosystem roots."""

    paths = {
        path if isinstance(path, pathlib.PurePosixPath) else _canonical_path(path)
        for path in raw_paths
    }
    updates: set[tuple[str, str]] = set()

    cargo_roots = {path.parent for path in paths if path.name == "Cargo.lock"}
    cargo_manifests = sorted(
        (path.parent for path in paths if path.name == "Cargo.toml"),
        key=lambda path: (len(path.parts), path.as_posix()),
    )
    for root in cargo_manifests:
        if not any(_is_within(root, existing) for existing in cargo_roots):
            cargo_roots.add(root)
    updates.update(("cargo", _directory(root)) for root in cargo_roots)

    pub_roots = {
        path.parent for path in paths if path.name in {"pubspec.yaml", "pubspec.lock"}
    }
    updates.update(("pub", _directory(root)) for root in pub_roots)

    bundler_roots = {
        path.parent for path in paths if path.name in {"Gemfile", "Gemfile.lock"}
    }
    updates.update(("bundler", _directory(root)) for root in bundler_roots)

    npm_lock_roots = {
        path.parent
        for path in paths
        if path.name in {"package-lock.json", "npm-shrinkwrap.json"}
    }
    npm_roots = set(npm_lock_roots)
    for path in paths:
        if path.name == "package.json" and not any(
            _is_within(path.parent, root) for root in npm_lock_roots
        ):
            npm_roots.add(path.parent)
    updates.update(("npm", _directory(root)) for root in npm_roots)

    # Limit text-file discovery to names that represent pip requirement
    # graphs. In particular, the adjacent Android PURL inventory is evidence,
    # not a Python dependency graph.
    pip_roots = {
        path.parent
        for path in paths
        if _PIP_REQUIREMENT.fullmatch(path.name) or path.name in _PIP_PROJECT_FILES
    }
    updates.update(("pip", _directory(root)) for root in pip_roots)

    swift_roots = {
        path.parent for path in paths if path.name == "Package.swift"
    }
    swift_roots.update(
        _swift_root(path) for path in paths if path.name == "Package.resolved"
    )
    updates.update(("swift", _directory(root)) for root in swift_roots)

    gradle_roots = {
        path.parent
        for path in paths
        if path.name in {"settings.gradle", "settings.gradle.kts"}
    }
    gradle_roots.update(
        path.parent.parent.parent
        for path in paths
        if path.name == "gradle-wrapper.properties"
        and path.parent.name == "wrapper"
        and path.parent.parent.name == "gradle"
    )
    for path in paths:
        if path.name in {"build.gradle", "build.gradle.kts"} and not any(
            _is_within(path.parent, root) for root in gradle_roots
        ):
            gradle_roots.add(path.parent)
    updates.update(("gradle", _directory(root)) for root in gradle_roots)

    compose_names = {
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    }
    updates.update(
        ("docker-compose", _directory(path.parent))
        for path in paths
        if path.name in compose_names
    )
    updates.update(
        ("docker", _directory(path.parent))
        for path in paths
        if path.name == "Dockerfile"
        or path.name.startswith("Dockerfile.")
        or path.name.endswith(".Dockerfile")
    )

    if any(
        (len(path.parts) >= 3 and path.parts[:2] == (".github", "workflows"))
        or (
            len(path.parts) >= 4
            and path.parts[:2] == (".github", "actions")
            and path.name in {"action.yml", "action.yaml"}
        )
        for path in paths
    ):
        updates.add(("github-actions", "/"))

    return updates


def _next_content_line(lines: list[str], index: int) -> tuple[int, str] | None:
    while index < len(lines):
        line = lines[index]
        if line and not line.lstrip().startswith("#"):
            return index, line
        index += 1
    return None


def configured_updates(source: str) -> dict[tuple[str, str], int]:
    if not source.startswith("version: 2\nupdates:\n"):
        raise RuntimeError("Dependabot must use the version-2 updates schema")

    lines = source.splitlines()[2:]
    updates: dict[tuple[str, str], int] = {}
    index = 0
    while (item := _next_content_line(lines, index)) is not None:
        index, line = item
        ecosystem_match = _ECOSYSTEM.fullmatch(line)
        if ecosystem_match is None:
            raise RuntimeError("Dependabot entry must start with a canonical ecosystem")
        ecosystem = ecosystem_match.group(1)

        directory_item = _next_content_line(lines, index + 1)
        if directory_item is None or (directory_match := _DIRECTORY.fullmatch(directory_item[1])) is None:
            raise RuntimeError(f"Dependabot ecosystem {ecosystem!r} has no canonical directory")
        directory = directory_match.group(1)

        schedule_item = _next_content_line(lines, directory_item[0] + 1)
        if schedule_item is None or schedule_item[1] != _SCHEDULE:
            raise RuntimeError(
                f"Dependabot {ecosystem}:{directory} must run weekly on Monday"
            )

        limit_item = _next_content_line(lines, schedule_item[0] + 1)
        if limit_item is None or (limit_match := _LIMIT.fullmatch(limit_item[1])) is None:
            raise RuntimeError(
                f"Dependabot {ecosystem}:{directory} has no canonical open-PR limit"
            )
        limit = int(limit_match.group(1))
        if not _MINIMUM_OPEN_PULL_REQUESTS <= limit <= _MAXIMUM_OPEN_PULL_REQUESTS:
            raise RuntimeError(
                f"Dependabot {ecosystem}:{directory} open-PR limit must be between "
                f"{_MINIMUM_OPEN_PULL_REQUESTS} and {_MAXIMUM_OPEN_PULL_REQUESTS}"
            )

        pair = (ecosystem, directory)
        if pair in updates:
            raise RuntimeError("Dependabot repeats an ecosystem/directory update entry")
        updates[pair] = limit
        index = limit_item[0] + 1

    if not updates:
        raise RuntimeError("Dependabot contains no update entries")
    return updates


def validate(
    config: pathlib.Path = CONFIG,
    root: pathlib.Path = ROOT,
    *,
    tracked_paths: Iterable[str | pathlib.PurePosixPath] | None = None,
) -> None:
    source = config.read_text(encoding="utf-8")
    configured = set(configured_updates(source))
    paths = (
        tracked_files(root)
        if tracked_paths is None
        else {
            path if isinstance(path, pathlib.PurePosixPath) else _canonical_path(path)
            for path in tracked_paths
        }
    )

    tracked_names = {path.as_posix() for path in paths}
    absent_graphs = sorted(REQUIRED_GRAPH_FILES - tracked_names)
    if absent_graphs:
        raise RuntimeError(
            "committed dependency graph is missing: " + ", ".join(absent_graphs)
        )

    required = REQUIRED_UPDATES | discover_dependency_updates(paths)
    missing = sorted(required - configured)
    if missing:
        rendered = ", ".join(f"{ecosystem}:{directory}" for ecosystem, directory in missing)
        raise RuntimeError(f"dependency update automation is missing: {rendered}")
    unexpected = sorted(configured - required)
    if unexpected:
        rendered = ", ".join(
            f"{ecosystem}:{directory}" for ecosystem, directory in unexpected
        )
        raise RuntimeError(f"dependency update automation has no committed graph: {rendered}")


if __name__ == "__main__":
    validate()
    print("Dependency update automation coverage validated")
