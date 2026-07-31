#!/usr/bin/env python3
"""Focused tests for the dependency-free OpenAPI compatibility checker."""

from __future__ import annotations

import unittest

from check_openapi_compatibility import compare_contracts


def contract() -> dict:
    return {
        "paths": {
            "/v1/items": {
                "get": {
                    "responses": {
                        "200": {"description": "ok"},
                        "404": {"description": "missing"},
                    }
                }
            }
        },
        "components": {
            "schemas": {
                "Item": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "state": {
                            "type": "string",
                            "enum": ["queued", "ready"],
                        },
                    },
                }
            }
        },
    }


class CompatibilityTests(unittest.TestCase):
    def test_identical_contract_is_compatible(self) -> None:
        self.assertEqual(compare_contracts(contract(), contract()), [])

    def test_removed_route_is_rejected(self) -> None:
        new = contract()
        del new["paths"]["/v1/items"]
        self.assertIn("removed route /v1/items", compare_contracts(contract(), new))

    def test_removed_response_and_field_are_rejected(self) -> None:
        new = contract()
        del new["paths"]["/v1/items"]["get"]["responses"]["404"]
        del new["components"]["schemas"]["Item"]["properties"]["id"]
        failures = compare_contracts(contract(), new)
        self.assertTrue(any("removed response 404" in item for item in failures))
        self.assertTrue(any("removed property 'id'" in item for item in failures))

    def test_narrowed_enum_is_rejected_but_expansion_is_allowed(self) -> None:
        narrowed = contract()
        narrowed["components"]["schemas"]["Item"]["properties"]["state"][
            "enum"
        ] = ["ready"]
        self.assertTrue(
            any(
                "removed enum values" in item
                for item in compare_contracts(contract(), narrowed)
            )
        )

        expanded = contract()
        expanded["components"]["schemas"]["Item"]["properties"]["state"][
            "enum"
        ].append("failed")
        self.assertEqual(compare_contracts(contract(), expanded), [])


if __name__ == "__main__":
    unittest.main()
