#!/usr/bin/env python3
"""Reject backward-incompatible changes to Pakperk's OpenAPI contract."""

from __future__ import annotations

import json
import math
import pathlib
import re
import subprocess
import sys
from fractions import Fraction
from typing import Any, Literal


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
SchemaMode = Literal["neutral", "request", "response"]
FULL_REVISION = re.compile(r"[0-9a-f]{40}")
RESPONSE_STATUS = re.compile(r"(?:default|[1-5](?:[0-9]{2}|XX))")
_MISSING = object()


def _object_without_duplicate_keys(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key {key!r}")
        value[key] = item
    return value


def _reject_non_json_number(value: str) -> None:
    raise ValueError(f"non-JSON numeric value {value!r}")


def _decode_contract(raw: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_object_without_duplicate_keys,
            parse_constant=_reject_non_json_number,
        )
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is not valid JSON: {error}") from error
    except ValueError as error:
        raise ValueError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} does not contain a JSON object")
    return value


def load(path: str | pathlib.Path) -> dict[str, Any]:
    contract = pathlib.Path(path)
    return _decode_contract(contract.read_text(encoding="utf-8"), str(contract))


def load_git_contract(
    repository: str | pathlib.Path,
    revision: str,
    relative_path: str,
) -> dict[str, Any]:
    """Load a historical contract and fail closed when the base is unavailable."""

    if FULL_REVISION.fullmatch(revision) is None:
        raise ValueError("OpenAPI base revision must be a full lowercase Git SHA")
    contract_path = pathlib.PurePosixPath(relative_path)
    if contract_path.is_absolute() or ".." in contract_path.parts:
        raise ValueError("OpenAPI base contract path must be repository-relative")
    repository_path = pathlib.Path(repository).resolve()
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repository_path),
            "show",
            f"{revision}:{contract_path.as_posix()}",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(
            "OpenAPI compatibility base is unavailable at "
            f"{revision}:{contract_path.as_posix()}"
        )
    return _decode_contract(
        result.stdout,
        f"{revision}:{contract_path.as_posix()}",
    )


def _local_reference(document: dict[str, Any], reference: str) -> Any:
    if reference == "#":
        return document
    if not reference.startswith("#/"):
        return None
    value: Any = document
    for raw_part in reference[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def _schema_types(schema: dict[str, Any]) -> frozenset[str] | None:
    value = schema.get("type")
    if isinstance(value, str):
        types = frozenset((value,))
    elif isinstance(value, list) and all(isinstance(item, str) for item in value):
        types = frozenset(value)
    else:
        return None
    if schema.get("nullable") is True:
        return types | {"null"}
    return types


def _compare_schema_type(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
) -> None:
    old_types = _schema_types(old)
    new_types = _schema_types(new)
    if old_types == new_types:
        return
    if old_types is None or new_types is None:
        if "type" in old or "type" in new:
            failures.append(
                f"{location}: changed schema type from {old.get('type')!r} "
                f"to {new.get('type')!r}"
            )
        return
    if mode == "request" and old_types.issubset(new_types):
        return
    if mode == "response" and new_types.issubset(old_types):
        return
    failures.append(
        f"{location}: changed schema type from {sorted(old_types)!r} "
        f"to {sorted(new_types)!r}"
    )


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value)


def _stricter_bound(
    left: tuple[int | float, bool] | None,
    right: tuple[int | float, bool] | None,
    *,
    lower: bool,
) -> bool:
    """Return whether left excludes values accepted by right."""

    if left is None:
        return False
    if right is None:
        return True
    left_value, left_exclusive = left
    right_value, right_exclusive = right
    if left_value == right_value:
        return left_exclusive and not right_exclusive
    return left_value > right_value if lower else left_value < right_value


def _effective_bound(
    schema: dict[str, Any], *, lower: bool
) -> tuple[int | float, bool] | None:
    inclusive_key = "minimum" if lower else "maximum"
    exclusive_key = "exclusiveMinimum" if lower else "exclusiveMaximum"
    candidates: list[tuple[int | float, bool]] = []
    inclusive = schema.get(inclusive_key)
    exclusive = schema.get(exclusive_key)
    if _is_number(inclusive):
        candidates.append((inclusive, exclusive is True))
    if _is_number(exclusive):
        candidates.append((exclusive, True))
    result: tuple[int | float, bool] | None = None
    for candidate in candidates:
        if result is None or _stricter_bound(candidate, result, lower=lower):
            result = candidate
    return result


def _compare_numeric_bounds(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
) -> None:
    for lower in (True, False):
        old_bound = _effective_bound(old, lower=lower)
        new_bound = _effective_bound(new, lower=lower)
        if old_bound == new_bound:
            continue
        if mode == "request":
            incompatible = _stricter_bound(new_bound, old_bound, lower=lower)
        elif mode == "response":
            incompatible = _stricter_bound(old_bound, new_bound, lower=lower)
        else:
            incompatible = True
        if incompatible:
            name = "lower" if lower else "upper"
            failures.append(
                f"{location}: {mode} schema {name} bound changed "
                f"from {old_bound!r} to {new_bound!r}"
            )


def _limit_value(schema: dict[str, Any], keyword: str, default: float) -> int | float:
    if keyword not in schema:
        return default
    value = schema[keyword]
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return math.nan


def _compare_cardinality_limits(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
) -> None:
    for minimum, maximum in (
        ("minLength", "maxLength"),
        ("minItems", "maxItems"),
        ("minProperties", "maxProperties"),
    ):
        for keyword, lower, default in (
            (minimum, True, 0.0),
            (maximum, False, math.inf),
        ):
            old_value = _limit_value(old, keyword, default)
            new_value = _limit_value(new, keyword, default)
            if old_value == new_value:
                continue
            old_malformed = isinstance(old_value, float) and math.isnan(old_value)
            new_malformed = isinstance(new_value, float) and math.isnan(new_value)
            if old_malformed or new_malformed:
                failures.append(f"{location}: changed malformed {keyword} constraint")
                continue
            if mode == "request":
                incompatible = new_value > old_value if lower else new_value < old_value
            elif mode == "response":
                incompatible = new_value < old_value if lower else new_value > old_value
            else:
                incompatible = True
            if incompatible:
                failures.append(
                    f"{location}: {mode} schema {keyword} changed "
                    f"from {old_value:g} to {new_value:g}"
                )


