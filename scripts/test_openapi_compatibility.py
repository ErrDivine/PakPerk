#!/usr/bin/env python3
"""Focused tests for the dependency-free OpenAPI compatibility checker."""

from __future__ import annotations

import copy
import json
import pathlib
import subprocess
import tempfile
import unittest

from check_openapi_compatibility import compare_contracts, load, load_git_contract


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


def operation_contract() -> dict:
    return {
        "openapi": "3.1.0",
        "paths": {
            "/v1/items": {
                "post": {
                    "operationId": "createItem",
                    "security": [
                        {"oauth": ["items:write"]},
                        {"api_key": []},
                    ],
                    "parameters": [
                        {
                            "name": "mode",
                            "in": "query",
                            "required": False,
                            "schema": {"type": "string"},
                        }
                    ],
                    "requestBody": {
                        "required": False,
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/CreateItem"}
                            },
                            "application/problem+json": {"schema": {"type": "object"}},
                        },
                    },
                    "responses": {
                        "200": {
                            "description": "ok",
                            "content": {
                                "application/json": {
                                    "schema": {
                                        "type": "object",
                                        "required": ["id"],
                                        "properties": {
                                            "id": {"type": "string"},
                                            "state": {"type": "string"},
                                        },
                                    }
                                },
                                "application/problem+json": {
                                    "schema": {"type": "object"}
                                },
                            },
                        }
                    },
                }
            }
        },
        "components": {
            "schemas": {
                "CreateItem": {
                    "type": "object",
                    "required": ["name"],
                    "properties": {
                        "name": {"type": "string"},
                        "note": {"type": "string"},
                    },
                },
                "AlternateCreateItem": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                },
            },
            "securitySchemes": {
                "oauth": {
                    "type": "oauth2",
                    "flows": {
                        "authorizationCode": {
                            "authorizationUrl": "https://issuer.example/authorize",
                            "tokenUrl": "https://issuer.example/token",
                            "scopes": {"items:write": "Create an item"},
                        }
                    },
                },
                "api_key": {
                    "type": "apiKey",
                    "name": "X-API-Key",
                    "in": "header",
                },
            },
        },
    }


def schema_contract(schema: dict, *, mode: str) -> dict:
    operation = {"responses": {"200": {"description": "ok"}}}
    if mode == "request":
        operation["requestBody"] = {
            "required": True,
            "content": {"application/json": {"schema": schema}},
        }
    elif mode == "response":
        operation["responses"]["200"]["content"] = {
            "application/json": {"schema": schema}
        }
    else:
        raise ValueError(f"unsupported schema mode {mode}")
    return {
        "openapi": "3.1.0",
        "paths": {"/v1/schema": {"post": operation}},
    }


