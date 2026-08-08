#!/usr/bin/env python3
"""Adversarial tests for protected mobile-release secret writes."""

from __future__ import annotations

import base64
import os
import pathlib
import tempfile
import unittest
from unittest import mock

import materialize_mobile_release_secret as materializer


class MobileReleaseSecretMaterializationTests(unittest.TestCase):
    def test_decodes_multiple_secrets_into_fresh_owner_only_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            environment = {
                "FIRST_SECRET": base64.b64encode(b"first bytes").decode("ascii"),
                "SECOND_SECRET": base64.b64encode(b"second bytes").decode("ascii"),
            }
            with mock.patch.dict(os.environ, environment, clear=False):
                materializer.decode_into_exclusive_directory(
                    root=root,
                    directory="auth/private_keys",
                    secrets=[
                        ("FIRST_SECRET", "first.bin", 32),
                        ("SECOND_SECRET", "AuthKey_ABCDEFGHIJ.p8", 32),
                    ],
                )
            auth = root / "auth"
            private_keys = auth / "private_keys"
            self.assertEqual(0o700, auth.stat().st_mode & 0o777)
            self.assertEqual(0o700, private_keys.stat().st_mode & 0o777)
            self.assertEqual(b"first bytes", (private_keys / "first.bin").read_bytes())
            self.assertEqual(
                b"second bytes",
                (private_keys / "AuthKey_ABCDEFGHIJ.p8").read_bytes(),
            )
            self.assertEqual(0o600, (private_keys / "first.bin").stat().st_mode & 0o777)

    def test_preplanted_directory_or_symlink_fails_before_secret_write(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            encoded = base64.b64encode(b"secret").decode("ascii")
            for planted_kind in ("directory", "symlink"):
                with self.subTest(planted_kind=planted_kind):
                    planted = root / f"auth-{planted_kind}"
                    target = root / f"target-{planted_kind}"
                    target.mkdir()
                    if planted_kind == "directory":
                        planted.mkdir()
                    else:
                        planted.symlink_to(target, target_is_directory=True)
                    with mock.patch.dict(os.environ, {"SECRET": encoded}, clear=False):
                        with self.assertRaises(materializer.MaterializationError):
                            materializer.decode_into_exclusive_directory(
                                root=root,
                                directory=planted.name,
                                secrets=[("SECRET", "secret.bin", 32)],
                            )
                    self.assertEqual([], list(target.iterdir()))

    def test_symlinked_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "real"
            root.mkdir()
            linked = parent / "linked"
            linked.symlink_to(root, target_is_directory=True)
            with mock.patch.dict(
                os.environ,
                {"SECRET": base64.b64encode(b"secret").decode("ascii")},
                clear=False,
            ):
                with self.assertRaises(materializer.MaterializationError):
                    materializer.decode_into_exclusive_directory(
                        root=linked,
                        directory="auth",
                        secrets=[("SECRET", "secret.bin", 32)],
                    )

    def test_invalid_or_oversized_base64_fails_without_creating_directory(self) -> None:
        values = ("not base64!", base64.b64encode(b"too large").decode("ascii"))
        for value in values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                with mock.patch.dict(os.environ, {"SECRET": value}, clear=False):
                    with self.assertRaises(materializer.MaterializationError):
                        materializer.decode_into_exclusive_directory(
                            root=root,
                            directory="auth",
                            secrets=[("SECRET", "secret.bin", 3)],
                        )
                self.assertFalse((root / "auth").exists())

    def test_duplicate_secret_filenames_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            encoded = base64.b64encode(b"secret").decode("ascii")
            with mock.patch.dict(
                os.environ, {"FIRST": encoded, "SECOND": encoded}, clear=False
            ):
                with self.assertRaises(materializer.MaterializationError):
                    materializer.decode_into_exclusive_directory(
                        root=root,
                        directory="auth",
                        secrets=[
                            ("FIRST", "same.bin", 32),
                            ("SECOND", "same.bin", 32),
                        ],
                    )

    def test_secure_copy_creates_real_parents_and_exclusive_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.mobileprovision"
            source.write_bytes(b"profile bytes")
            source.chmod(0o600)
            materializer.copy_to_protected_path(
                source=source,
                root=root,
                relative_path="Library/MobileDevice/Provisioning Profiles/profile.mobileprovision",
                maximum_bytes=64,
            )
            destination = (
                root
                / "Library/MobileDevice/Provisioning Profiles/profile.mobileprovision"
            )
            self.assertEqual(b"profile bytes", destination.read_bytes())
            self.assertEqual(0o600, destination.stat().st_mode & 0o777)

    def test_secure_copy_rejects_preplanted_destination_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.mobileprovision"
            source.write_bytes(b"profile bytes")
            source.chmod(0o600)
            destination_parent = root / "Library/MobileDevice/Provisioning Profiles"
            destination_parent.mkdir(parents=True)
            target = root / "captured"
            target.write_bytes(b"unchanged")
            destination = destination_parent / "profile.mobileprovision"
            destination.symlink_to(target)
            with self.assertRaises(materializer.MaterializationError):
                materializer.copy_to_protected_path(
                    source=source,
                    root=root,
                    relative_path="Library/MobileDevice/Provisioning Profiles/profile.mobileprovision",
                    maximum_bytes=64,
                )
            self.assertEqual(b"unchanged", target.read_bytes())

    def test_secure_copy_rejects_symlinked_parent_and_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.mobileprovision"
            source.write_bytes(b"profile bytes")
            source.chmod(0o600)
            real_library = root / "real-library"
            real_library.mkdir()
            (root / "Library").symlink_to(real_library, target_is_directory=True)
            with self.assertRaises(materializer.MaterializationError):
                materializer.copy_to_protected_path(
                    source=source,
                    root=root,
                    relative_path="Library/MobileDevice/profile.mobileprovision",
                    maximum_bytes=64,
                )
            linked_source = root / "linked.mobileprovision"
            linked_source.symlink_to(source)
            with self.assertRaises(materializer.MaterializationError):
                materializer.copy_to_protected_path(
                    source=linked_source,
                    root=root,
                    relative_path="real-library/profile.mobileprovision",
                    maximum_bytes=64,
                )

    def test_private_key_container_requires_no_follow_owner_only_single_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            valid = root / "release.keychain-db"
            valid.write_bytes(b"keychain")
            valid.chmod(0o600)
            materializer.validate_protected_file(valid, 64)

            insecure = root / "insecure.keychain-db"
            insecure.write_bytes(b"keychain")
            insecure.chmod(0o640)
            with self.assertRaises(materializer.MaterializationError):
                materializer.validate_protected_file(insecure, 64)

            linked = root / "linked.keychain-db"
            linked.symlink_to(valid)
            with self.assertRaises(materializer.MaterializationError):
                materializer.validate_protected_file(linked, 64)

            hardlink = root / "hardlinked.keychain-db"
            os.link(valid, hardlink)
            with self.assertRaises(materializer.MaterializationError):
                materializer.validate_protected_file(valid, 64)


if __name__ == "__main__":
    unittest.main()