def _compare_pattern_and_uniqueness(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
) -> None:
    old_pattern = old.get("pattern", _MISSING)
    new_pattern = new.get("pattern", _MISSING)
    if old_pattern != new_pattern:
        if mode == "request":
            incompatible = new_pattern is not _MISSING
        elif mode == "response":
            incompatible = old_pattern is not _MISSING
        else:
            incompatible = True
        if incompatible:
            failures.append(f"{location}: changed {mode} schema pattern")

    old_unique = old.get("uniqueItems", False) is True
    new_unique = new.get("uniqueItems", False) is True
    if old_unique != new_unique:
        incompatible = (
            (mode == "request" and new_unique)
            or (mode == "response" and old_unique)
            or mode == "neutral"
        )
        if incompatible:
            failures.append(f"{location}: changed {mode} schema uniqueItems")


def _multiple_of(value: Any) -> Fraction | None:
    if not _is_number(value) or value <= 0:
        return None
    return Fraction(str(value))


def _compare_multiple_of(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
) -> None:
    old_present = "multipleOf" in old
    new_present = "multipleOf" in new
    old_value = _multiple_of(old.get("multipleOf"))
    new_value = _multiple_of(new.get("multipleOf"))
    if not old_present and not new_present:
        return
    if old_present and old_value is None or new_present and new_value is None:
        if old.get("multipleOf", _MISSING) != new.get("multipleOf", _MISSING):
            failures.append(f"{location}: changed malformed multipleOf constraint")
        return
    if old_value == new_value:
        return
    if mode == "request":
        compatible = new_value is None or (
            old_value is not None
            and new_value is not None
            and (old_value / new_value).denominator == 1
        )
    elif mode == "response":
        compatible = old_value is None or (
            old_value is not None
            and new_value is not None
            and (new_value / old_value).denominator == 1
        )
    else:
        compatible = False
    if not compatible:
        failures.append(
            f"{location}: incompatible {mode} multipleOf change "
            f"from {old_value!r} to {new_value!r}"
        )


def _compare_additional_properties(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
    old_document: dict[str, Any] | None,
    new_document: dict[str, Any] | None,
    seen_references: set[tuple[SchemaMode, str, str]] | None,
) -> None:
    old_extra = old.get("additionalProperties", True)
    new_extra = new.get("additionalProperties", True)
    if old_extra == new_extra:
        return

    if isinstance(old_extra, dict) and isinstance(new_extra, dict):
        compare_schema(
            old_extra,
            new_extra,
            f"{location}.*",
            failures,
            mode=mode,
            old_document=old_document,
            new_document=new_document,
            seen_references=seen_references,
        )
        return

    if mode == "request":
        incompatible = (old_extra is True and new_extra is not True) or (
            isinstance(old_extra, dict) and new_extra is False
        )
    elif mode == "response":
        incompatible = (old_extra is False and new_extra is not False) or (
            isinstance(old_extra, dict) and new_extra is True
        )
    else:
        incompatible = True
    if incompatible:
        failures.append(
            f"{location}: changed {mode} additionalProperties from "
            f"{old_extra!r} to {new_extra!r}"
        )