def callback_contract() -> dict:
    callback = {
        "{$request.body#/callbackUrl}": {
            "post": {
                "requestBody": {
                    "content": {"application/json": {"schema": {"type": "object"}}}
                },
                "responses": {"200": {"description": "ok"}},
            }
        }
    }
    return {
        "openapi": "3.1.0",
        "paths": {
            "/v1/jobs": {
                "post": {
                    "callbacks": {"finished": copy.deepcopy(callback)},
                    "responses": {"202": {"description": "accepted"}},
                }
            }
        },
        "webhooks": {
            "jobCreated": {
                "post": {
                    "requestBody": {
                        "content": {"application/json": {"schema": {"type": "object"}}}
                    },
                    "responses": {"200": {"description": "ok"}},
                }
            }
        },
        "components": {"callbacks": {"Finished": callback}},
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
        narrowed["components"]["schemas"]["Item"]["properties"]["state"]["enum"] = [
            "ready"
        ]
        self.assertTrue(
            any(
                "removed enum values" in item
                for item in compare_contracts(contract(), narrowed)
            )
        )

        expanded = contract()
        expanded["components"]["schemas"]["Item"]["properties"]["state"]["enum"].append(
            "failed"
        )
        self.assertEqual(compare_contracts(contract(), expanded), [])

    def test_schema_type_and_reference_changes_are_rejected(self) -> None:
        changed_type = operation_contract()
        changed_type["components"]["schemas"]["CreateItem"]["properties"]["name"][
            "type"
        ] = "integer"
        self.assertTrue(
            any(
                "changed schema type" in item
                for item in compare_contracts(operation_contract(), changed_type)
            )
        )

        changed_reference = operation_contract()
        changed_reference["paths"]["/v1/items"]["post"]["requestBody"]["content"][
            "application/json"
        ]["schema"]["$ref"] = "#/components/schemas/AlternateCreateItem"
        self.assertTrue(
            any(
                "changed schema reference" in item
                for item in compare_contracts(operation_contract(), changed_reference)
            )
        )

    def test_required_parameter_changes_are_rejected(self) -> None:
        became_required = operation_contract()
        became_required["paths"]["/v1/items"]["post"]["parameters"][0][
            "required"
        ] = True
        self.assertTrue(
            any(
                "parameter became required" in item
                for item in compare_contracts(operation_contract(), became_required)
            )
        )

        added_required = operation_contract()
        added_required["paths"]["/v1/items"]["post"]["parameters"].append(
            {
                "name": "tenant",
                "in": "header",
                "required": True,
                "schema": {"type": "string"},
            }
        )
        self.assertTrue(
            any(
                "added required parameter" in item
                for item in compare_contracts(operation_contract(), added_required)
            )
        )

    def test_required_request_body_and_property_changes_are_rejected(self) -> None:
        required_body = operation_contract()
        required_body["paths"]["/v1/items"]["post"]["requestBody"]["required"] = True
        self.assertTrue(
            any(
                "request body became required" in item
                for item in compare_contracts(operation_contract(), required_body)
            )
        )

        required_property = operation_contract()
        required_property["components"]["schemas"]["CreateItem"]["required"].append(
            "note"
        )
        self.assertTrue(
            any(
                "added required request properties" in item
                for item in compare_contracts(operation_contract(), required_property)
            )
        )

    def test_inline_request_and_response_schema_changes_are_rejected(self) -> None:
        request_type = operation_contract()
        request_type["paths"]["/v1/items"]["post"]["requestBody"]["content"][
            "application/problem+json"
        ]["schema"]["type"] = "array"
        self.assertTrue(
            any(
                "changed schema type" in item
                for item in compare_contracts(operation_contract(), request_type)
            )
        )

        removed_response_field = operation_contract()
        del removed_response_field["paths"]["/v1/items"]["post"]["responses"]["200"][
            "content"
        ]["application/json"]["schema"]["properties"]["id"]
        self.assertTrue(
            any(
                "removed property 'id'" in item
                for item in compare_contracts(
                    operation_contract(), removed_response_field
                )
            )
        )

    def test_removed_request_or_response_media_type_is_rejected(self) -> None:
        removed_request_media = operation_contract()
        del removed_request_media["paths"]["/v1/items"]["post"]["requestBody"][
            "content"
        ]["application/problem+json"]
        self.assertTrue(
            any(
                "removed request media type" in item
                for item in compare_contracts(
                    operation_contract(), removed_request_media
                )
            )
        )

        removed_response_media = operation_contract()
        del removed_response_media["paths"]["/v1/items"]["post"]["responses"]["200"][
            "content"
        ]["application/problem+json"]
        self.assertTrue(
            any(
                "removed response media type" in item
                for item in compare_contracts(
                    operation_contract(), removed_response_media
                )
            )
        )

    def test_stricter_operation_security_is_rejected(self) -> None:
        removed_alternative = operation_contract()
        removed_alternative["paths"]["/v1/items"]["post"]["security"] = [
            {"oauth": ["items:write"]}
        ]
        self.assertTrue(
            any(
                "security requirements became stricter" in item
                for item in compare_contracts(operation_contract(), removed_alternative)
            )
        )

        changed_scheme = operation_contract()
        changed_scheme["components"]["securitySchemes"]["api_key"]["in"] = "query"
        self.assertTrue(
            any(
                "changed in" in item
                for item in compare_contracts(operation_contract(), changed_scheme)
            )
        )

    def test_additive_contract_changes_remain_compatible(self) -> None:
        additive = operation_contract()
        additive["paths"]["/v1/items"]["post"]["parameters"].append(
            {
                "name": "trace",
                "in": "query",
                "required": False,
                "schema": {"type": "string"},
            }
        )
        additive["paths"]["/v1/items"]["post"]["requestBody"]["content"][
            "application/cbor"
        ] = {"schema": {"type": "object"}}
        additive["paths"]["/v1/items"]["post"]["responses"]["200"]["content"][
            "application/cbor"
        ] = {"schema": {"type": "object"}}
        additive["paths"]["/v1/items"]["post"]["responses"]["200"]["content"][
            "application/json"
        ]["schema"]["required"].append("server_revision")
        additive["paths"]["/v1/items"]["post"]["responses"]["200"]["content"][
            "application/json"
        ]["schema"]["properties"]["server_revision"] = {"type": "integer"}
        additive["paths"]["/v1/items"]["post"]["security"].append({})
        additive["paths"]["/v1/items/{id}"] = {
            "get": {"responses": {"200": {"description": "ok"}}}
        }
        self.assertEqual(compare_contracts(operation_contract(), additive), [])

    def test_duplicate_json_object_keys_are_rejected(self) -> None:
        fixtures = (
            '{"openapi":"3.1.0","paths":{},"paths":{"/hidden":{}}}',
            '{"paths":{"/x":{"get":{"responses":{"200":{},"200":{}}}}}}',
            '{"paths":{},"components":{"schemas":{"A":{"type":"string",'
            '"type":"integer"}}}}',
        )
        for raw in fixtures:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "contract.json"
                path.write_text(raw, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                    load(path)

    def test_directional_schema_constraints_reject_only_domain_widening(self) -> None:
        request_constraints = (
            ("string", "minLength", 1, 2),
            ("string", "maxLength", 10, 9),
            ("array", "minItems", 1, 2),
            ("array", "maxItems", 10, 9),
            ("object", "minProperties", 1, 2),
            ("object", "maxProperties", 10, 9),
            ("number", "minimum", 1, 2),
            ("number", "maximum", 10, 9),
            ("number", "exclusiveMinimum", 1, 2),
            ("number", "exclusiveMaximum", 10, 9),
            ("number", "multipleOf", 1, 2),
        )
        for schema_type, keyword, old_value, unsafe_value in request_constraints:
            old_schema = {"type": schema_type, keyword: old_value}
            unsafe_schema = {"type": schema_type, keyword: unsafe_value}
            with self.subTest(mode="request", keyword=keyword):
                self.assertTrue(
                    compare_contracts(
                        schema_contract(old_schema, mode="request"),
                        schema_contract(unsafe_schema, mode="request"),
                    )
                )
                self.assertEqual(
                    compare_contracts(
                        schema_contract(unsafe_schema, mode="request"),
                        schema_contract(old_schema, mode="request"),
                    ),
                    [],
                )

        response_constraints = (
            ("string", "minLength", 2, 1),
            ("string", "maxLength", 9, 10),
            ("array", "minItems", 2, 1),
            ("array", "maxItems", 9, 10),
            ("object", "minProperties", 2, 1),
            ("object", "maxProperties", 9, 10),
            ("number", "minimum", 2, 1),
            ("number", "maximum", 9, 10),
            ("number", "exclusiveMinimum", 2, 1),
            ("number", "exclusiveMaximum", 9, 10),
            ("number", "multipleOf", 2, 1),
        )
        for schema_type, keyword, old_value, unsafe_value in response_constraints:
            old_schema = {"type": schema_type, keyword: old_value}
            unsafe_schema = {"type": schema_type, keyword: unsafe_value}
            with self.subTest(mode="response", keyword=keyword):
                self.assertTrue(
                    compare_contracts(
                        schema_contract(old_schema, mode="response"),
                        schema_contract(unsafe_schema, mode="response"),
                    )
                )
                self.assertEqual(
                    compare_contracts(
                        schema_contract(unsafe_schema, mode="response"),
                        schema_contract(old_schema, mode="response"),
                    ),
                    [],
                )

    def test_pattern_nullable_and_unique_item_direction_is_enforced(self) -> None:
        cases = (
            (
                "request",
                {"type": "string"},
                {"type": "string", "pattern": "^[a-z]+$"},
            ),
            (
                "response",
                {"type": "string", "pattern": "^[a-z]+$"},
                {"type": "string"},
            ),
            (
                "request",
                {"type": "string", "nullable": True},
                {"type": "string", "nullable": False},
            ),
            (
                "response",
                {"type": "string", "nullable": False},
                {"type": "string", "nullable": True},
            ),
            (
                "request",
                {"type": "array", "uniqueItems": False},
                {"type": "array", "uniqueItems": True},
            ),
            (
                "response",
                {"type": "array", "uniqueItems": True},
                {"type": "array", "uniqueItems": False},
            ),
        )
        for mode, old_schema, unsafe_schema in cases:
            with self.subTest(mode=mode, old=old_schema, new=unsafe_schema):
                self.assertTrue(
                    compare_contracts(
                        schema_contract(old_schema, mode=mode),
                        schema_contract(unsafe_schema, mode=mode),
                    )
                )
                self.assertEqual(
                    compare_contracts(
                        schema_contract(unsafe_schema, mode=mode),
                        schema_contract(old_schema, mode=mode),
                    ),
                    [],
                )

    def test_referenced_components_keep_their_request_response_direction(self) -> None:
        request_old = operation_contract()
        request_old["components"]["schemas"]["CreateItem"]["properties"]["name"][
            "minLength"
        ] = 2
        request_relaxed = copy.deepcopy(request_old)
        request_relaxed["components"]["schemas"]["CreateItem"]["properties"]["name"][
            "minLength"
        ] = 1
        self.assertEqual(compare_contracts(request_old, request_relaxed), [])
        self.assertTrue(compare_contracts(request_relaxed, request_old))

        response_old = schema_contract(
            {"$ref": "#/components/schemas/Result"}, mode="response"
        )
        response_old["components"] = {
            "schemas": {"Result": {"type": ["string", "null"]}}
        }
        response_narrowed = copy.deepcopy(response_old)
        response_narrowed["components"]["schemas"]["Result"]["type"] = "string"
        self.assertEqual(compare_contracts(response_old, response_narrowed), [])
        self.assertTrue(compare_contracts(response_narrowed, response_old))

    def test_additional_properties_schemas_are_directional(self) -> None:
        request_old = {
            "type": "object",
            "additionalProperties": {"type": "string"},
        }
        request_changed = {
            "type": "object",
            "additionalProperties": {"type": "integer"},
        }
        self.assertTrue(
            compare_contracts(
                schema_contract(request_old, mode="request"),
                schema_contract(request_changed, mode="request"),
            )
        )
        request_unconstrained = {"type": "object", "additionalProperties": True}
        self.assertEqual(
            compare_contracts(
                schema_contract(request_old, mode="request"),
                schema_contract(request_unconstrained, mode="request"),
            ),
            [],
        )
        self.assertTrue(
            compare_contracts(
                schema_contract(request_unconstrained, mode="request"),
                schema_contract(request_old, mode="request"),
            )
        )

        response_old = {
            "type": "object",
            "additionalProperties": {"type": "string"},
        }
        response_changed = {
            "type": "object",
            "additionalProperties": {"type": "integer"},
        }
        self.assertTrue(
            compare_contracts(
                schema_contract(response_old, mode="response"),
                schema_contract(response_changed, mode="response"),
            )
        )
        response_widened = {"type": "object", "additionalProperties": True}
        self.assertTrue(
            compare_contracts(
                schema_contract(response_old, mode="response"),
                schema_contract(response_widened, mode="response"),
            )
        )
        self.assertEqual(
            compare_contracts(
                schema_contract(response_widened, mode="response"),
                schema_contract(response_old, mode="response"),
            ),
            [],
        )

    def test_discriminator_and_directional_compositions_are_checked(self) -> None:
        discriminator = {
            "propertyName": "kind",
            "mapping": {"text": "#/components/schemas/Text"},
        }
        old = schema_contract(
            {
                "oneOf": [{"$ref": "#/components/schemas/Text"}],
                "discriminator": discriminator,
            },
            mode="request",
        )
        old["components"] = {"schemas": {"Text": {"type": "string"}}}
        changed = copy.deepcopy(old)
        changed["paths"]["/v1/schema"]["post"]["requestBody"]["content"][
            "application/json"
        ]["schema"]["discriminator"]["propertyName"] = "type"
        self.assertTrue(
            any("discriminator" in item for item in compare_contracts(old, changed))
        )
        remapped = copy.deepcopy(old)
        remapped["paths"]["/v1/schema"]["post"]["requestBody"]["content"][
            "application/json"
        ]["schema"]["discriminator"]["mapping"]["text"] = "#/components/schemas/Other"
        remapped["components"]["schemas"]["Other"] = {"type": "integer"}
        self.assertTrue(
            any("discriminator" in item for item in compare_contracts(old, remapped))
        )

        variants = [{"type": "string"}, {"type": "integer"}]
        added = variants + [{"type": "boolean"}]
        for composition in ("allOf", "anyOf", "oneOf"):
            with self.subTest(composition=composition, case="reorder"):
                self.assertEqual(
                    compare_contracts(
                        schema_contract({composition: variants}, mode="request"),
                        schema_contract(
                            {composition: list(reversed(variants))}, mode="request"
                        ),
                    ),
                    [],
                )
        self.assertTrue(
            compare_contracts(
                schema_contract({"allOf": variants}, mode="request"),
                schema_contract({"allOf": added}, mode="request"),
            )
        )
        self.assertEqual(
            compare_contracts(
                schema_contract({"allOf": variants}, mode="request"),
                schema_contract({"allOf": variants[:1]}, mode="request"),
            ),
            [],
        )
        self.assertEqual(
            compare_contracts(
                schema_contract({"allOf": variants}, mode="response"),
                schema_contract({"allOf": added}, mode="response"),
            ),
            [],
        )
        self.assertTrue(
            compare_contracts(
                schema_contract({"allOf": variants}, mode="response"),
                schema_contract({"allOf": variants[:1]}, mode="response"),
            )
        )
        for composition in ("anyOf", "oneOf"):
            with self.subTest(composition=composition, mode="request"):
                self.assertEqual(
                    compare_contracts(
                        schema_contract({composition: variants}, mode="request"),
                        schema_contract({composition: added}, mode="request"),
                    ),
                    [],
                )
                self.assertTrue(
                    compare_contracts(
                        schema_contract({composition: variants}, mode="request"),
                        schema_contract({composition: variants[:1]}, mode="request"),
                    )
                )
            with self.subTest(composition=composition, mode="response"):
                self.assertTrue(
                    compare_contracts(
                        schema_contract({composition: variants}, mode="response"),
                        schema_contract({composition: added}, mode="response"),
                    )
                )
                self.assertEqual(
                    compare_contracts(
                        schema_contract({composition: variants}, mode="response"),
                        schema_contract({composition: variants[:1]}, mode="response"),
                    ),
                    [],
                )

    def test_parameter_defaults_and_empty_value_semantics(self) -> None:
        old = schema_contract({"type": "object"}, mode="response")
        old_parameter = {
            "name": "q",
            "in": "query",
            "schema": {"type": "array"},
        }
        old["paths"]["/v1/schema"]["post"]["parameters"] = [old_parameter]
        for field, value in (
            ("style", "form"),
            ("explode", True),
            ("allowReserved", False),
        ):
            explicit = copy.deepcopy(old)
            explicit["paths"]["/v1/schema"]["post"]["parameters"][0][field] = value
            with self.subTest(field=field):
                self.assertEqual(compare_contracts(old, explicit), [])

        allowed_empty = copy.deepcopy(old)
        allowed_empty["paths"]["/v1/schema"]["post"]["parameters"][0][
            "allowEmptyValue"
        ] = True
        self.assertTrue(compare_contracts(allowed_empty, old))

        content_parameter = copy.deepcopy(old)
        content_parameter["paths"]["/v1/schema"]["post"]["parameters"] = [
            {
                "name": "filter",
                "in": "query",
                "content": {
                    "application/json": {"schema": {"type": "string", "minLength": 1}}
                },
            }
        ]
        narrowed_content = copy.deepcopy(content_parameter)
        narrowed_content["paths"]["/v1/schema"]["post"]["parameters"][0]["content"][
            "application/json"
        ]["schema"]["minLength"] = 2
        self.assertTrue(compare_contracts(content_parameter, narrowed_content))

    def test_response_shapes_and_headers_fail_closed(self) -> None:
        old = schema_contract({"type": "string"}, mode="response")
        response = old["paths"]["/v1/schema"]["post"]["responses"]["200"]
        response["headers"] = {"X-Value": {"schema": {"type": "string"}}}

        malformed_responses = copy.deepcopy(old)
        malformed_responses["paths"]["/v1/schema"]["post"]["responses"] = []
        self.assertTrue(compare_contracts(old, malformed_responses))

        malformed_response = copy.deepcopy(old)
        malformed_response["paths"]["/v1/schema"]["post"]["responses"][
            "200"
        ] = "invalid"
        self.assertTrue(compare_contracts(old, malformed_response))

        malformed_status = copy.deepcopy(old)
        responses = malformed_status["paths"]["/v1/schema"]["post"]["responses"]
        responses["20x"] = responses.pop("200")
        self.assertTrue(compare_contracts(old, malformed_status))

        widened_header = copy.deepcopy(old)
        widened_header["paths"]["/v1/schema"]["post"]["responses"]["200"]["headers"][
            "X-Value"
        ]["schema"]["type"] = ["string", "null"]
        self.assertTrue(compare_contracts(old, widened_header))

        bounded_header = copy.deepcopy(old)
        bounded_header["paths"]["/v1/schema"]["post"]["responses"]["200"]["headers"][
            "X-Value"
        ]["schema"] = {"type": "integer", "minimum": 5}
        loosened_header = copy.deepcopy(bounded_header)
        loosened_header["paths"]["/v1/schema"]["post"]["responses"]["200"]["headers"][
            "X-Value"
        ]["schema"]["minimum"] = 0
        self.assertTrue(compare_contracts(bounded_header, loosened_header))

        case_only = copy.deepcopy(old)
        headers = case_only["paths"]["/v1/schema"]["post"]["responses"]["200"][
            "headers"
        ]
        headers["x-value"] = headers.pop("X-Value")
        self.assertEqual(compare_contracts(old, case_only), [])

    def test_callbacks_webhooks_path_items_and_refs_fail_closed(self) -> None:
        old = callback_contract()
        callback_removed = callback_contract()
        del callback_removed["paths"]["/v1/jobs"]["post"]["callbacks"]["finished"]
        self.assertTrue(compare_contracts(old, callback_removed))

        webhook_removed = callback_contract()
        del webhook_removed["webhooks"]["jobCreated"]
        self.assertTrue(compare_contracts(old, webhook_removed))

        component_callback_removed = callback_contract()
        del component_callback_removed["components"]["callbacks"]["Finished"]
        self.assertTrue(compare_contracts(old, component_callback_removed))

        widened_callback_request = callback_contract()
        widened_callback_request["paths"]["/v1/jobs"]["post"]["callbacks"]["finished"][
            "{$request.body#/callbackUrl}"
        ]["post"]["requestBody"]["content"]["application/json"]["schema"]["type"] = [
            "object",
            "null",
        ]
        self.assertTrue(compare_contracts(old, widened_callback_request))

        widened_webhook_request = callback_contract()
        widened_webhook_request["webhooks"]["jobCreated"]["post"]["requestBody"][
            "content"
        ]["application/json"]["schema"]["type"] = ["object", "null"]
        self.assertTrue(compare_contracts(old, widened_webhook_request))

        path_item = {
            "openapi": "3.1.0",
            "paths": {"/v1/ref": {"$ref": "#/components/pathItems/Referenced"}},
            "components": {
                "pathItems": {
                    "Referenced": {"get": {"responses": {"200": {"description": "ok"}}}}
                }
            },
        }
        removed_target = copy.deepcopy(path_item)
        del removed_target["components"]["pathItems"]["Referenced"]
        self.assertTrue(compare_contracts(path_item, removed_target))

        removed_referenced_operation = copy.deepcopy(path_item)
        del removed_referenced_operation["components"]["pathItems"]["Referenced"]["get"]
        self.assertTrue(compare_contracts(path_item, removed_referenced_operation))

        unresolved = schema_contract(
            {"$ref": "#/components/schemas/Missing"}, mode="request"
        )
        self.assertTrue(compare_contracts(unresolved, unresolved))
        external = schema_contract({"$ref": "other.json#/Thing"}, mode="request")
        self.assertTrue(compare_contracts(external, external))

    def test_supplied_git_base_must_exist_and_contain_the_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = pathlib.Path(directory)
            subprocess.run(
                ["git", "init", "--quiet", str(repository)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            docs = repository / "docs"
            docs.mkdir()
            (docs / "openapi-v1.json").write_text(
                json.dumps(contract()), encoding="utf-8"
            )
            subprocess.run(
                ["git", "-C", str(repository), "add", "docs/openapi-v1.json"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repository),
                    "-c",
                    "user.name=Pakperk Test",
                    "-c",
                    "user.email=pakperk-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "contract fixture",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            revision = subprocess.run(
                ["git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ).stdout.strip()
            self.assertEqual(
                load_git_contract(repository, revision, "docs/openapi-v1.json"),
                contract(),
            )
            with self.assertRaisesRegex(ValueError, "base is unavailable"):
                load_git_contract(repository, "0" * 40, "docs/openapi-v1.json")
            with self.assertRaisesRegex(ValueError, "base is unavailable"):
                load_git_contract(repository, revision, "docs/missing.json")


if __name__ == "__main__":
    unittest.main()
