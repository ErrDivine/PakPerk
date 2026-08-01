#!/usr/bin/env python3
"""Regression tests for the Android native SBOM gate."""

from __future__ import annotations

import copy
import unittest

import validate_android_native_sbom as validator


def component(group: str, name: str, version: str, sha256: str, *, licensed: bool = True) -> dict:
    value = {
        "type": "library",
        "group": group,
        "name": name,
        "version": version,
        "purl": f"pkg:maven/{group}/{name}@{version}?type=aar",
        "bom-ref": f"pkg:maven/{group}/{name}@{version}?type=aar",
        "hashes": [{"alg": "SHA-256", "content": sha256}],
    }
    if licensed:
        value["licenses"] = [{"license": {"id": "Apache-2.0"}}]
    return value


def valid_payload() -> dict:
    required = [
        component(group, name, values["version"], values["sha256"])
        for (group, name), values in validator.REQUIRED_COMPONENTS.items()
    ]
    required.extend(
        [
            component("androidx.core", "core", "1.17.0", "a" * 64),
            component(
                "io.flutter",
                "flutter_embedding_release",
                "1.0.0-reviewed",
                "b" * 64,
                licensed=False,
            ),
        ]
    )
    root = "pkg:maven/app.pakperk/pakperk-android@0.2.0?project_path=%3Aapp"
    component_refs = [value["purl"] for value in required]
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "metadata": {
            "component": {
                "type": "application",
                "group": "app.pakperk",
                "name": "pakperk-android",
                "version": "0.2.0",
                "purl": root,
                "bom-ref": root,
                "modified": False,
            }
        },
        "components": required,
        "dependencies": [
            {"ref": root, "dependsOn": component_refs},
            *({"ref": reference, "dependsOn": []} for reference in component_refs),
        ],
    }


def validate_fixture(payload: dict, expected_purls: set[str] | None = None) -> None:
    validator.validate_sbom(
        payload,
        expected_purls=expected_purls
        if expected_purls is not None
        else {value["purl"] for value in valid_payload()["components"]},
        expected_version="0.2.0",
    )


class AndroidNativeSbomTests(unittest.TestCase):
    def test_reviewed_release_graph_passes(self) -> None:
        validate_fixture(valid_payload())

    def test_checked_in_runtime_inventory_matches_build_inputs(self) -> None:
        inventory = validator.load_reviewed_inventory()
        self.assertIn("pkg:maven/net.openid/appauth@0.11.1?type=aar", inventory)
        self.assertIn(
            "pkg:maven/com.google.crypto.tink/tink-android@1.21.0?type=jar",
            inventory,
        )

    def test_missing_security_dependency_fails(self) -> None:
        payload = valid_payload()
        removed = next(
            value for value in payload["components"] if value["name"] == "appauth"
        )
        payload["components"] = [
            value for value in payload["components"] if value["name"] != "appauth"
        ]
        payload["dependencies"][0]["dependsOn"].remove(removed["purl"])
        payload["dependencies"] = [
            value for value in payload["dependencies"] if value["ref"] != removed["purl"]
        ]
        with self.assertRaisesRegex(RuntimeError, "missing required component"):
            validate_fixture(payload, {value["purl"] for value in payload["components"]})

    def test_changed_checksum_fails(self) -> None:
        payload = valid_payload()
        appauth = next(value for value in payload["components"] if value["name"] == "appauth")
        appauth["hashes"][0]["content"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "checksum changed"):
            validate_fixture(payload)

    def test_unlicensed_external_dependency_fails(self) -> None:
        payload = valid_payload()
        payload["components"].append(
            component("example", "unreviewed", "1.0.0", "c" * 64, licensed=False)
        )
        with self.assertRaisesRegex(RuntimeError, "no declared license"):
            validate_fixture(
                payload,
                {value["purl"] for value in payload["components"]},
            )

    def test_debug_engine_fails(self) -> None:
        payload = copy.deepcopy(valid_payload())
        engine = next(
            value
            for value in payload["components"]
            if value["name"] == "flutter_embedding_release"
        )
        engine["name"] = "flutter_embedding_debug"
        engine["purl"] = engine["purl"].replace("release", "debug")
        engine["bom-ref"] = engine["purl"]
        with self.assertRaisesRegex(RuntimeError, "non-release Flutter engine"):
            validate_fixture(
                payload,
                {value["purl"] for value in payload["components"]},
            )

    def test_duplicate_group_name_identity_fails(self) -> None:
        payload = valid_payload()
        payload["components"].append(
            component("net.openid", "appauth", "0.11.2", "d" * 64)
        )
        with self.assertRaisesRegex(RuntimeError, "repeats a group/name identity"):
            validate_fixture(
                payload,
                {value["purl"] for value in payload["components"]},
            )

    def test_external_dependency_cannot_spoof_a_local_project(self) -> None:
        payload = valid_payload()
        spoofed = component(
            "example", "unlicensed", "1.0.0", "e" * 64, licensed=False
        )
        spoofed["purl"] = (
            "pkg:maven/example/unlicensed@1.0.0?project_path=%3Aunlicensed"
        )
        spoofed["bom-ref"] = spoofed["purl"]
        payload["components"].append(spoofed)
        with self.assertRaisesRegex(RuntimeError, "unreviewed local project identity"):
            validate_fixture(
                payload,
                {value["purl"] for value in payload["components"]},
            )

    def test_truncated_inventory_fails(self) -> None:
        payload = valid_payload()
        removed = payload["components"].pop()
        payload["dependencies"][0]["dependsOn"].remove(removed["purl"])
        payload["dependencies"] = [
            value for value in payload["dependencies"] if value["ref"] != removed["purl"]
        ]
        with self.assertRaisesRegex(RuntimeError, "reviewed production runtime inventory"):
            validate_fixture(payload)

    def test_unreachable_component_fails(self) -> None:
        payload = valid_payload()
        unreachable = payload["components"][0]["purl"]
        payload["dependencies"][0]["dependsOn"].remove(unreachable)
        with self.assertRaisesRegex(RuntimeError, "unreachable from the app release"):
            validate_fixture(payload)

    def test_dangling_dependency_ref_fails(self) -> None:
        payload = valid_payload()
        payload["dependencies"][0]["dependsOn"].append(
            "pkg:maven/example/missing@1.0.0?type=jar"
        )
        with self.assertRaisesRegex(RuntimeError, "dangling refs"):
            validate_fixture(payload)

    def test_root_application_identity_tamper_fails(self) -> None:
        payload = valid_payload()
        payload["metadata"]["component"]["name"] = "different-app"
        with self.assertRaisesRegex(RuntimeError, "metadata.component identity"):
            validate_fixture(payload)


if __name__ == "__main__":
    unittest.main()