def _canonical_schema(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _composition_remainders(
    old_variants: list[Any], new_variants: list[Any]
) -> tuple[list[Any], list[Any]]:
    old_by_key: dict[str, list[Any]] = {}
    new_by_key: dict[str, list[Any]] = {}
    for variant in old_variants:
        old_by_key.setdefault(_canonical_schema(variant), []).append(variant)
    for variant in new_variants:
        new_by_key.setdefault(_canonical_schema(variant), []).append(variant)
    for key in set(old_by_key) & set(new_by_key):
        common = min(len(old_by_key[key]), len(new_by_key[key]))
        del old_by_key[key][:common]
        del new_by_key[key][:common]
    old_remaining = [
        variant for key in sorted(old_by_key) for variant in old_by_key[key]
    ]
    new_remaining = [
        variant for key in sorted(new_by_key) for variant in new_by_key[key]
    ]
    return old_remaining, new_remaining


def _compare_composition(
    composition: str,
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    mode: SchemaMode,
    old_document: dict[str, Any] | None,
    new_document: dict[str, Any] | None,
    seen_references: set[tuple[SchemaMode, str, str]] | None,
) -> None:
    old_variants = old.get(composition)
    new_variants = new.get(composition)
    if old_variants is None and new_variants is None:
        return
    if not isinstance(old_variants, list) or not isinstance(new_variants, list):
        if old_variants is None and isinstance(new_variants, list):
            incompatible = mode in ("request", "neutral")
        elif isinstance(old_variants, list) and new_variants is None:
            incompatible = mode in ("response", "neutral")
        else:
            incompatible = True
        if incompatible:
            failures.append(f"{location}: changed {composition} schema")
        return

    old_remaining, new_remaining = _composition_remainders(old_variants, new_variants)
    if composition == "allOf":
        incompatible_cardinality = (
            mode == "request" and len(new_remaining) > len(old_remaining)
        ) or (mode == "response" and len(old_remaining) > len(new_remaining))
    else:
        incompatible_cardinality = (
            mode == "request" and len(old_remaining) > len(new_remaining)
        ) or (mode == "response" and len(new_remaining) > len(old_remaining))
    if mode == "neutral":
        incompatible_cardinality = len(old_remaining) != len(new_remaining)
    if incompatible_cardinality:
        failures.append(f"{location}: incompatible {mode} {composition} variant change")

    for index, (old_variant, new_variant) in enumerate(
        zip(old_remaining, new_remaining)
    ):
        compare_schema(
            old_variant,
            new_variant,
            f"{location}.{composition}[{index}]",
            failures,
            mode=mode,
            old_document=old_document,
            new_document=new_document,
            seen_references=seen_references,
        )


def compare_schema(
    old: Any,
    new: Any,
    location: str,
    failures: list[str],
    *,
    mode: SchemaMode = "neutral",
    old_document: dict[str, Any] | None = None,
    new_document: dict[str, Any] | None = None,
    seen_references: set[tuple[SchemaMode, str, str]] | None = None,
) -> None:
    if not isinstance(old, dict) or not isinstance(new, dict):
        if old != new:
            failures.append(f"{location}: changed schema shape")
        return

    old_reference = old.get("$ref")
    new_reference = new.get("$ref")
    if old_reference != new_reference and (
        isinstance(old_reference, str) or isinstance(new_reference, str)
    ):
        failures.append(
            f"{location}: changed schema reference from {old_reference!r} "
            f"to {new_reference!r}"
        )
        return
    if (
        isinstance(old_reference, str)
        and isinstance(new_reference, str)
        and old_document is not None
        and new_document is not None
    ):
        seen = seen_references if seen_references is not None else set()
        reference_pair = (mode, old_reference, new_reference)
        if reference_pair not in seen:
            seen.add(reference_pair)
            old_target = _local_reference(old_document, old_reference)
            new_target = _local_reference(new_document, new_reference)
            if old_target is not None and new_target is None:
                failures.append(f"{location}: schema reference target was removed")
            elif old_target is not None and new_target is not None:
                compare_schema(
                    old_target,
                    new_target,
                    f"{location}->{old_reference}",
                    failures,
                    mode=mode,
                    old_document=old_document,
                    new_document=new_document,
                    seen_references=seen,
                )

    _compare_schema_type(old, new, location, failures, mode)

    _compare_numeric_bounds(old, new, location, failures, mode)
    _compare_cardinality_limits(old, new, location, failures, mode)
    _compare_pattern_and_uniqueness(old, new, location, failures, mode)
    _compare_multiple_of(old, new, location, failures, mode)

    if old.get("format") != new.get("format") and ("format" in old or "format" in new):
        failures.append(
            f"{location}: changed schema format from {old.get('format')!r} "
            f"to {new.get('format')!r}"
        )

    old_enum = old.get("enum")
    new_enum = new.get("enum")
    if isinstance(old_enum, list) and isinstance(new_enum, list):
        removed_values = [value for value in old_enum if value not in new_enum]
        added_values = [value for value in new_enum if value not in old_enum]
        incompatible_values = added_values if mode == "response" else removed_values
        if incompatible_values:
            action = "added" if mode == "response" else "removed"
            failures.append(f"{location}: {action} enum values {incompatible_values!r}")
    elif isinstance(old_enum, list) and new_enum is None:
        if mode in ("response", "neutral"):
            failures.append(f"{location}: removed response enum constraint")
    elif old_enum is None and isinstance(new_enum, list):
        if mode in ("request", "neutral"):
            failures.append(f"{location}: added request enum constraint")

    old_const = old.get("const", _MISSING)
    new_const = new.get("const", _MISSING)
    if old_const != new_const:
        if mode == "request":
            incompatible_const = new_const is not _MISSING
        elif mode == "response":
            incompatible_const = old_const is not _MISSING
        else:
            incompatible_const = True
        if incompatible_const:
            failures.append(f"{location}: changed {mode} schema const")

    old_required = {item for item in old.get("required", []) if isinstance(item, str)}
    new_required = {item for item in new.get("required", []) if isinstance(item, str)}
    if mode == "request":
        newly_required = sorted(new_required - old_required)
        if newly_required:
            failures.append(
                f"{location}: added required request properties {newly_required!r}"
            )
    elif mode == "response":
        no_longer_required = sorted(old_required - new_required)
        if no_longer_required:
            failures.append(
                f"{location}: response properties are no longer required "
                f"{no_longer_required!r}"
            )

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
                    mode=mode,
                    old_document=old_document,
                    new_document=new_document,
                    seen_references=seen_references,
                )

    _compare_additional_properties(
        old,
        new,
        location,
        failures,
        mode,
        old_document,
        new_document,
        seen_references,
    )

    if "items" in old and "items" in new:
        compare_schema(
            old["items"],
            new["items"],
            f"{location}[]",
            failures,
            mode=mode,
            old_document=old_document,
            new_document=new_document,
            seen_references=seen_references,
        )
    elif "items" in old and mode in ("response", "neutral"):
        failures.append(f"{location}: removed array item schema")
    elif "items" in new and mode in ("request", "neutral"):
        failures.append(f"{location}: added array item schema")

    for composition in ("allOf", "anyOf", "oneOf"):
        _compare_composition(
            composition,
            old,
            new,
            location,
            failures,
            mode,
            old_document,
            new_document,
            seen_references,
        )

    if old.get("discriminator", _MISSING) != new.get("discriminator", _MISSING):
        failures.append(f"{location}: changed schema discriminator")


def _resolved_object(document: dict[str, Any], value: Any) -> Any:
    seen: set[str] = set()
    while isinstance(value, dict):
        reference = value.get("$ref")
        if not isinstance(reference, str) or reference in seen:
            return value
        seen.add(reference)
        resolved = _local_reference(document, reference)
        if resolved is None:
            return value
        value = resolved
    return value


