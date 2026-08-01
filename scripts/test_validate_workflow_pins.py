#!/usr/bin/env python3
"""Regression tests for immutable GitHub Actions references."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("validate_workflow_pins.py")
SPEC = importlib.util.spec_from_file_location("validate_workflow_pins", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WorkflowPinTests(unittest.TestCase):
    def validate(self, source: str):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            (workflows / "test.yml").write_text(source, encoding="utf-8")
            with mock.patch.object(MODULE, "ROOT", root):
                return MODULE.workflow_pins()

    def test_finds_list_mapping_and_job_level_uses(self):
        sha = "a" * 40
        pins, references = self.validate(
            f"""jobs:
  direct:
    uses: owner/reusable@{sha}
  steps:
    steps:
      - uses: owner/action@{sha}
      - name: Mapping-shaped step
        uses: owner/another@{sha} # reviewed tag
      - uses: ./.github/actions/local
"""
        )
        self.assertEqual(references, 3)
        self.assertEqual(sum(map(len, pins.values())), 3)

    def test_local_action_does_not_need_a_commit(self):
        sha = "b" * 40
        pins, references = self.validate(
            f"""jobs:
  test:
    steps:
      - uses: ./.github/actions/local
      - uses: owner/action@{sha}
"""
        )
        self.assertEqual(references, 1)
        self.assertEqual(pins[("owner", "action")], [sha])

    def test_docker_action_requires_full_lowercase_digest(self):
        digest = "c" * 64
        pins, references = self.validate(
            f"""jobs:
  test:
    steps:
      - uses: docker://registry.example/tool:1.2@sha256:{digest}
"""
        )
        self.assertEqual(pins, {})
        self.assertEqual(references, 1)
        for reference in (
            "docker://registry.example/tool:1.2",
            "docker://registry.example/tool:1.2@sha256:abc",
            f"docker://registry.example/tool:1.2@sha256:{'D' * 64}",
        ):
            with self.subTest(reference=reference):
                with self.assertRaisesRegex(RuntimeError, "full lowercase sha256 digest"):
                    self.validate(
                        f"""jobs:
  test:
    steps:
      - uses: {reference}
"""
                    )

    def test_unpinned_mapping_shaped_step_fails(self):
        with self.assertRaisesRegex(RuntimeError, "full lowercase commit SHA"):
            self.validate(
                """jobs:
  test:
    steps:
      - name: Mutable action
        uses: owner/action@v1
                """
            )

    def test_duplicate_job_steps_key_fails(self):
        sha = "d" * 40
        with self.assertRaisesRegex(RuntimeError, "repeats the steps key"):
            self.validate(
                f"""jobs:
  test:
    steps:
      - uses: owner/action@{sha}
    steps:
      - uses: owner/another@{sha}
"""
            )


if __name__ == "__main__":
    unittest.main()
