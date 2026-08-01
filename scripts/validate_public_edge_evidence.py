#!/usr/bin/env python3
"""Validate one retained Pakperk public-edge technical evidence artifact."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence

from public_edge_evidence import (
    ENVIRONMENTS,
    EvidenceError,
    PublicEdgeBinding,
    read_evidence,
    validate_evidence,
)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--environment", required=True, choices=ENVIRONMENTS)
    parser.add_argument(
        "--expected-outcome", required=True, choices=("passed", "failed")
    )
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--site-origin", required=True)
    parser.add_argument("--api-origin", required=True)
    parser.add_argument("--telemetry-origin", required=True)
    parser.add_argument("--document-version", required=True)
    parser.add_argument("--oidc-issuer", required=True)
    parser.add_argument("--oidc-client-id", required=True)
    parser.add_argument("--support-email", required=True)
    parser.add_argument("--android-package", required=True)
    parser.add_argument("--android-sha256", required=True)
    parser.add_argument("--apple-team-id", required=True)
    parser.add_argument("--apple-bundle-id", required=True)
    return parser.parse_args(argv)


def binding_from_args(arguments: argparse.Namespace) -> PublicEdgeBinding:
    return PublicEdgeBinding(
        source_revision=arguments.source_revision,
        target_environment=arguments.environment,
        requested_candidate_id=arguments.candidate_id,
        site_origin=arguments.site_origin,
        api_origin=arguments.api_origin,
        telemetry_origin=arguments.telemetry_origin,
        document_version=arguments.document_version,
        oidc_issuer=arguments.oidc_issuer,
        oidc_client_id=arguments.oidc_client_id,
        support_email=arguments.support_email,
        android_package=arguments.android_package,
        android_sha256=arguments.android_sha256,
        apple_team_id=arguments.apple_team_id,
        apple_bundle_id=arguments.apple_bundle_id,
    ).validate()


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        binding = binding_from_args(arguments)
        evidence = read_evidence(arguments.evidence)
        validated = validate_evidence(
            evidence,
            expected_binding=binding,
            expected_outcome=arguments.expected_outcome,
        )
    except EvidenceError as error:
        print(f"public-edge evidence validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "Public-edge technical evidence validated "
        f"({validated['run']['outcome']}, {len(validated['scenarios'])} scenarios)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