def _validate_schema_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen: set[int],
) -> None:
    if isinstance(raw, bool):
        return
    schema = _resolved_object(document, raw)
    if not isinstance(schema, dict):
        failures.append(f"{location}: schema is not an object or boolean")
        return
    identity = id(schema)
    if identity in seen:
        return
    seen.add(identity)

    schema_type = schema.get("type", _MISSING)
    if schema_type is not _MISSING and not (
        isinstance(schema_type, str)
        or (
            isinstance(schema_type, list)
            and schema_type
            and all(isinstance(item, str) for item in schema_type)
        )
    ):
        failures.append(f"{location}: malformed schema type")
    for keyword in (
        "minimum",
        "maximum",
    ):
        if keyword in schema and not _is_number(schema[keyword]):
            failures.append(f"{location}: malformed {keyword} constraint")
    for keyword in ("exclusiveMinimum", "exclusiveMaximum"):
        if keyword in schema and not (
            isinstance(schema[keyword], bool) or _is_number(schema[keyword])
        ):
            failures.append(f"{location}: malformed {keyword} constraint")
    for keyword in (
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
    ):
        value = schema.get(keyword, 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            failures.append(f"{location}: malformed {keyword} constraint")
    if "multipleOf" in schema and _multiple_of(schema["multipleOf"]) is None:
        failures.append(f"{location}: malformed multipleOf constraint")
    if "pattern" in schema and not isinstance(schema["pattern"], str):
        failures.append(f"{location}: malformed pattern constraint")
    for keyword in ("nullable", "uniqueItems"):
        if keyword in schema and not isinstance(schema[keyword], bool):
            failures.append(f"{location}: malformed {keyword} constraint")
    if "enum" in schema and not isinstance(schema["enum"], list):
        failures.append(f"{location}: malformed enum constraint")

    properties = schema.get("properties")
    if properties is not None:
        if not isinstance(properties, dict):
            failures.append(f"{location}: malformed schema properties")
        else:
            for name, child in properties.items():
                _validate_schema_shape(
                    document, child, f"{location}.{name}", failures, seen
                )
    extra = schema.get("additionalProperties", True)
    if not isinstance(extra, (bool, dict)):
        failures.append(f"{location}: malformed additionalProperties")
    elif isinstance(extra, dict):
        _validate_schema_shape(document, extra, f"{location}.*", failures, seen)
    if "items" in schema:
        _validate_schema_shape(
            document, schema["items"], f"{location}[]", failures, seen
        )
    for composition in ("allOf", "anyOf", "oneOf"):
        variants = schema.get(composition)
        if variants is None:
            continue
        if not isinstance(variants, list) or not variants:
            failures.append(f"{location}: malformed {composition} schema")
            continue
        for index, variant in enumerate(variants):
            _validate_schema_shape(
                document,
                variant,
                f"{location}.{composition}[{index}]",
                failures,
                seen,
            )
    discriminator = schema.get("discriminator")
    if discriminator is not None:
        if not isinstance(discriminator, dict) or not isinstance(
            discriminator.get("propertyName"), str
        ):
            failures.append(f"{location}: malformed discriminator")
        else:
            mapping = discriminator.get("mapping", {})
            if not isinstance(mapping, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in mapping.items()
            ):
                failures.append(f"{location}: malformed discriminator mapping")
            else:
                for value in mapping.values():
                    if (
                        value.startswith("#")
                        and _local_reference(document, value) is None
                    ):
                        failures.append(
                            f"{location}: unresolved discriminator mapping {value!r}"
                        )


def _validate_content_shape(
    document: dict[str, Any],
    owner: dict[str, Any],
    location: str,
    failures: list[str],
    seen_schemas: set[int],
) -> None:
    if "content" not in owner:
        return
    content = owner["content"]
    if not isinstance(content, dict):
        failures.append(f"{location}: content is not an object")
        return
    for media_type, media in content.items():
        if not isinstance(media_type, str) or not isinstance(media, dict):
            failures.append(f"{location}: malformed media type object")
            continue
        if "schema" in media:
            _validate_schema_shape(
                document,
                media["schema"],
                f"{location} {media_type}",
                failures,
                seen_schemas,
            )


def _validate_parameter_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen_schemas: set[int],
) -> None:
    parameter = _resolved_object(document, raw)
    if not isinstance(parameter, dict):
        failures.append(f"{location}: parameter/header is not an object")
        return
    if "schema" not in parameter and "content" not in parameter:
        failures.append(f"{location}: parameter/header has no schema or content")
    if "schema" in parameter and "content" in parameter:
        failures.append(f"{location}: parameter/header has both schema and content")
    for keyword in ("required", "explode", "allowReserved", "allowEmptyValue"):
        if keyword in parameter and not isinstance(parameter[keyword], bool):
            failures.append(f"{location}: malformed parameter/header {keyword}")
    if "style" in parameter and not isinstance(parameter["style"], str):
        failures.append(f"{location}: malformed parameter/header style")
    if "schema" in parameter:
        _validate_schema_shape(
            document,
            parameter["schema"],
            f"{location}.schema",
            failures,
            seen_schemas,
        )
    if "content" in parameter:
        content = parameter["content"]
        if isinstance(content, dict) and len(content) != 1:
            failures.append(
                f"{location}: parameter/header content must have one media type"
            )
        _validate_content_shape(document, parameter, location, failures, seen_schemas)


def _validate_response_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen_schemas: set[int],
) -> None:
    response = _resolved_object(document, raw)
    if not isinstance(response, dict):
        failures.append(f"{location}: response is not an object")
        return
    _validate_content_shape(document, response, location, failures, seen_schemas)
    headers = response.get("headers")
    if headers is not None:
        if not isinstance(headers, dict):
            failures.append(f"{location}: response headers are not an object")
        else:
            folded: set[str] = set()
            for name, header in headers.items():
                normalized = name.casefold() if isinstance(name, str) else ""
                if not normalized or normalized in folded:
                    failures.append(f"{location}: duplicate/malformed response header")
                folded.add(normalized)
                _validate_parameter_shape(
                    document,
                    header,
                    f"{location} header {name!r}",
                    failures,
                    seen_schemas,
                )


def _validate_request_body_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen_schemas: set[int],
) -> None:
    body = _resolved_object(document, raw)
    if not isinstance(body, dict):
        failures.append(f"{location}: request body is not an object")
        return
    _validate_content_shape(document, body, location, failures, seen_schemas)


def _validate_callback_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen_objects: set[int],
    seen_schemas: set[int],
) -> None:
    callback = _resolved_object(document, raw)
    if not isinstance(callback, dict):
        failures.append(f"{location}: callback is not an object")
        return
    for expression, path_item in callback.items():
        if expression == "$ref":
            continue
        _validate_path_item_shape(
            document,
            path_item,
            f"{location} expression {expression!r}",
            failures,
            seen_objects,
            seen_schemas,
        )


def _validate_operation_shape(
    document: dict[str, Any],
    operation: dict[str, Any],
    location: str,
    failures: list[str],
    seen_objects: set[int],
    seen_schemas: set[int],
) -> None:
    parameters = operation.get("parameters")
    if parameters is not None:
        if not isinstance(parameters, list):
            failures.append(f"{location}: parameters are not an array")
        else:
            for index, parameter in enumerate(parameters):
                _validate_parameter_shape(
                    document,
                    parameter,
                    f"{location} parameter[{index}]",
                    failures,
                    seen_schemas,
                )
    if "requestBody" in operation:
        _validate_request_body_shape(
            document,
            operation["requestBody"],
            f"{location} request body",
            failures,
            seen_schemas,
        )
    responses = operation.get("responses")
    if responses is not None:
        if not isinstance(responses, dict):
            failures.append(f"{location}: responses are not an object")
        else:
            for status, response in responses.items():
                if (
                    not isinstance(status, str)
                    or RESPONSE_STATUS.fullmatch(status) is None
                ):
                    failures.append(f"{location}: malformed response status {status!r}")
                _validate_response_shape(
                    document,
                    response,
                    f"{location} response {status}",
                    failures,
                    seen_schemas,
                )
    callbacks = operation.get("callbacks")
    if callbacks is not None:
        if not isinstance(callbacks, dict):
            failures.append(f"{location}: callbacks are not an object")
        else:
            for name, callback in callbacks.items():
                _validate_callback_shape(
                    document,
                    callback,
                    f"{location} callback {name!r}",
                    failures,
                    seen_objects,
                    seen_schemas,
                )


