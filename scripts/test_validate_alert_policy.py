#!/usr/bin/env python3
"""Regression tests for the production alert-policy validator."""

from __future__ import annotations

import copy
import json
import tempfile
from pathlib import Path
from typing import Any, Callable

from validate_alert_policy import DEFAULT_POLICY, PolicyError, validate_policy


def _write(path: Path, policy: dict[str, Any]) -> None:
    path.write_text(json.dumps(policy, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _expect_rejected(
    baseline: dict[str, Any],
    mutate: Callable[[dict[str, Any]], None],
    expected: str,
    directory: Path,
) -> None:
    candidate = copy.deepcopy(baseline)
    mutate(candidate)
    path = directory / "candidate.json"
    _write(path, candidate)
    try:
        validate_policy(path)
    except PolicyError as error:
        if expected not in str(error):
            raise AssertionError(f"expected {expected!r} in {error!r}") from error
    else:
        raise AssertionError(f"validator accepted mutation expecting {expected!r}")


def main() -> int:
    validate_policy(DEFAULT_POLICY)
    baseline = json.loads(DEFAULT_POLICY.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="pakperk-alert-policy-test-") as raw_directory:
        directory = Path(raw_directory)

        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["rules"].pop(),
            "every required production alert",
            directory,
        )
        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["rules"][0]["condition"].update(threshold=3),
            "weakens or changes",
            directory,
        )
        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["rules"][1]["signal"]["filters"].update(
                {"deployment.environment.name": "staging"}
            ),
            "signal.filters weakens or changes",
            directory,
        )
        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["rules"][0]["signal"]["filters"].update(
                {"authorization": "present"}
            ),
            "selects protected data",
            directory,
        )
        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["requiredInputs"][0].update(
                liveAdapterEvidenceRequired=False
            ),
            "live-adapter evidence",
            directory,
        )
        _expect_rejected(
            baseline,
            lambda policy: policy["spec"]["rules"][0].update(
                runbook="docs/runbooks/missing.md"
            ),
            "existing runbook",
            directory,
        )

        duplicate = directory / "duplicate.json"
        raw = DEFAULT_POLICY.read_text(encoding="utf-8")
        duplicate.write_text(
            raw.replace('"version": 1', '"version": 1,\n    "version": 1', 1),
            encoding="utf-8",
        )
        try:
            validate_policy(duplicate)
        except PolicyError as error:
            assert "duplicate JSON key" in str(error), error
        else:
            raise AssertionError("validator accepted a duplicate JSON key")

    print("Alert-policy validator regression tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
