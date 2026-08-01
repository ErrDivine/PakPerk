#!/usr/bin/env python3
"""Regression tests for external image scan pin validation."""

from __future__ import annotations

import pathlib
import tempfile

from validate_external_image_scan_pins import validate


DIGEST_A = "sha256:" + "a" * 64
DIGEST_B = "sha256:" + "b" * 64


def fixture(directory: pathlib.Path, *, workflow_grobid: str = DIGEST_A) -> tuple[pathlib.Path, pathlib.Path]:
    values = directory / "values.yaml"
    values.write_text(
        f"""grobid:
  image:
    repository: grobid/grobid
    digest: {DIGEST_A}
otelCollector:
  image:
    repository: example.invalid/collector
    digest: {DIGEST_B}
""",
        encoding="utf-8",
    )
    workflow = directory / "security.yml"
    workflow.write_text(
        f"""env:
  GROBID_IMAGE: grobid/grobid@{workflow_grobid}
  OTEL_COLLECTOR_IMAGE: example.invalid/collector@{DIGEST_B}
jobs:
  scan:
    steps:
      - with:
          image-ref: ${{{{ env.GROBID_IMAGE }}}}
      - with:
          image-ref: ${{{{ env.GROBID_IMAGE }}}}
      - with:
          image-ref: ${{{{ env.OTEL_COLLECTOR_IMAGE }}}}
      - with:
          image-ref: ${{{{ env.OTEL_COLLECTOR_IMAGE }}}}
""",
        encoding="utf-8",
    )
    return values, workflow


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="pakperk-image-pins-") as raw:
        values, workflow = fixture(pathlib.Path(raw))
        validate(values, workflow)

    with tempfile.TemporaryDirectory(prefix="pakperk-image-pins-") as raw:
        values, workflow = fixture(pathlib.Path(raw), workflow_grobid=DIGEST_B)
        try:
            validate(values, workflow)
        except RuntimeError as error:
            assert "does not match chart image" in str(error)
        else:
            raise AssertionError("mismatched scan pin unexpectedly passed")

    print("External image scan pin regressions passed.")


if __name__ == "__main__":
    main()