def _validate_path_item_shape(
    document: dict[str, Any],
    raw: Any,
    location: str,
    failures: list[str],
    seen_objects: set[int],
    seen_schemas: set[int],
) -> None:
    path_item = _resolved_object(document, raw)
    if not isinstance(path_item, dict):
        failures.append(f"{location}: Path Item is not an object")
        return
    identity = id(path_item)
    if identity in seen_objects:
        return
    seen_objects.add(identity)
    parameters = path_item.get("parameters")
    if parameters is not None:
        if not isinstance(parameters, list):
            failures.append(f"{location}: parameters are not an array")
        else:
            for index, parameter in enumerate(parameters):
                _validate_parameter_shape(
                    document,
                    parameter,
                    f"{location} parameter[{index}]",
                    failures,
                    seen_schemas,
                )
    for method, operation in path_item.items():
        if method.lower() not in HTTP_METHODS:
            continue
        if not isinstance(operation, dict):
            failures.append(f"{location}: operation {method.upper()} is not an object")
            continue
        _validate_operation_shape(
            document,
            operation,
            f"{method.upper()} {location}",
            failures,
            seen_objects,
            seen_schemas,
        )


def _validate_document(document: dict[str, Any], label: str) -> list[str]:
    failures: list[str] = []

    def walk(value: Any, location: str) -> None:
        if isinstance(value, dict):
            if "$ref" in value:
                reference = value["$ref"]
                if not isinstance(reference, str):
                    failures.append(f"{label} {location}: $ref is not a string")
                elif not reference.startswith("#"):
                    failures.append(
                        f"{label} {location}: unsupported external reference {reference!r}"
                    )
                elif _local_reference(document, reference) is None:
                    failures.append(
                        f"{label} {location}: unresolved reference {reference!r}"
                    )
            for key, item in value.items():
                walk(item, f"{location}/{key}")
        elif isinstance(value, list):
            for index, item in enumerate(value):
                walk(item, f"{location}/{index}")
        elif isinstance(value, float) and not math.isfinite(value):
            failures.append(f"{label} {location}: non-finite number")

    walk(document, "#")
    seen_objects: set[int] = set()
    seen_schemas: set[int] = set()
    for map_name in ("paths", "webhooks"):
        path_map = document.get(map_name, {})
        if not isinstance(path_map, dict):
            failures.append(f"{label}: {map_name} is not an object")
            continue
        for path, path_item in path_map.items():
            _validate_path_item_shape(
                document,
                path_item,
                f"{map_name}.{path}",
                failures,
                seen_objects,
                seen_schemas,
            )

    components = document.get("components", {})
    if not isinstance(components, dict):
        failures.append(f"{label}: components is not an object")
        return failures
    schemas = components.get("schemas", {})
    if not isinstance(schemas, dict):
        failures.append(f"{label}: components.schemas is not an object")
    else:
        for name, schema in schemas.items():
            _validate_schema_shape(
                document,
                schema,
                f"components.schemas.{name}",
                failures,
                seen_schemas,
            )
    for component_name, validator in (
        ("parameters", _validate_parameter_shape),
        ("headers", _validate_parameter_shape),
        ("requestBodies", _validate_request_body_shape),
        ("responses", _validate_response_shape),
    ):
        values = components.get(component_name, {})
        if not isinstance(values, dict):
            failures.append(f"{label}: components.{component_name} is not an object")
            continue
        for name, value in values.items():
            validator(
                document,
                value,
                f"components.{component_name}.{name}",
                failures,
                seen_schemas,
            )
    callbacks = components.get("callbacks", {})
    if not isinstance(callbacks, dict):
        failures.append(f"{label}: components.callbacks is not an object")
    else:
        for name, callback in callbacks.items():
            _validate_callback_shape(
                document,
                callback,
                f"components.callbacks.{name}",
                failures,
                seen_objects,
                seen_schemas,
            )
    path_items = components.get("pathItems", {})
    if not isinstance(path_items, dict):
        failures.append(f"{label}: components.pathItems is not an object")
    else:
        for name, path_item in path_items.items():
            _validate_path_item_shape(
                document,
                path_item,
                f"components.pathItems.{name}",
                failures,
                seen_objects,
                seen_schemas,
            )
    return failures


def _compare_reference(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
) -> bool:
    old_reference = old.get("$ref")
    new_reference = new.get("$ref")
    if old_reference == new_reference:
        return False
    if isinstance(old_reference, str) or isinstance(new_reference, str):
        failures.append(
            f"{location}: changed reference from {old_reference!r} "
            f"to {new_reference!r}"
        )
        return True
    return False


def _compare_content(
    old: dict[str, Any],
    new: dict[str, Any],
    location: str,
    failures: list[str],
    *,
    mode: Literal["request", "response"],
    old_document: dict[str, Any],
    new_document: dict[str, Any],
) -> None:
    old_content = old.get("content", {})
    new_content = new.get("content", {})
    if not isinstance(old_content, dict):
        return
    if not isinstance(new_content, dict):
        failures.append(f"{location}: removed all {mode} media types")
        return
    for media_type, old_media in old_content.items():
        new_media = new_content.get(media_type)
        if not isinstance(new_media, dict):
            failures.append(f"{location}: removed {mode} media type {media_type!r}")
            continue
        if not isinstance(old_media, dict):
            continue
        if "schema" in old_media and "schema" in new_media:
            compare_schema(
                old_media["schema"],
                new_media["schema"],
                f"{location} {media_type}",
                failures,
                mode=mode,
                old_document=old_document,
                new_document=new_document,
            )
        elif "schema" in old_media and mode == "response":
            failures.append(f"{location} {media_type}: removed response schema")
        elif "schema" in new_media and mode == "request":
            failures.append(f"{location} {media_type}: added request schema constraint")


def _parameter_key(document: dict[str, Any], value: Any) -> tuple[str, str] | None:
    resolved = _resolved_object(document, value)
    if not isinstance(resolved, dict):
        return None
    name = resolved.get("name")
    location = resolved.get("in")
    if isinstance(name, str) and isinstance(location, str):
        return (location, name)
    reference = value.get("$ref") if isinstance(value, dict) else None
    if isinstance(reference, str):
        return ("$ref", reference)
    return None


def _effective_parameters(
    document: dict[str, Any],
    path_item: dict[str, Any],
    operation: dict[str, Any],
) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for owner in (path_item, operation):
        parameters = owner.get("parameters", [])
        if not isinstance(parameters, list):
            continue
        for parameter in parameters:
            key = _parameter_key(document, parameter)
            if key is not None and isinstance(parameter, dict):
                result[key] = parameter
    return result


