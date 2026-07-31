#!/usr/bin/env python3
"""Reject clearly breaking removals from Pakperk's checked OpenAPI contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


HTTP_METHODS = {
    "get",
    "put",
    "post",
    "delete",
    "options",
    "head",
    "patch",
    "trace",
}


def load(path: str) -> dict[str, Any]:
    with Path(path).open(encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise ValueError(f"{path} does not contain a JSON object")
    return value


def compare_schema(
    old: Any,
    new: Any,
    location: str,
    failures: list[str],
) -> None:
    if not isinstance(old, dict) or not isinstance(new, dict):
        return

    old_enum = old.get("enum")
    new_enum = new.get("enum")
    if isinstance(old_enum, list) and isinstance(new_enum, list):
        removed_values = [value for value in old_enum if value not in new_enum]
        if removed_values:
            failures.append(f"{location}: removed enum values {removed_values!r}")

    old_properties = old.get("properties")
    new_properties = new.get("properties")
    if isinstance(old_properties, dict):
        if not isinstance(new_properties, dict):
            failures.append(f"{location}: removed all object properties")
        else:
            for name, old_property in old_properties.items():
                if name not in new_properties:
                    failures.append(f"{location}: removed property {name!r}")
                    continue
                compare_schema(
                    old_property,
                    new_properties[name],
                    f"{location}.{name}",
                    failures,
                )

    if "items" in old and "items" in new:
        compare_schema(old["items"], new["items"], f"{location}[]", failures)

    for composition in ("allOf", "anyOf", "oneOf"):
        old_variants = old.get(composition)
        new_variants = new.get(composition)
        if isinstance(old_variants, list) and isinstance(new_variants, list):
            if len(new_variants) < len(old_variants):
                failures.append(
                    f"{location}: {composition} narrowed from "
                    f"{len(old_variants)} to {len(new_variants)} variants"
                )
            for index, old_variant in enumerate(old_variants):
                if index < len(new_variants):
                    compare_schema(
                        old_variant,
                        new_variants[index],
                        f"{location}.{composition}[{index}]",
                        failures,
                    )


def compare_contracts(old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    failures: list[str] = []

    old_paths = old.get("paths", {})
    new_paths = new.get("paths", {})
    if isinstance(old_paths, dict) and isinstance(new_paths, dict):
        for path, old_path_item in old_paths.items():
            new_path_item = new_paths.get(path)
            if not isinstance(new_path_item, dict):
                failures.append(f"removed route {path}")
                continue
            if not isinstance(old_path_item, dict):
                continue
            for method, old_operation in old_path_item.items():
                if method.lower() not in HTTP_METHODS:
                    continue
                new_operation = new_path_item.get(method)
                if not isinstance(new_operation, dict):
                    failures.append(f"removed operation {method.upper()} {path}")
                    continue
                if not isinstance(old_operation, dict):
                    continue
                old_responses = old_operation.get("responses", {})
                new_responses = new_operation.get("responses", {})
                if isinstance(old_responses, dict) and isinstance(new_responses, dict):
                    for status in old_responses:
                        if status not in new_responses:
                            failures.append(
                                f"{method.upper()} {path}: removed response {status}"
                            )

    old_schemas = old.get("components", {}).get("schemas", {})
    new_schemas = new.get("components", {}).get("schemas", {})
    if isinstance(old_schemas, dict) and isinstance(new_schemas, dict):
        for name, old_schema in old_schemas.items():
            if name not in new_schemas:
                failures.append(f"removed component schema {name}")
                continue
            compare_schema(
                old_schema,
                new_schemas[name],
                f"components.schemas.{name}",
                failures,
            )

    return failures


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: check_openapi_compatibility.py OLD.json NEW.json",
            file=sys.stderr,
        )
        return 2
    failures = compare_contracts(load(sys.argv[1]), load(sys.argv[2]))
    if failures:
        print("OpenAPI backward-compatibility check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("OpenAPI backward-compatibility check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
