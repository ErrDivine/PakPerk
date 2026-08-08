#!/usr/bin/env python3
"""Tamper regressions for the checked-in Keycloak realm policy."""

from __future__ import annotations

import copy
import json
import pathlib
import subprocess
import unittest


PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent
REALM_FILE = PROJECT_DIR / "deploy" / "keycloak" / "pakperk-realm.json"
VALIDATOR = PROJECT_DIR / "scripts" / "validate_keycloak_realm.sh"


class KeycloakRealmPolicyValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.realm = json.loads(REALM_FILE.read_text(encoding="utf-8"))

    def validate(self, realm: dict[str, object]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(VALIDATOR), "/dev/stdin"],
            input=json.dumps(realm),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    @staticmethod
    def client(realm: dict[str, object], client_id: str) -> dict[str, object]:
        clients = realm["clients"]
        assert isinstance(clients, list)
        matches = [client for client in clients if client.get("clientId") == client_id]
        assert len(matches) == 1
        return matches[0]

    def test_checked_in_realm_passes(self) -> None:
        completed = self.validate(self.realm)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_provider_policy_relaxations_are_rejected(self) -> None:
        external_smtp = copy.deepcopy(self.realm["smtpServer"])
        assert isinstance(external_smtp, dict)
        external_smtp["host"] = "smtp.external.example"
        tamper_cases = (
            ("realm disabled", "enabled", False),
            ("TLS disabled", "sslRequired", "none"),
            ("self-registration disabled", "registrationAllowed", False),
            ("email verification disabled", "verifyEmail", False),
            ("password recovery disabled", "resetPasswordAllowed", False),
            ("password policy weakened", "passwordPolicy", "length(8)"),
            ("brute-force protection disabled", "bruteForceProtected", False),
            ("brute-force failure threshold widened", "failureFactor", 100),
            ("brute-force wait removed", "waitIncrementSeconds", 0),
            ("access-token lifetime disabled", "accessTokenLifespan", 0),
            ("access-token lifetime is fractional", "accessTokenLifespan", 0.5),
            ("access-token lifetime drifted", "accessTokenLifespan", 299),
            ("access-token lifetime exceeds five minutes", "accessTokenLifespan", 301),
            ("SSO session widened", "ssoSessionMaxLifespan", 604800),
            ("offline session enabled", "offlineSessionIdleTimeout", 2592000),
            ("refresh-token rotation disabled", "revokeRefreshToken", False),
            ("refresh-token reuse enabled", "refreshTokenMaxReuse", 1),
            ("signature algorithm weakened", "defaultSignatureAlgorithm", "none"),
            ("SMTP escaped Mailpit", "smtpServer", external_smtp),
            ("unknown root policy added", "rogueSecurityOverride", True),
        )

        for description, field, value in tamper_cases:
            with self.subTest(description=description):
                tampered = copy.deepcopy(self.realm)
                tampered[field] = value
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted realm with {description}",
                )

    def test_client_protocol_security_and_key_surface_are_exact(self) -> None:
        tamper_cases = (
            ("pakperk-mobile-dev", "bearerOnly", True),
            ("pakperk-mobile-dev", "protocol", "saml"),
            ("pakperk-mobile-dev", "consentRequired", True),
            ("pakperk-mobile-dev", "frontchannelLogout", True),
            ("pakperk-mobile-dev", "clientAuthenticatorType", "client-jwt"),
            ("pakperk-deletion-worker-dev", "authorizationServicesEnabled", True),
            ("pakperk-deletion-worker-dev", "rogueCapability", True),
        )
        for client_id, field, value in tamper_cases:
            with self.subTest(client_id=client_id, field=field):
                tampered = copy.deepcopy(self.realm)
                self.client(tampered, client_id)[field] = value
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted {field} drift on {client_id}",
                )

        tampered = copy.deepcopy(self.realm)
        mobile = self.client(tampered, "pakperk-mobile-dev")
        mappers = mobile["protocolMappers"]
        assert isinstance(mappers, list) and len(mappers) == 1
        mappers[0]["rogueMapperCapability"] = True
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted an unknown audience-mapper capability",
        )

    def test_required_clients_cannot_be_disabled(self) -> None:
        client_ids = (
            "pakperk-mobile-dev",
            "pakperk-admin-dev",
            "pakperk-web-deletion-dev",
            "pakperk-deletion-worker-dev",
        )
        for client_id in client_ids:
            with self.subTest(client_id=client_id):
                tampered = copy.deepcopy(self.realm)
                self.client(tampered, client_id)["enabled"] = False
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted disabled client {client_id}",
                )

    def test_additional_enabled_wildcard_grant_client_is_rejected(self) -> None:
        tampered = copy.deepcopy(self.realm)
        clients = tampered["clients"]
        assert isinstance(clients, list)
        rogue = copy.deepcopy(self.client(tampered, "pakperk-mobile-dev"))
        rogue.update(
            {
                "clientId": "rogue-wildcard-grant-client",
                "enabled": True,
                "redirectUris": ["*"],
                "webOrigins": ["*"],
                "implicitFlowEnabled": True,
                "directAccessGrantsEnabled": True,
            }
        )
        clients.append(rogue)
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted an additional enabled wildcard/grant client",
        )

    def test_deletion_worker_service_account_cannot_be_disabled(self) -> None:
        tampered = copy.deepcopy(self.realm)
        users = tampered["users"]
        assert isinstance(users, list)
        service_accounts = [
            user
            for user in users
            if user.get("serviceAccountClientId") == "pakperk-deletion-worker-dev"
        ]
        self.assertEqual(len(service_accounts), 1)
        service_accounts[0]["enabled"] = False
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted a disabled deletion-worker service account",
        )

    def test_deletion_worker_service_account_cannot_gain_roles(self) -> None:
        tamper_cases = (
            ("realm admin role", "realmRoles", ["admin"]),
            (
                "client realm-admin role",
                "clientRoles",
                {"realm-management": ["manage-users", "realm-admin"]},
            ),
        )

        for description, field, value in tamper_cases:
            with self.subTest(description=description):
                tampered = copy.deepcopy(self.realm)
                users = tampered["users"]
                assert isinstance(users, list)
                service_accounts = [
                    user
                    for user in users
                    if user.get("serviceAccountClientId")
                    == "pakperk-deletion-worker-dev"
                ]
                self.assertEqual(len(service_accounts), 1)
                service_accounts[0][field] = value
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted deletion-worker {description}",
                )

    def test_additional_enabled_credentialed_admin_user_is_rejected(self) -> None:
        tampered = copy.deepcopy(self.realm)
        users = tampered["users"]
        assert isinstance(users, list)
        users.append(
            {
                "username": "rogue-realm-administrator",
                "enabled": True,
                "credentials": [
                    {
                        "type": "password",
                        "value": "rogue-password",
                        "temporary": False,
                    }
                ],
                "realmRoles": ["admin"],
                "clientRoles": {"realm-management": ["realm-admin"]},
            }
        )
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted an additional credentialed realm administrator",
        )

    def test_additive_realm_import_surfaces_are_rejected(self) -> None:
        tamper_cases = {
            "roles": {"realm": [{"name": "rogue-admin"}]},
            "groups": [{"name": "rogue-admins", "realmRoles": ["admin"]}],
            "identityProviders": [
                {
                    "alias": "rogue-idp",
                    "providerId": "oidc",
                    "enabled": True,
                }
            ],
            "authenticationFlows": [
                {
                    "alias": "rogue-password-flow",
                    "providerId": "basic-flow",
                    "topLevel": True,
                    "builtIn": False,
                }
            ],
        }
        for field, value in tamper_cases.items():
            with self.subTest(field=field):
                tampered = copy.deepcopy(self.realm)
                tampered[field] = value
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted populated top-level {field}",
                )

    def test_mobile_refresh_token_issuance_cannot_be_disabled(self) -> None:
        tampered = copy.deepcopy(self.realm)
        mobile = self.client(tampered, "pakperk-mobile-dev")
        attributes = mobile["attributes"]
        assert isinstance(attributes, dict)
        attributes["use.refresh.tokens"] = "false"
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted a mobile client without refresh tokens",
        )

    def test_required_audience_mappers_cannot_be_removed(self) -> None:
        client_ids = (
            "pakperk-mobile-dev",
            "pakperk-admin-dev",
            "pakperk-web-deletion-dev",
        )
        for client_id in client_ids:
            with self.subTest(client_id=client_id):
                tampered = copy.deepcopy(self.realm)
                self.client(tampered, client_id)["protocolMappers"] = []
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted {client_id} without its audience mapper",
                )

    def test_public_client_web_origins_cannot_be_wildcarded(self) -> None:
        client_ids = (
            "pakperk-mobile-dev",
            "pakperk-admin-dev",
            "pakperk-web-deletion-dev",
        )
        for client_id in client_ids:
            with self.subTest(client_id=client_id):
                tampered = copy.deepcopy(self.realm)
                self.client(tampered, client_id)["webOrigins"] = ["*"]
                completed = self.validate(tampered)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    f"validator accepted wildcard web origin for {client_id}",
                )

    def test_keycloak_collection_shapes_must_remain_arrays(self) -> None:
        tampered = copy.deepcopy(self.realm)
        clients = tampered["clients"]
        assert isinstance(clients, list)
        tampered["clients"] = {
            str(index): client for index, client in enumerate(clients)
        }
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted an object where Keycloak requires a client array",
        )

        tampered = copy.deepcopy(self.realm)
        mobile = self.client(tampered, "pakperk-mobile-dev")
        mappers = mobile["protocolMappers"]
        assert isinstance(mappers, list) and len(mappers) == 1
        mobile["protocolMappers"] = {"mapper": mappers[0]}
        completed = self.validate(tampered)
        self.assertNotEqual(
            completed.returncode,
            0,
            "validator accepted an object where Keycloak requires a mapper array",
        )


if __name__ == "__main__":
    unittest.main()
