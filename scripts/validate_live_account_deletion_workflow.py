#!/usr/bin/env python3
"""Validate live account-deletion dependency and Compose image locks."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_REQUIREMENTS = ROOT / "scripts/requirements/live-account-deletion.txt"
DEFAULT_WORKFLOW = ROOT / ".github/workflows/live-account-deletion.yml"
DEFAULT_COMPOSE = ROOT / "docker-compose.yml"
EXPECTED_COMPOSE_IMAGES = {
    "postgres": "pgvector/pgvector:0.8.2-pg16-bookworm@sha256:00ba258a66dac104fd5171074a0084462a64a1369d8513f3d0a634e2f24d15bc",
    "keycloak-postgres": "postgres:16.14-bookworm@sha256:92620daddcd947f8d5ab5ba66e848702fe443d87fed30c4cea8e389fd78dfc55",
    "mailpit": "axllent/mailpit:v1.30.6@sha256:7f33095f80e901f6ad08028f06ca284aa58fe84942be5496008d041d3b9f4d4d",
    "keycloak": "quay.io/keycloak/keycloak:26.7.0@sha256:0f198be292568439d700cdbfb893e69a6009bb43a94a06a945b1d3d506c76b13",
    "grobid": "grobid/grobid:0.9.0-crf@sha256:24ba90eb1c959f65d812bcdb2cf79c677fa5fd7b95235de616b8bc9fa1317849",
}
EXPECTED_REQUIREMENTS = {
    "beautifulsoup4": (
        "4.13.4",
        "9bbbb14bfde9d79f38b8cd5f8c7c85f4b8f2523190ebed90e950a8dea4cb1c4b",
    ),
    "certifi": (
        "2026.7.22",
        "62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775",
    ),
    "charset-normalizer": (
        "3.4.9",
        "5e226f6218febc71f6c1fc2fafb91c226f75bdc1d8fb12d66823716e891608fd",
    ),
    "idna": (
        "3.18",
        "7f952cbe720b688055e3f87de14f5c3e5fdaa8bc3928985c4077ca689de849a2",
    ),
    "requests": (
        "2.32.4",
        "27babd3cda2a6d50b30443204ee89830707d396671944c998b5975b031ac2b2c",
    ),
    "soupsieve": (
        "2.9.1",
        "4f4477399246b7a0c720a88ca2454b11cd6bb9ae4c9d170140786e916776c14c",
    ),
    "typing-extensions": (
        "4.16.0",
        "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
    ),
    "urllib3": (
        "2.7.0",
        "9fb4c81ebbb1ce9531cce37674bbc6f1360472bc18ca9a553ede278ef7276897",
    ),
}
REQUIREMENT = re.compile(
    r"([a-z0-9]+(?:-[a-z0-9]+)*)==([A-Za-z0-9][A-Za-z0-9._-]*) "
    r"--hash=sha256:([0-9a-f]{64})"
)


def validate(
    requirements: pathlib.Path = DEFAULT_REQUIREMENTS,
    workflow: pathlib.Path = DEFAULT_WORKFLOW,
    compose: pathlib.Path = DEFAULT_COMPOSE,
) -> None:
    resolved: dict[str, tuple[str, str]] = {}
    for line_number, raw_line in enumerate(
        requirements.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = REQUIREMENT.fullmatch(line)
        if match is None:
            raise RuntimeError(
                f"live deletion requirement line {line_number} is not one exact pin/hash"
            )
        name, version, digest = match.groups()
        if name in resolved:
            raise RuntimeError(f"live deletion requirement is duplicated: {name}")
        resolved[name] = (version, digest)
    if resolved != EXPECTED_REQUIREMENTS:
        raise RuntimeError("live deletion Python dependency graph changed without review")

    source = workflow.read_text(encoding="utf-8")
    for fragment in (
        "runs-on: ubuntu-24.04",
        "sys.version_info[:2] != (3, 12)",
        "--require-hashes",
        "--only-binary=:all:",
        "--requirement scripts/requirements/live-account-deletion.txt",
    ):
        if fragment not in source:
            raise RuntimeError(f"live deletion workflow is missing: {fragment}")
    for forbidden in ("requests==", "beautifulsoup4=="):
        if forbidden in source:
            raise RuntimeError(
                f"live deletion workflow bypasses the complete hash lock: {forbidden}"
            )

    compose_images: dict[str, str] = {}
    current_service: str | None = None
    in_services = False
    for raw_line in compose.read_text(encoding="utf-8").splitlines():
        if raw_line == "services:":
            in_services = True
            continue
        if not in_services:
            continue
        if raw_line and not raw_line.startswith(" "):
            break
        service_match = re.fullmatch(r"  ([a-z0-9][a-z0-9-]*):", raw_line)
        if service_match is not None:
            current_service = service_match.group(1)
            continue
        image_match = re.fullmatch(r"    image: ([^ #]+)", raw_line)
        if current_service is not None and image_match is not None:
            compose_images[current_service] = image_match.group(1)
    for service, expected_image in EXPECTED_COMPOSE_IMAGES.items():
        if compose_images.get(service) != expected_image:
            raise RuntimeError(
                f"Compose service {service} must use the reviewed tag and digest"
            )


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError) as error:
        print(f"live account-deletion workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Live account-deletion dependency and Compose image locks validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