def _compare_parameter(
    old_raw: dict[str, Any],
    new_raw: dict[str, Any],
    location: str,
    failures: list[str],
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    *,
    mode: Literal["request", "response"] = "request",
) -> None:
    if _compare_reference(old_raw, new_raw, location, failures):
        return
    old = _resolved_object(old_document, old_raw)
    new = _resolved_object(new_document, new_raw)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return
    old_required = old.get("required", False) is True
    new_required = new.get("required", False) is True
    if (mode == "request" and not old_required and new_required) or (
        mode == "response" and old_required and not new_required
    ):
        if mode == "request":
            failures.append(f"{location}: parameter became required")
        else:
            failures.append(f"{location}: response parameter became optional")

    def serialization(parameter: dict[str, Any]) -> dict[str, Any]:
        parameter_location = parameter.get("in", "header")
        default_style = {
            "query": "form",
            "cookie": "form",
            "path": "simple",
            "header": "simple",
        }.get(parameter_location)
        style = parameter.get("style", default_style)
        return {
            "style": style,
            "explode": parameter.get("explode", style == "form"),
            "allowReserved": parameter.get("allowReserved", False),
        }

    old_serialization = serialization(old)
    new_serialization = serialization(new)
    for field in ("style", "explode", "allowReserved"):
        if old_serialization[field] != new_serialization[field]:
            failures.append(
                f"{location}: changed parameter {field} from "
                f"{old_serialization[field]!r} to {new_serialization[field]!r}"
            )
    if (
        mode == "request"
        and old.get("allowEmptyValue", False) is True
        and new.get("allowEmptyValue", False) is not True
    ):
        failures.append(f"{location}: parameter no longer allows an empty value")
    if "schema" in old:
        if "schema" not in new:
            failures.append(f"{location}: removed parameter schema")
        else:
            compare_schema(
                old["schema"],
                new["schema"],
                f"{location}.schema",
                failures,
                mode=mode,
                old_document=old_document,
                new_document=new_document,
            )
    _compare_content(
        old,
        new,
        location,
        failures,
        mode=mode,
        old_document=old_document,
        new_document=new_document,
    )


def _compare_parameters(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_path_item: dict[str, Any],
    new_path_item: dict[str, Any],
    old_operation: dict[str, Any],
    new_operation: dict[str, Any],
    location: str,
    failures: list[str],
    *,
    mode: Literal["request", "response"] = "request",
) -> None:
    old_parameters = _effective_parameters(old_document, old_path_item, old_operation)
    new_parameters = _effective_parameters(new_document, new_path_item, new_operation)
    for key, old_parameter in old_parameters.items():
        if key not in new_parameters:
            failures.append(f"{location}: removed parameter {key[0]} {key[1]!r}")
            continue
        _compare_parameter(
            old_parameter,
            new_parameters[key],
            f"{location} parameter {key[0]} {key[1]!r}",
            failures,
            old_document,
            new_document,
            mode=mode,
        )
    for key, new_parameter in new_parameters.items():
        if key in old_parameters:
            continue
        resolved = _resolved_object(new_document, new_parameter)
        if (
            mode == "request"
            and isinstance(resolved, dict)
            and resolved.get("required", False) is True
        ):
            failures.append(f"{location}: added required parameter {key[0]} {key[1]!r}")


def _compare_request_body(
    old_raw: Any,
    new_raw: Any,
    location: str,
    failures: list[str],
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    *,
    mode: Literal["request", "response"] = "request",
) -> None:
    if not isinstance(old_raw, dict):
        if isinstance(new_raw, dict):
            resolved = _resolved_object(new_document, new_raw)
            if (
                mode == "request"
                and isinstance(resolved, dict)
                and resolved.get("required", False) is True
            ):
                failures.append(f"{location}: added a required request body")
        return
    if not isinstance(new_raw, dict):
        failures.append(f"{location}: removed request body")
        return
    if _compare_reference(old_raw, new_raw, f"{location} request body", failures):
        return
    old = _resolved_object(old_document, old_raw)
    new = _resolved_object(new_document, new_raw)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return
    old_required = old.get("required", False) is True
    new_required = new.get("required", False) is True
    if (mode == "request" and not old_required and new_required) or (
        mode == "response" and old_required and not new_required
    ):
        if mode == "request":
            failures.append(f"{location}: request body became required")
        else:
            failures.append(f"{location}: emitted request body became optional")
    _compare_content(
        old,
        new,
        f"{location} request body",
        failures,
        mode=mode,
        old_document=old_document,
        new_document=new_document,
    )


def _compare_response(
    old_raw: Any,
    new_raw: Any,
    location: str,
    failures: list[str],
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    *,
    mode: Literal["request", "response"] = "response",
) -> None:
    if not isinstance(old_raw, dict) or not isinstance(new_raw, dict):
        if old_raw != new_raw:
            failures.append(f"{location}: changed response shape")
        return
    if _compare_reference(old_raw, new_raw, location, failures):
        return
    old = _resolved_object(old_document, old_raw)
    new = _resolved_object(new_document, new_raw)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return
    _compare_content(
        old,
        new,
        location,
        failures,
        mode=mode,
        old_document=old_document,
        new_document=new_document,
    )
    old_headers = old.get("headers", {})
    new_headers = new.get("headers", {})
    if isinstance(old_headers, dict):
        if not isinstance(new_headers, dict):
            failures.append(f"{location}: removed all response headers")
        else:
            new_header_names = {
                name.casefold(): name for name in new_headers if isinstance(name, str)
            }
            for name, old_header in old_headers.items():
                matched_name = new_header_names.get(name.casefold())
                new_header = (
                    new_headers.get(matched_name) if matched_name is not None else None
                )
                if not isinstance(new_header, dict):
                    failures.append(f"{location}: removed response header {name!r}")
                    continue
                _compare_parameter(
                    old_header,
                    new_header,
                    f"{location} header {name!r}",
                    failures,
                    old_document,
                    new_document,
                    mode=mode,
                )


def _effective_security(
    document: dict[str, Any], operation: dict[str, Any]
) -> list[dict[str, set[str]]] | None:
    raw = operation.get("security", document.get("security"))
    if raw is None or raw == []:
        return [{}]
    if not isinstance(raw, list):
        return None
    requirements: list[dict[str, set[str]]] = []
    for requirement in raw:
        if not isinstance(requirement, dict):
            return None
        normalized: dict[str, set[str]] = {}
        for scheme, scopes in requirement.items():
            if (
                not isinstance(scheme, str)
                or not isinstance(scopes, list)
                or not all(isinstance(scope, str) for scope in scopes)
            ):
                return None
            normalized[scheme] = set(scopes)
        requirements.append(normalized)
    return requirements


def _security_requirement_accepts_old_clients(
    old: dict[str, set[str]], new: dict[str, set[str]]
) -> bool:
    return set(new).issubset(old) and all(
        new[scheme].issubset(old[scheme]) for scheme in new
    )


