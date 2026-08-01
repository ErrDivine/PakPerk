#!/usr/bin/env python3
"""Regressions for complete repository shell-script syntax validation."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_shell_syntax as validator


class ShellSyntaxValidationTests(unittest.TestCase):
    def test_checked_in_scripts_pass(self) -> None:
        self.assertGreater(validator.validate(), 1)

    def test_invalid_script_after_valid_script_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scripts = pathlib.Path(directory)
            (scripts / "a-valid.sh").write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' valid\n",
                encoding="utf-8",
            )
            (scripts / "z-invalid.sh").write_text(
                "#!/usr/bin/env bash\nif true; then\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "z-invalid.sh"):
                validator.validate(scripts)

    def test_empty_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "contains no .sh files"):
                validator.validate(pathlib.Path(directory))

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scripts = pathlib.Path(directory)
            target = scripts / "target"
            target.write_text("#!/usr/bin/env bash\ntrue\n", encoding="utf-8")
            (scripts / "linked.sh").symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, "not a regular file"):
                validator.validate(scripts)


if __name__ == "__main__":
    unittest.main()
