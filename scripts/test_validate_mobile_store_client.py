#!/usr/bin/env python3
"""Tests for the immutable mobile store-client tree validator."""

from __future__ import annotations

import os
import pathlib
import tempfile
import unittest

import validate_mobile_store_client as validator


class StoreClientValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.temporary_root = pathlib.Path(self.temporary.name).resolve()
        self.root = self.temporary_root / "client"
        self.root.mkdir(mode=0o700)
        self.gem_home = self.root / "gem-home"
        self.bundle_path = self.root / "bundle"
        self.bundle_config = self.root / "config"
        self.client_home = self.root / "home"
        self.manifest = self.root / "manifest"
        for directory in (
            self.gem_home,
            self.bundle_path,
            self.bundle_config,
            self.client_home,
            self.manifest,
        ):
            directory.mkdir(mode=0o700)
        bin_directory = self.gem_home / "bin"
        bin_directory.mkdir(mode=0o700)
        self.bundle_bin = bin_directory / "bundle"
        self.bundle_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.bundle_bin.chmod(0o700)
        self.gemfile = self.manifest / "Gemfile"
        self.lockfile = self.manifest / "Gemfile.lock"
        self.gemfile.write_text('source "https://rubygems.org"\n', encoding="utf-8")
        self.lockfile.write_text("GEM\n", encoding="utf-8")
        self.gemfile.chmod(0o400)
        self.lockfile.chmod(0o400)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def attest(self) -> validator.Attestation:
        return validator.attest(
            root=self.root,
            bundle_bin=self.bundle_bin,
            gem_home=self.gem_home,
            bundle_gemfile=self.gemfile,
            bundle_lockfile=self.lockfile,
            bundle_path=self.bundle_path,
            bundle_app_config=self.bundle_config,
            client_home=self.client_home,
        )

    def test_attestation_is_stable_for_unchanged_tree(self) -> None:
        first = self.attest()
        second = self.attest()
        self.assertEqual(first, second)
        self.assertRegex(first.bundle_sha256, r"^[0-9a-f]{64}$")
        self.assertRegex(first.tree_sha256, r"^[0-9a-f]{64}$")

    def test_tree_mutation_changes_attestation(self) -> None:
        before = self.attest()
        dependency = self.bundle_path / "dependency.rb"
        dependency.write_text("raise 'changed'\n", encoding="utf-8")
        after = self.attest()
        self.assertNotEqual(before.tree_sha256, after.tree_sha256)

    def test_bundle_mutation_changes_both_digests(self) -> None:
        before = self.attest()
        self.bundle_bin.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        self.bundle_bin.chmod(0o700)
        after = self.attest()
        self.assertNotEqual(before.bundle_sha256, after.bundle_sha256)
        self.assertNotEqual(before.tree_sha256, after.tree_sha256)

    def test_symlink_in_tree_is_rejected(self) -> None:
        (self.bundle_path / "escape").symlink_to(self.gemfile)
        with self.assertRaisesRegex(validator.ValidationError, "regular file"):
            self.attest()

    def test_hardlinked_file_is_rejected(self) -> None:
        os.link(self.gemfile, self.bundle_path / "hardlink")
        with self.assertRaisesRegex(validator.ValidationError, "regular file"):
            self.attest()

    def test_group_writable_client_home_is_rejected(self) -> None:
        self.client_home.chmod(0o720)
        with self.assertRaisesRegex(validator.ValidationError, "HOME"):
            self.attest()

    def test_expected_path_outside_root_is_rejected(self) -> None:
        outside = self.temporary_root / "outside"
        outside.mkdir(mode=0o700)
        with self.assertRaisesRegex(validator.ValidationError, "escaped"):
            validator.attest(
                root=self.root,
                bundle_bin=self.bundle_bin,
                gem_home=self.gem_home,
                bundle_gemfile=self.gemfile,
                bundle_lockfile=self.lockfile,
                bundle_path=outside,
                bundle_app_config=self.bundle_config,
                client_home=self.client_home,
            )


if __name__ == "__main__":
    unittest.main()
