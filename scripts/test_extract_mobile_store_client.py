#!/usr/bin/env python3
"""Tests for safe mobile store-client archive extraction."""

from __future__ import annotations

import io
import pathlib
import tarfile
import tempfile
import unittest

import extract_mobile_store_client as extractor
import validate_mobile_store_client as validator


class StoreClientExtractionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir(mode=0o700)
        self.paths = {}
        for name in ("gem-home", "bundle", "config", "home", "manifest"):
            path = self.source / name
            path.mkdir(mode=0o700)
            self.paths[name] = path
        bin_directory = self.paths["gem-home"] / "bin"
        bin_directory.mkdir(mode=0o700)
        self.bundle_bin = bin_directory / "bundle"
        self.bundle_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.bundle_bin.chmod(0o700)
        self.gemfile = self.paths["manifest"] / "Gemfile"
        self.lockfile = self.paths["manifest"] / "Gemfile.lock"
        self.gemfile.write_text('source "https://rubygems.org"\n', encoding="utf-8")
        self.lockfile.write_text("GEM\n", encoding="utf-8")
        self.gemfile.chmod(0o400)
        self.lockfile.chmod(0o400)
        self.archive = self.base / "client.tar.gz"
        self.output = self.base / "output.txt"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_archive(self) -> None:
        with tarfile.open(self.archive, "w:gz") as target:
            for child in sorted(self.source.iterdir()):
                target.add(child, arcname=child.name, recursive=True)

    def attest(self, root: pathlib.Path) -> validator.Attestation:
        return validator.attest(
            root=root,
            bundle_bin=root / "gem-home/bin/bundle",
            gem_home=root / "gem-home",
            bundle_gemfile=root / "manifest/Gemfile",
            bundle_lockfile=root / "manifest/Gemfile.lock",
            bundle_path=root / "bundle",
            bundle_app_config=root / "config",
            client_home=root / "home",
        )

    def test_round_trip_preserves_content_attestation(self) -> None:
        before = self.attest(self.source)
        self.write_archive()
        root = extractor.extract(
            archive=self.archive,
            parent=self.base,
            output=self.output,
        )
        after = self.attest(root)
        self.assertEqual(before.bundle_sha256, after.bundle_sha256)
        self.assertEqual(before.tree_sha256, after.tree_sha256)
        self.assertIn(f"root={root}\n", self.output.read_text(encoding="utf-8"))

    def test_path_traversal_is_rejected(self) -> None:
        with tarfile.open(self.archive, "w:gz") as target:
            member = tarfile.TarInfo("../escape")
            member.size = 1
            target.addfile(member, io.BytesIO(b"x"))
        with self.assertRaisesRegex(extractor.ExtractionError, "escaped"):
            extractor.extract(
                archive=self.archive,
                parent=self.base,
                output=self.output,
            )

    def test_symbolic_link_is_rejected(self) -> None:
        with tarfile.open(self.archive, "w:gz") as target:
            member = tarfile.TarInfo("bundle/link")
            member.type = tarfile.SYMTYPE
            member.linkname = "/tmp/escape"
            target.addfile(member)
        with self.assertRaisesRegex(extractor.ExtractionError, "link or special"):
            extractor.extract(
                archive=self.archive,
                parent=self.base,
                output=self.output,
            )

    def test_group_writable_member_is_rejected(self) -> None:
        with tarfile.open(self.archive, "w:gz") as target:
            member = tarfile.TarInfo("bundle/file")
            member.mode = 0o620
            member.size = 1
            target.addfile(member, io.BytesIO(b"x"))
        with self.assertRaisesRegex(extractor.ExtractionError, "writable"):
            extractor.extract(
                archive=self.archive,
                parent=self.base,
                output=self.output,
            )

    def test_member_limit_is_enforced_while_streaming_headers(self) -> None:
        with tarfile.open(self.archive, "w:gz") as target:
            for name in ("one", "two"):
                member = tarfile.TarInfo(name)
                member.mode = 0o600
                member.size = 1
                target.addfile(member, io.BytesIO(b"x"))
        original_limit = extractor.MAXIMUM_MEMBERS
        extractor.MAXIMUM_MEMBERS = 1
        try:
            with self.assertRaisesRegex(extractor.ExtractionError, "member count"):
                extractor.extract(
                    archive=self.archive,
                    parent=self.base,
                    output=self.output,
                )
        finally:
            extractor.MAXIMUM_MEMBERS = original_limit


if __name__ == "__main__":
    unittest.main()
