#!/usr/bin/env python3
"""Validate one selected Flutter device without retaining its identifier."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any


DEVICE_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}")
ANDROID_SDK = re.compile(
    r"Android ([0-9]{1,2}(?:\.[0-9]{1,2}){0,2}) \(API ([0-9]{1,3})\)"
)
IOS_SDK = re.compile(
    r"iOS ([0-9]{1,2}(?:\.[0-9]{1,2}){0,2})(?: [A-Za-z0-9]+)?"
)
ALLOWED_TARGETS = frozenset(
    {"android-arm", "android-arm64", "android-x64", "ios"}
)


class DeviceValidationError(ValueError):
    """The selected Flutter target is not a supported physical mobile device."""


@dataclass(frozen=True)
class PhysicalDevice:
    target_platform: str
    os_family: str
    os_version: str
    android_api_level: int | None = None


def validate_devices(payload: Any, expected_id: str) -> PhysicalDevice:
    if (
        not isinstance(expected_id, str)
        or DEVICE_ID.fullmatch(expected_id) is None
    ):
        raise DeviceValidationError("device ID contains unsupported characters")
    if not isinstance(payload, list):
        raise DeviceValidationError("flutter devices --machine did not return a list")
    if not all(isinstance(device, dict) for device in payload):
        raise DeviceValidationError("Flutter device entries must be objects")

    matches = [device for device in payload if device.get("id") == expected_id]
    if len(matches) != 1:
        raise DeviceValidationError("expected exactly one connected selected device")
    selected = matches[0]
    if selected.get("isSupported") is not True:
        raise DeviceValidationError("the selected Flutter device is unsupported")
    if selected.get("emulator") is not False:
        raise DeviceValidationError(
            "the physical-device lane rejects emulators and simulators"
        )

    target = selected.get("targetPlatform")
    if not isinstance(target, str) or target not in ALLOWED_TARGETS:
        raise DeviceValidationError(
            "the selected target is not a supported mobile platform"
        )
    sdk = selected.get("sdk")
    if not isinstance(sdk, str):
        raise DeviceValidationError("the selected physical device did not report an SDK")

    android = ANDROID_SDK.fullmatch(sdk)
    ios = IOS_SDK.fullmatch(sdk)
    if target.startswith("android-") and android is None:
        raise DeviceValidationError(
            "Android SDK did not match the sanitized version/API shape"
        )
    if target == "ios" and ios is None:
        raise DeviceValidationError("iOS SDK did not match the sanitized version shape")
    match = android or ios
    if match is None:
        raise DeviceValidationError("device SDK does not match its target platform")

    return PhysicalDevice(
        target_platform=target,
        os_family="android" if android else "ios",
        os_version=match.group(1),
        android_api_level=int(android.group(2)) if android else None,
    )


def validate_file(path: pathlib.Path, expected_id: str) -> PhysicalDevice:
    return validate_devices(json.loads(path.read_text(encoding="utf-8")), expected_id)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reject a selected Flutter target unless it is a physical mobile device."
    )
    parser.add_argument("devices_json", type=pathlib.Path)
    arguments = parser.parse_args()
    expected_id = os.environ.get("PAKPERK_MOBILE_DEVICE_ID", "")
    try:
        device = validate_file(arguments.devices_json, expected_id)
    except (DeviceValidationError, json.JSONDecodeError, OSError) as error:
        print(f"physical-device validation failed: {error}", file=sys.stderr)
        return 1
    api = (
        f" API {device.android_api_level}"
        if device.android_api_level is not None
        else ""
    )
    print(
        "Validated selected physical "
        f"{device.os_family} target ({device.os_version}{api}); identifier omitted."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