def _compare_security(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_operation: dict[str, Any],
    new_operation: dict[str, Any],
    location: str,
    failures: list[str],
) -> None:
    old = _effective_security(old_document, old_operation)
    new = _effective_security(new_document, new_operation)
    if old is None or new is None:
        if old != new:
            failures.append(f"{location}: changed malformed security requirements")
        return
    for old_requirement in old:
        if not any(
            _security_requirement_accepts_old_clients(old_requirement, candidate)
            for candidate in new
        ):
            failures.append(f"{location}: security requirements became stricter")
            return


def _component_map(document: dict[str, Any], name: str) -> dict[str, Any]:
    components = document.get("components", {})
    if not isinstance(components, dict):
        return {}
    values = components.get(name, {})
    return values if isinstance(values, dict) else {}


def _reachable_schema_components(document: dict[str, Any]) -> set[str]:
    """Find schema components reached from public paths, callbacks, or webhooks."""

    prefix = "#/components/schemas/"
    result: set[str] = set()
    seen: set[int] = set()

    def visit(value: Any) -> None:
        if not isinstance(value, (dict, list)):
            return
        identity = id(value)
        if identity in seen:
            return
        seen.add(identity)
        if isinstance(value, list):
            for item in value:
                visit(item)
            return
        reference = value.get("$ref")
        if isinstance(reference, str):
            if reference.startswith(prefix):
                encoded_name = reference[len(prefix) :]
                result.add(encoded_name.replace("~1", "/").replace("~0", "~"))
            target = _local_reference(document, reference)
            if target is not None:
                visit(target)
        for key, item in value.items():
            if key != "$ref":
                visit(item)

    visit(document.get("paths", {}))
    visit(document.get("webhooks", {}))
    return result


def _compare_security_schemes(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    failures: list[str],
) -> None:
    old_schemes = _component_map(old_document, "securitySchemes")
    new_schemes = _component_map(new_document, "securitySchemes")
    for name, old_raw in old_schemes.items():
        new_raw = new_schemes.get(name)
        if not isinstance(new_raw, dict):
            failures.append(f"removed security scheme {name}")
            continue
        if not isinstance(old_raw, dict):
            continue
        location = f"components.securitySchemes.{name}"
        if _compare_reference(old_raw, new_raw, location, failures):
            continue
        for field in (
            "type",
            "name",
            "in",
            "scheme",
            "bearerFormat",
            "openIdConnectUrl",
        ):
            if old_raw.get(field) != new_raw.get(field) and (
                field in old_raw or field in new_raw
            ):
                failures.append(
                    f"{location}: changed {field} from {old_raw.get(field)!r} "
                    f"to {new_raw.get(field)!r}"
                )
        old_flows = old_raw.get("flows", {})
        new_flows = new_raw.get("flows", {})
        if isinstance(old_flows, dict):
            if not isinstance(new_flows, dict):
                failures.append(f"{location}: removed OAuth flows")
                continue
            for flow_name, old_flow in old_flows.items():
                new_flow = new_flows.get(flow_name)
                if not isinstance(new_flow, dict):
                    failures.append(f"{location}: removed OAuth flow {flow_name!r}")
                    continue
                if not isinstance(old_flow, dict):
                    continue
                for field in ("authorizationUrl", "tokenUrl", "refreshUrl"):
                    if old_flow.get(field) != new_flow.get(field) and (
                        field in old_flow or field in new_flow
                    ):
                        failures.append(f"{location}.{flow_name}: changed {field}")
                old_scopes = old_flow.get("scopes", {})
                new_scopes = new_flow.get("scopes", {})
                if isinstance(old_scopes, dict):
                    if not isinstance(new_scopes, dict):
                        failures.append(f"{location}.{flow_name}: removed OAuth scopes")
                    else:
                        for scope in old_scopes:
                            if scope not in new_scopes:
                                failures.append(
                                    f"{location}.{flow_name}: removed OAuth scope {scope!r}"
                                )


def _compare_component_objects(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    component_name: str,
    failures: list[str],
) -> None:
    old_values = _component_map(old_document, component_name)
    new_values = _component_map(new_document, component_name)
    for name, old_value in old_values.items():
        if name not in new_values:
            failures.append(f"removed component {component_name}.{name}")
            continue
        location = f"components.{component_name}.{name}"
        if component_name in ("parameters", "headers"):
            if isinstance(old_value, dict) and isinstance(new_values[name], dict):
                _compare_parameter(
                    old_value,
                    new_values[name],
                    location,
                    failures,
                    old_document,
                    new_document,
                    mode="response" if component_name == "headers" else "request",
                )
        elif component_name == "requestBodies":
            _compare_request_body(
                old_value,
                new_values[name],
                location,
                failures,
                old_document,
                new_document,
            )
        elif component_name == "responses":
            _compare_response(
                old_value,
                new_values[name],
                location,
                failures,
                old_document,
                new_document,
            )


def _compare_callback(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_raw: Any,
    new_raw: Any,
    location: str,
    failures: list[str],
) -> None:
    if not isinstance(old_raw, dict) or not isinstance(new_raw, dict):
        if old_raw != new_raw:
            failures.append(f"{location}: changed callback shape")
        return
    if _compare_reference(old_raw, new_raw, location, failures):
        return
    old_callback = _resolved_object(old_document, old_raw)
    new_callback = _resolved_object(new_document, new_raw)
    if not isinstance(old_callback, dict) or not isinstance(new_callback, dict):
        failures.append(f"{location}: changed callback shape")
        return
    for expression, old_path_item in old_callback.items():
        if expression == "$ref":
            continue
        if expression not in new_callback:
            failures.append(f"{location}: removed callback expression {expression!r}")
            continue
        _compare_path_item(
            old_document,
            new_document,
            old_path_item,
            new_callback[expression],
            f"{location} expression {expression!r}",
            failures,
            reverse=True,
        )


def _compare_callbacks(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_operation: dict[str, Any],
    new_operation: dict[str, Any],
    location: str,
    failures: list[str],
) -> None:
    old_callbacks = old_operation.get("callbacks", {})
    new_callbacks = new_operation.get("callbacks", {})
    if not isinstance(old_callbacks, dict):
        return
    if not isinstance(new_callbacks, dict):
        failures.append(f"{location}: removed all callbacks")
        return
    for name, old_callback in old_callbacks.items():
        if name not in new_callbacks:
            failures.append(f"{location}: removed callback {name!r}")
            continue
        _compare_callback(
            old_document,
            new_document,
            old_callback,
            new_callbacks[name],
            f"{location} callback {name!r}",
            failures,
        )


