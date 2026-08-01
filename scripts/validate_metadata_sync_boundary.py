#!/usr/bin/env python3
"""Guard the local metadata-only Compose/seed privilege boundary."""

from __future__ import annotations

import pathlib
import re


PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent


def service_block(compose: str, service: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(service)}:\s*\n(.*?)(?=^  [a-zA-Z0-9_-]+:\s*\n|^volumes:\s*$)",
        compose,
    )
    if match is None:
        raise SystemExit(f"docker-compose.yml has no {service!r} service")
    return match.group(1)


def main() -> None:
    compose = (PROJECT_DIR / "docker-compose.yml").read_text(encoding="utf-8")
    metadata = service_block(compose, "metadata-sync")
    for forbidden in ("env_file:", "GROBID_URL", "LLM_API_KEY", "grobid:"):
        if forbidden in metadata:
            raise SystemExit(
                f"metadata-sync Compose service retained forbidden capability {forbidden!r}"
            )
    for required in (
        'profiles: ["tools"]',
        "DATABASE_URL:",
        "DATABASE_POOL_SIZE:",
        "ARXIV_USER_AGENT:",
        "ARXIV_CONTACT_EMAIL:",
        "read_only: true",
        "no-new-privileges:true",
    ):
        if required not in metadata:
            raise SystemExit(
                f"metadata-sync Compose service is missing boundary {required!r}"
            )

    seed = (PROJECT_DIR / "scripts" / "seed_demo.sh").read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s+metadata-sync /usr/local/bin/pakperk-worker ", seed):
        raise SystemExit("seed_demo.sh does not target the restricted metadata-sync service")
    if re.search(r"(?m)^\s+worker /usr/local/bin/pakperk-worker ", seed):
        raise SystemExit("seed_demo.sh still targets the privileged worker service")

    print("Validated the local metadata-sync privilege boundary.")


if __name__ == "__main__":
    main()