def _compare_operation(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_path_item: dict[str, Any],
    new_path_item: dict[str, Any],
    old_operation: dict[str, Any],
    new_operation: dict[str, Any],
    location: str,
    failures: list[str],
    *,
    reverse: bool,
) -> None:
    if "operationId" in old_operation and old_operation.get(
        "operationId"
    ) != new_operation.get("operationId"):
        failures.append(f"{location}: changed operationId")
    request_mode: Literal["request", "response"] = "response" if reverse else "request"
    response_mode: Literal["request", "response"] = "request" if reverse else "response"
    _compare_parameters(
        old_document,
        new_document,
        old_path_item,
        new_path_item,
        old_operation,
        new_operation,
        location,
        failures,
        mode=request_mode,
    )
    _compare_request_body(
        old_operation.get("requestBody"),
        new_operation.get("requestBody"),
        location,
        failures,
        old_document,
        new_document,
        mode=request_mode,
    )
    _compare_security(
        old_document,
        new_document,
        old_operation,
        new_operation,
        location,
        failures,
    )
    old_responses = old_operation.get("responses", {})
    new_responses = new_operation.get("responses", {})
    if isinstance(old_responses, dict):
        if not isinstance(new_responses, dict):
            failures.append(f"{location}: responses are no longer an object")
        else:
            for status, old_response in old_responses.items():
                if status not in new_responses:
                    failures.append(f"{location}: removed response {status}")
                    continue
                _compare_response(
                    old_response,
                    new_responses[status],
                    f"{location} response {status}",
                    failures,
                    old_document,
                    new_document,
                    mode=response_mode,
                )
    _compare_callbacks(
        old_document,
        new_document,
        old_operation,
        new_operation,
        location,
        failures,
    )


def _compare_path_item(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    old_raw: Any,
    new_raw: Any,
    location: str,
    failures: list[str],
    *,
    reverse: bool,
) -> None:
    if not isinstance(old_raw, dict) or not isinstance(new_raw, dict):
        if old_raw != new_raw:
            failures.append(f"removed route {location}")
        return
    if _compare_reference(old_raw, new_raw, location, failures):
        return
    old_path_item = _resolved_object(old_document, old_raw)
    new_path_item = _resolved_object(new_document, new_raw)
    if not isinstance(old_path_item, dict) or not isinstance(new_path_item, dict):
        failures.append(f"{location}: changed Path Item shape")
        return
    for method, old_operation in old_path_item.items():
        if method.lower() not in HTTP_METHODS:
            continue
        new_operation = new_path_item.get(method)
        if not isinstance(new_operation, dict):
            failures.append(f"removed operation {method.upper()} {location}")
            continue
        if not isinstance(old_operation, dict):
            continue
        _compare_operation(
            old_document,
            new_document,
            old_path_item,
            new_path_item,
            old_operation,
            new_operation,
            f"{method.upper()} {location}",
            failures,
            reverse=reverse,
        )


def _compare_path_map(
    old_document: dict[str, Any],
    new_document: dict[str, Any],
    map_name: str,
    failures: list[str],
    *,
    reverse: bool,
) -> None:
    old_paths = old_document.get(map_name, {})
    new_paths = new_document.get(map_name, {})
    if not isinstance(old_paths, dict):
        return
    if not isinstance(new_paths, dict):
        failures.append(f"removed all {map_name}")
        return
    for path, old_path_item in old_paths.items():
        if path not in new_paths:
            label = "webhook" if map_name == "webhooks" else "route"
            failures.append(f"removed {label} {path}")
            continue
        _compare_path_item(
            old_document,
            new_document,
            old_path_item,
            new_paths[path],
            path,
            failures,
            reverse=reverse,
        )


def compare_contracts(old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    failures = _validate_document(old, "old contract")
    failures.extend(_validate_document(new, "new contract"))
    if failures:
        return failures

    _compare_path_map(old, new, "paths", failures, reverse=False)
    _compare_path_map(old, new, "webhooks", failures, reverse=True)

    old_schemas = _component_map(old, "schemas")
    new_schemas = _component_map(new, "schemas")
    reached_schemas = _reachable_schema_components(old)
    for name, old_schema in old_schemas.items():
        if name not in new_schemas:
            failures.append(f"removed component schema {name}")
            continue
        if name in reached_schemas:
            # Its compatibility was already checked from each request/response use,
            # which preserves direction instead of applying ambiguous neutral rules.
            continue
        compare_schema(
            old_schema,
            new_schemas[name],
            f"components.schemas.{name}",
            failures,
            old_document=old,
            new_document=new,
        )

    for component_name in ("parameters", "headers", "requestBodies", "responses"):
        _compare_component_objects(old, new, component_name, failures)

    old_callbacks = _component_map(old, "callbacks")
    new_callbacks = _component_map(new, "callbacks")
    for name, old_callback in old_callbacks.items():
        if name not in new_callbacks:
            failures.append(f"removed component callbacks.{name}")
            continue
        _compare_callback(
            old,
            new,
            old_callback,
            new_callbacks[name],
            f"components.callbacks.{name}",
            failures,
        )

    old_path_items = _component_map(old, "pathItems")
    new_path_items = _component_map(new, "pathItems")
    for name, old_path_item in old_path_items.items():
        if name not in new_path_items:
            failures.append(f"removed component pathItems.{name}")
            continue
        _compare_path_item(
            old,
            new,
            old_path_item,
            new_path_items[name],
            f"components.pathItems.{name}",
            failures,
            reverse=False,
        )
    _compare_security_schemes(old, new, failures)
    return failures


def _print_failures(failures: list[str]) -> int:
    if failures:
        print("OpenAPI backward-compatibility check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("OpenAPI backward-compatibility check passed.")
    return 0


def main() -> int:
    try:
        if len(sys.argv) == 3:
            old = load(sys.argv[1])
            new = load(sys.argv[2])
        elif len(sys.argv) == 6 and sys.argv[1] == "--git-base":
            old = load_git_contract(sys.argv[2], sys.argv[3], sys.argv[4])
            new = load(sys.argv[5])
        else:
            print(
                "usage: check_openapi_compatibility.py OLD.json NEW.json\n"
                "   or: check_openapi_compatibility.py --git-base "
                "REPOSITORY REVISION CONTRACT_PATH NEW.json",
                file=sys.stderr,
            )
            return 2
    except (OSError, ValueError) as error:
        print(f"OpenAPI compatibility input failed: {error}", file=sys.stderr)
        return 2
    return _print_failures(compare_contracts(old, new))


if __name__ == "__main__":
    raise SystemExit(main())
