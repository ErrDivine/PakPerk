#!/usr/bin/env python3
"""Disposable Keycloak/PostgreSQL account-deletion acceptance driver.

The shell wrapper owns Compose and the Rust processes. This driver owns one
disposable identity and verifies the destructive HTTP/worker contract without
printing credentials, bearer tokens, provider subjects, or response bodies.
"""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import time
from typing import Any, Iterable
from urllib.parse import parse_qs, urljoin, urlparse
import unittest
import uuid


requests: Any = None
BeautifulSoup: Any = None
HTTP: Any = None


class AcceptanceError(RuntimeError):
    """A bounded failure that is safe to print."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise AcceptanceError(f"{name} is required")
    return value


def loopback_http_origin(value: str, name: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise AcceptanceError(f"{name} must be an HTTP loopback origin")
    try:
        port = parsed.port
    except ValueError as error:
        raise AcceptanceError(f"{name} has an invalid port") from error
    if port is None:
        raise AcceptanceError(f"{name} must include an explicit port")
    return value.rstrip("/")


def same_http_origin_url(value: str, expected_origin: str, name: str) -> str:
    """Accept an absolute URL only on the already validated HTTP origin."""
    parsed = urlparse(value)
    expected = urlparse(expected_origin)
    try:
        port = parsed.port
        expected_port = expected.port
    except ValueError as error:
        raise AcceptanceError(f"{name} has an invalid port") from error
    if (
        parsed.scheme != expected.scheme
        or parsed.hostname != expected.hostname
        or port != expected_port
        or parsed.username
        or parsed.password
        or parsed.fragment
    ):
        raise AcceptanceError(f"{name} left the exact disposable provider origin")
    return value


def exact_native_redirect_query(value: str, expected_redirect: str) -> dict[str, list[str]]:
    """Return a callback query only when every non-query URI component matches."""
    parsed = urlparse(value)
    expected = urlparse(expected_redirect)
    if (
        parsed.scheme != expected.scheme
        or parsed.netloc != expected.netloc
        or parsed.path != expected.path
        or parsed.params != expected.params
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise AcceptanceError("Keycloak login did not return to the exact native redirect URI")
    return parse_qs(parsed.query)


def loopback_postgres_url(value: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme not in {"postgres", "postgresql"}
        or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
        or not parsed.path.strip("/")
        or parsed.query
        or parsed.fragment
    ):
        raise AcceptanceError(
            "LIVE_ACCOUNT_DELETION_DATABASE_URL must target loopback PostgreSQL"
        )
    return value


def checked_uuid(value: Any, field: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except ValueError as error:
        raise AcceptanceError(f"{field} is not a UUID") from error


@dataclass(frozen=True)
class Config:
    project_dir: Path
    state_file: Path
    api_base: str
    keycloak_base: str
    realm: str
    oidc_client_id: str
    oidc_redirect_uri: str
    admin_username: str
    admin_password: str
    database_url: str
    postgres_user: str
    postgres_db: str
    run_id: str
    token_sentinel: str
    worker_client_id: str
    worker_secret_file: Path
    worker_binary: Path
    ledger_directory: Path
    recent_auth_seconds: int
    log_files: tuple[Path, ...]

    @classmethod
    def load(cls) -> "Config":
        project_dir = Path(required_env("LIVE_ACCOUNT_DELETION_PROJECT_DIR")).resolve()
        run_id = required_env("LIVE_ACCOUNT_DELETION_RUN_ID")
        if len(run_id) != 32 or any(
            character not in "0123456789abcdef" for character in run_id
        ):
            raise AcceptanceError(
                "LIVE_ACCOUNT_DELETION_RUN_ID must be 32 lowercase hex characters"
            )
        recent_auth_seconds = int(
            required_env("LIVE_ACCOUNT_DELETION_RECENT_AUTH_SECONDS")
        )
        if not 30 <= recent_auth_seconds <= 300:
            raise AcceptanceError(
                "LIVE_ACCOUNT_DELETION_RECENT_AUTH_SECONDS must be between 30 and 300"
            )
        logs = tuple(
            Path(value)
            for value in required_env("LIVE_ACCOUNT_DELETION_LOGS").split(os.pathsep)
            if value
        )
        if len(logs) != 2:
            raise AcceptanceError(
                "LIVE_ACCOUNT_DELETION_LOGS must name API and worker logs"
            )
        realm = required_env("LIVE_ACCOUNT_DELETION_KEYCLOAK_REALM")
        oidc_client_id = required_env("LIVE_ACCOUNT_DELETION_OIDC_CLIENT_ID")
        oidc_redirect_uri = required_env("LIVE_ACCOUNT_DELETION_OIDC_REDIRECT_URI")
        worker_client_id = required_env("LIVE_ACCOUNT_DELETION_WORKER_CLIENT_ID")
        if (
            realm != "pakperk"
            or oidc_client_id != "pakperk-mobile-dev"
            or oidc_redirect_uri != "pakperk-auth-dev://oauth/callback"
            or worker_client_id != "pakperk-deletion-worker-dev"
        ):
            raise AcceptanceError(
                "live acceptance must use the exact checked-in development realm clients"
            )
        return cls(
            project_dir=project_dir,
            state_file=Path(required_env("LIVE_ACCOUNT_DELETION_STATE_FILE")),
            api_base=loopback_http_origin(
                required_env("LIVE_ACCOUNT_DELETION_API_BASE"),
                "LIVE_ACCOUNT_DELETION_API_BASE",
            ),
            keycloak_base=loopback_http_origin(
                required_env("LIVE_ACCOUNT_DELETION_KEYCLOAK_BASE_URL"),
                "LIVE_ACCOUNT_DELETION_KEYCLOAK_BASE_URL",
            ),
            realm=realm,
            oidc_client_id=oidc_client_id,
            oidc_redirect_uri=oidc_redirect_uri,
            admin_username=required_env(
                "LIVE_ACCOUNT_DELETION_KEYCLOAK_ADMIN_USERNAME"
            ),
            admin_password=required_env(
                "LIVE_ACCOUNT_DELETION_KEYCLOAK_ADMIN_PASSWORD"
            ),
            database_url=loopback_postgres_url(
                required_env("LIVE_ACCOUNT_DELETION_DATABASE_URL")
            ),
            postgres_user=required_env("LIVE_ACCOUNT_DELETION_POSTGRES_USER"),
            postgres_db=required_env("LIVE_ACCOUNT_DELETION_POSTGRES_DB"),
            run_id=run_id,
            token_sentinel=required_env("LIVE_ACCOUNT_DELETION_TOKEN_SENTINEL"),
            worker_client_id=worker_client_id,
            worker_secret_file=Path(
                required_env("LIVE_ACCOUNT_DELETION_WORKER_SECRET_FILE")
            ),
            worker_binary=Path(required_env("LIVE_ACCOUNT_DELETION_WORKER_BINARY")),
            ledger_directory=Path(required_env("ACCOUNT_DELETION_LEDGER_DIRECTORY")),
            recent_auth_seconds=recent_auth_seconds,
            log_files=logs,
        )

    @property
    def issuer(self) -> str:
        return f"{self.keycloak_base}/realms/{self.realm}"

    @property
    def admin_realm_url(self) -> str:
        return f"{self.keycloak_base}/admin/realms/{self.realm}"

    @property
    def token_url(self) -> str:
        return f"{self.issuer}/protocol/openid-connect/token"

    @property
    def authorize_url(self) -> str:
        return f"{self.issuer}/protocol/openid-connect/auth"


def load_http_dependencies() -> None:
    global requests, BeautifulSoup, HTTP
    try:
        import requests as requests_module  # type: ignore[import-untyped]
        from bs4 import BeautifulSoup as beautiful_soup  # type: ignore[import-untyped]
    except ImportError as error:
        raise AcceptanceError(
            "live acceptance requires the requests and beautifulsoup4 packages"
        ) from error
    requests = requests_module
    BeautifulSoup = beautiful_soup
    HTTP = requests.Session()
    HTTP.trust_env = False


def safe_response_error(response: Any) -> str:
    try:
        payload = response.json()
    except ValueError:
        return "non-JSON response"
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict) and isinstance(error.get("code"), str):
            return error["code"]
        if isinstance(error, str):
            return error
    return "unexpected response envelope"


def expect_status(response: Any, expected: int | Iterable[int], operation: str) -> Any:
    expected_values = {expected} if isinstance(expected, int) else set(expected)
    if response.status_code not in expected_values:
        wanted = "/".join(str(value) for value in sorted(expected_values))
        raise AcceptanceError(
            f"{operation} returned HTTP {response.status_code}, expected {wanted} "
            f"({safe_response_error(response)})"
        )
    return response


def object_json(response: Any, operation: str) -> dict[str, Any]:
    try:
        payload = response.json()
    except ValueError as error:
        raise AcceptanceError(f"{operation} did not return JSON") from error
    if not isinstance(payload, dict):
        raise AcceptanceError(f"{operation} returned a non-object JSON envelope")
    return payload


def api_error_code(response: Any) -> str | None:
    try:
        payload = response.json()
    except ValueError:
        return None
    error = payload.get("error") if isinstance(payload, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def api_request(
    config: Config,
    method: str,
    path: str,
    token: str,
) -> Any:
    try:
        return HTTP.request(
            method,
            f"{config.api_base}{path}",
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {token}",
                "X-Pakperk-Live-Token-Sentinel": config.token_sentinel,
            },
            allow_redirects=False,
            timeout=15,
        )
    except requests.RequestException as error:
        raise AcceptanceError(f"{method} {path} could not reach the API") from error


def admin_access_token(config: Config) -> str:
    try:
        response = HTTP.post(
            f"{config.keycloak_base}/realms/master/protocol/openid-connect/token",
            data={
                "client_id": "admin-cli",
                "grant_type": "password",
                "username": config.admin_username,
                "password": config.admin_password,
            },
            allow_redirects=False,
            timeout=15,
        )
    except requests.RequestException as error:
        raise AcceptanceError(
            "Keycloak administration endpoint is unavailable"
        ) from error
    expect_status(response, 200, "Keycloak administrator bootstrap")
    token = object_json(response, "Keycloak administrator bootstrap").get(
        "access_token"
    )
    if not isinstance(token, str) or not token:
        raise AcceptanceError(
            "Keycloak administrator bootstrap returned no access token"
        )
    return token


def write_worker_secret(config: Config, admin_token: str) -> None:
    headers = {"Authorization": f"Bearer {admin_token}"}
    response = HTTP.get(
        f"{config.admin_realm_url}/clients",
        headers=headers,
        params={"clientId": config.worker_client_id, "first": 0, "max": 2},
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, 200, "find deletion-worker client")
    try:
        clients = response.json()
    except ValueError as error:
        raise AcceptanceError(
            "deletion-worker client lookup did not return JSON"
        ) from error
    exact = (
        [
            item
            for item in clients
            if isinstance(item, dict)
            and item.get("clientId") == config.worker_client_id
            and isinstance(item.get("id"), str)
        ]
        if isinstance(clients, list)
        else []
    )
    if len(exact) != 1:
        raise AcceptanceError(
            "Keycloak did not return one exact deletion-worker client"
        )
    client_uuid = checked_uuid(exact[0]["id"], "Keycloak client ID")
    response = HTTP.get(
        f"{config.admin_realm_url}/clients/{client_uuid}/client-secret",
        headers=headers,
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, 200, "read runtime deletion-worker client secret")
    secret = object_json(response, "read runtime deletion-worker client secret").get(
        "value"
    )
    if not isinstance(secret, str) or not 16 <= len(secret) <= 4096:
        raise AcceptanceError(
            "Keycloak returned an invalid deletion-worker client secret"
        )
    if config.worker_secret_file.exists() or config.worker_secret_file.is_symlink():
        raise AcceptanceError("worker client-secret destination already exists")
    descriptor = os.open(
        config.worker_secret_file,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(descriptor, "wb") as output:
        output.write(secret.encode("utf-8"))
        output.flush()
        os.fsync(output.fileno())


def save_state(config: Config, state: dict[str, Any]) -> None:
    temporary = config.state_file.with_name(
        f".{config.state_file.name}.{uuid.uuid4().hex}.tmp"
    )
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, config.state_file)


def load_state(config: Config) -> dict[str, Any] | None:
    if not config.state_file.exists():
        return None
    metadata = config.state_file.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        raise AcceptanceError("live account-deletion state file is unsafe")
    try:
        state = json.loads(config.state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError("could not read live account-deletion state") from error
    if (
        not isinstance(state, dict)
        or state.get("schema_version") != 1
        or state.get("run_id") != config.run_id
    ):
        raise AcceptanceError("live account-deletion state is malformed")
    return state


def create_keycloak_user(
    config: Config, username: str, password: str, state: dict[str, Any]
) -> str:
    admin_token = admin_access_token(config)
    response = HTTP.post(
        f"{config.admin_realm_url}/users",
        headers={"Authorization": f"Bearer {admin_token}"},
        json={
            "username": username,
            "email": f"{username}@pakperk.test",
            "firstName": "Pakperk",
            "lastName": "Deletion Acceptance",
            "emailVerified": True,
            "enabled": True,
            "requiredActions": [],
            "credentials": [
                {"type": "password", "value": password, "temporary": False}
            ],
        },
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, 201, "create disposable Keycloak user")
    user_id = checked_uuid(
        response.headers.get("Location", "").rstrip("/").rsplit("/", 1)[-1],
        "Keycloak user ID",
    )
    state["keycloak_user_id"] = user_id
    save_state(config, state)
    return user_id


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def jwt_payload(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise AcceptanceError("OIDC access token is not a compact JWT")
    try:
        payload = json.loads(
            base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
        )
    except (ValueError, json.JSONDecodeError) as error:
        raise AcceptanceError("OIDC access token payload is malformed") from error
    if not isinstance(payload, dict):
        raise AcceptanceError("OIDC access token payload is not an object")
    return payload


def authorization_code_pkce(
    config: Config, username: str, password: str, expected_subject: str
) -> dict[str, str]:
    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state_value = secrets.token_urlsafe(24)
    session = requests.Session()
    session.trust_env = False
    response = session.get(
        config.authorize_url,
        params={
            "client_id": config.oidc_client_id,
            "redirect_uri": config.oidc_redirect_uri,
            "response_type": "code",
            "scope": "openid profile",
            "state": state_value,
            "nonce": secrets.token_urlsafe(24),
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "prompt": "login",
            "max_age": "0",
        },
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, 200, "Authorization Code + PKCE authorization")
    form = BeautifulSoup(response.text, "html.parser").select_one("form#kc-form-login")
    if form is None or not form.get("action"):
        raise AcceptanceError("Keycloak did not present its login form")
    for cookie in session.cookies:
        cookie.secure = False
    form_data: dict[str, str] = {}
    for element in form.select("input[name]"):
        if element.has_attr("disabled"):
            continue
        input_type = str(element.get("type", "text")).lower()
        if input_type in {"checkbox", "radio"} and not element.has_attr("checked"):
            continue
        form_data[str(element["name"])] = str(element.get("value", ""))
    form_data.update({"username": username, "password": password})
    form_action = same_http_origin_url(
        urljoin(response.url, str(form["action"])),
        config.keycloak_base,
        "Keycloak login form action",
    )
    login = session.post(
        form_action,
        data=form_data,
        headers={"Referer": response.url},
        allow_redirects=False,
        timeout=15,
    )
    expect_status(login, (302, 303), "Keycloak login form submission")
    location = login.headers.get("Location", "")
    query = exact_native_redirect_query(location, config.oidc_redirect_uri)
    if query.get("state") != [state_value] or len(query.get("code", [])) != 1:
        raise AcceptanceError("Authorization redirect state/code validation failed")
    exchanged = session.post(
        config.token_url,
        data={
            "grant_type": "authorization_code",
            "client_id": config.oidc_client_id,
            "redirect_uri": config.oidc_redirect_uri,
            "code": query["code"][0],
            "code_verifier": verifier,
        },
        allow_redirects=False,
        timeout=15,
    )
    expect_status(exchanged, 200, "Authorization Code + PKCE token exchange")
    payload = object_json(exchanged, "Authorization Code + PKCE token exchange")
    access_token = payload.get("access_token")
    refresh_token = payload.get("refresh_token")
    if not isinstance(access_token, str) or not isinstance(refresh_token, str):
        raise AcceptanceError("Authorization Code + PKCE omitted its token pair")
    claims = jwt_payload(access_token)
    audience = claims.get("aud")
    audiences = {audience} if isinstance(audience, str) else set(audience or [])
    if (
        claims.get("iss") != config.issuer
        or claims.get("sub") != expected_subject
        or "pakperk-api" not in audiences
        or not isinstance(claims.get("auth_time"), int)
    ):
        raise AcceptanceError("Authorization Code + PKCE claims are not API-bound")
    return {"access_token": access_token, "refresh_token": refresh_token}


def wait_until_stale(token: str, recent_auth_seconds: int) -> None:
    auth_time = jwt_payload(token).get("auth_time")
    if not isinstance(auth_time, int):
        raise AcceptanceError("OIDC access token omitted auth_time")
    delay = auth_time + recent_auth_seconds + 1 - time.time()
    if delay > recent_auth_seconds + 2:
        raise AcceptanceError("OIDC auth_time is unexpectedly in the future")
    if delay > 0:
        time.sleep(delay)


def psql(config: Config, sql: str) -> str:
    process_environment = {
        name: os.environ[name]
        for name in (
            "PATH",
            "HOME",
            "TMPDIR",
            "DOCKER_HOST",
            "DOCKER_CONTEXT",
            "DOCKER_CONFIG",
            "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH",
        )
        if name in os.environ
    }
    result = subprocess.run(
        [
            "docker",
            "compose",
            "--project-directory",
            str(config.project_dir),
            "exec",
            "-T",
            "postgres",
            "psql",
            "-X",
            "--quiet",
            "--tuples-only",
            "--no-align",
            "--set",
            "ON_ERROR_STOP=1",
            "--username",
            config.postgres_user,
            "--dbname",
            config.postgres_db,
        ],
        input=sql,
        capture_output=True,
        text=True,
        env=process_environment,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise AcceptanceError("disposable PostgreSQL verification failed")
    return result.stdout.strip()


def sql_json(config: Config, sql: str, operation: str) -> dict[str, Any]:
    try:
        payload = json.loads(psql(config, sql))
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"{operation} returned malformed JSON") from error
    if not isinstance(payload, dict):
        raise AcceptanceError(f"{operation} returned a non-object")
    return payload


def deletion_envelope(response: Any, operation: str) -> tuple[str, str]:
    deletion = object_json(response, operation).get("deletion")
    if not isinstance(deletion, dict):
        raise AcceptanceError(f"{operation} omitted the deletion projection")
    operation_id = checked_uuid(deletion.get("operation_id"), "deletion operation ID")
    state_value = deletion.get("state")
    if not isinstance(state_value, str):
        raise AcceptanceError(f"{operation} omitted the deletion state")
    return operation_id, state_value


def assert_external_ledger(config: Config, operation_id: str) -> None:
    path = (
        config.ledger_directory / f"{checked_uuid(operation_id, 'operation ID')}.json"
    )
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AcceptanceError("external deletion ledger record is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_mode & 0o077
        or metadata.st_nlink != 1
        or not 1 <= metadata.st_size <= 64 * 1024
    ):
        raise AcceptanceError("external deletion ledger record is unsafe")


def immediate_snapshot(
    config: Config, user_id: str, operation_id: str
) -> dict[str, Any]:
    user_id = checked_uuid(user_id, "local user ID")
    operation_id = checked_uuid(operation_id, "operation ID")
    return sql_json(
        config,
        f"""
        SELECT json_build_object(
            'user_count', (SELECT count(*) FROM users WHERE id = '{user_id}'::uuid),
            'user_status', COALESCE((SELECT status FROM users WHERE id = '{user_id}'::uuid), ''),
            'ledger_count', (SELECT count(*) FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid),
            'externalized', COALESCE((SELECT externalized_at IS NOT NULL FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid), false),
            'completed', COALESCE((SELECT completed_at IS NOT NULL FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid), false),
            'job_count', (SELECT count(*) FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid),
            'job_state', COALESCE((SELECT state FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid), ''),
            'request_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'requested')
        )::text;
        """,
        "immediate deletion snapshot",
    )


def prepare(config: Config) -> None:
    if load_state(config) is not None:
        raise AcceptanceError("live account-deletion state already exists")
    state: dict[str, Any] = {
        "schema_version": 1,
        "run_id": config.run_id,
        "keycloak_user_id": None,
        "local_user_id": None,
        "operation_id": None,
        "access_token": None,
        "refresh_token": None,
        "cleaned": False,
    }
    save_state(config, state)
    admin_token = admin_access_token(config)
    write_worker_secret(config, admin_token)
    username = f"lad_{config.run_id[:16]}"
    password = secrets.token_urlsafe(36) + "Aa1!"
    subject = create_keycloak_user(config, username, password, state)
    stale_pair = authorization_code_pkce(config, username, password, subject)

    me = expect_status(
        api_request(config, "GET", "/v1/me", stale_pair["access_token"]),
        200,
        "initial GET /v1/me",
    )
    account = object_json(me, "initial GET /v1/me").get("account")
    if not isinstance(account, dict) or account.get("status") != "active":
        raise AcceptanceError("initial GET /v1/me did not create an active account")
    user_id = checked_uuid(account.get("id"), "local user ID")
    state["local_user_id"] = user_id
    save_state(config, state)

    verification = expect_status(
        api_request(
            config,
            "GET",
            "/v1/me/deletion-verification",
            stale_pair["access_token"],
        ),
        200,
        "pre-delete identity verification",
    )
    verification_account = object_json(
        verification, "pre-delete identity verification"
    ).get("account")
    if (
        not isinstance(verification_account, dict)
        or verification_account.get("id") != user_id
        or verification_account.get("status") != "active"
        or verification_account.get("deletion_operation_id") is not None
    ):
        raise AcceptanceError(
            "pre-delete identity verification was not active and unbound"
        )

    wait_until_stale(stale_pair["access_token"], config.recent_auth_seconds)
    stale_delete = api_request(config, "DELETE", "/v1/me", stale_pair["access_token"])
    expect_status(stale_delete, 401, "stale-auth DELETE /v1/me")
    if api_error_code(stale_delete) != "REAUTHENTICATION_REQUIRED":
        raise AcceptanceError("stale-auth deletion did not require reauthentication")

    fresh_pair = authorization_code_pkce(config, username, password, subject)
    accepted = expect_status(
        api_request(config, "DELETE", "/v1/me", fresh_pair["access_token"]),
        202,
        "fresh-auth DELETE /v1/me",
    )
    operation_id, state_value = deletion_envelope(accepted, "fresh-auth DELETE /v1/me")
    if state_value != "requested":
        raise AcceptanceError("new deletion did not enter requested state")
    state.update(
        {
            "operation_id": operation_id,
            "access_token": fresh_pair["access_token"],
            "refresh_token": fresh_pair["refresh_token"],
        }
    )
    save_state(config, state)

    blocked = api_request(config, "GET", "/v1/me", fresh_pair["access_token"])
    expect_status(blocked, 403, "account access immediately after deletion request")
    if api_error_code(blocked) != "ACCOUNT_DELETION_PENDING":
        raise AcceptanceError(
            "accepted deletion did not immediately disable account access"
        )

    pending_verification = expect_status(
        api_request(
            config,
            "GET",
            "/v1/me/deletion-verification",
            fresh_pair["access_token"],
        ),
        200,
        "pending identity verification",
    )
    pending_account = object_json(
        pending_verification, "pending identity verification"
    ).get("account")
    if (
        not isinstance(pending_account, dict)
        or pending_account.get("status") != "deletion_pending"
        or pending_account.get("deletion_operation_id") != operation_id
    ):
        raise AcceptanceError(
            "deletion verification did not expose the pending operation"
        )

    replay = expect_status(
        api_request(config, "DELETE", "/v1/me", fresh_pair["access_token"]),
        202,
        "pre-worker deletion replay",
    )
    replay_operation, replay_state = deletion_envelope(
        replay, "pre-worker deletion replay"
    )
    if replay_operation != operation_id or replay_state != "requested":
        raise AcceptanceError("pre-worker deletion replay changed the operation")

    snapshot = immediate_snapshot(config, user_id, operation_id)
    if snapshot != {
        "user_count": 1,
        "user_status": "deletion_pending",
        "ledger_count": 1,
        "externalized": True,
        "completed": False,
        "job_count": 1,
        "job_state": "requested",
        "request_events": 1,
    }:
        raise AcceptanceError(
            "accepted deletion did not atomically persist its local contract"
        )
    assert_external_ledger(config, operation_id)
    print("PASS stale auth rejected and fresh Authorization Code + PKCE accepted")
    print(
        "PASS deletion immediately disabled access and externalized one durable operation"
    )
    print("PASS identity-scoped replay returned the same pending operation")


def wait_for_completed(
    config: Config, operation_id: str, timeout_seconds: int = 60
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        state_value = psql(
            config,
            "SELECT state FROM account_deletion_jobs WHERE operation_id = "
            f"'{checked_uuid(operation_id, 'operation ID')}'::uuid;",
        )
        if state_value == "completed":
            return
        if state_value == "failed_terminal":
            raise AcceptanceError("account-deletion worker reached terminal failure")
        time.sleep(0.25)
    raise AcceptanceError("account-deletion worker did not complete within 60 seconds")


def maintenance_command(config: Config, *arguments: str) -> dict[str, Any]:
    environment = {
        name: os.environ[name]
        for name in (
            "PATH",
            "HOME",
            "TMPDIR",
            "APP_ENV",
            "DATABASE_URL",
            "DATABASE_POOL_SIZE",
            "ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE",
            "ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE",
            "ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE",
            "ACCOUNT_DELETION_LEDGER_DIRECTORY",
            "ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID",
            "ACCOUNT_DELETION_RECENT_AUTH_SECONDS",
            "ACCOUNT_DELETE_LIMIT",
            "ACCOUNT_DELETE_WINDOW_SECONDS",
            "ACCOUNT_DELETION_MAX_ATTEMPTS",
            "ACCOUNT_SECURITY_RETENTION_DAYS",
            "ACCOUNT_DELETION_LEDGER_RETENTION_DAYS",
            "ACCOUNT_RECOVERABLE_BACKUP_DAYS",
            "ACCOUNT_DELETION_WORKER_ID",
            "ACCOUNT_DELETION_JOB_LEASE_SECONDS",
            "ACCOUNT_DELETION_STEP_TIMEOUT_SECONDS",
            "ACCOUNT_DELETION_POLL_INTERVAL_MS",
            "ACCOUNT_DELETION_RETRY_BASE_SECONDS",
            "ACCOUNT_DELETION_RETRY_MAX_SECONDS",
            "ACCOUNT_DELETION_CLEANUP_INTERVAL_SECONDS",
            "ACCOUNT_DELETION_CLEANUP_BATCH_SIZE",
            "ACCOUNT_DELETION_PENDING_FILE_MAX_AGE_SECONDS",
            "PAKPERK_ADMIN_ACTOR",
            "RUST_LOG",
            "LOG_FORMAT",
        )
        if name in os.environ
    }
    environment["RUN_MIGRATIONS"] = "false"
    result = subprocess.run(
        [str(config.worker_binary), *arguments],
        capture_output=True,
        text=True,
        env=environment,
        timeout=45,
        check=False,
    )
    if result.returncode != 0:
        raise AcceptanceError(
            f"account-deletion maintenance command {arguments[0]} failed"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AcceptanceError(
            f"account-deletion maintenance command {arguments[0]} returned malformed JSON"
        ) from error
    if not isinstance(payload, dict):
        raise AcceptanceError("account-deletion maintenance output was not an object")
    return payload


def completion_snapshot(
    config: Config, user_id: str, operation_id: str
) -> dict[str, Any]:
    operation_id = checked_uuid(operation_id, "operation ID")
    user_id = checked_uuid(user_id, "local user ID")
    return sql_json(
        config,
        f"""
        SELECT json_build_object(
            'user_count', (SELECT count(*) FROM users WHERE id = '{user_id}'::uuid),
            'ledger_count', (SELECT count(*) FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid),
            'externalized', COALESCE((SELECT externalized_at IS NOT NULL FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid), false),
            'ledger_completed', COALESCE((SELECT completed_at IS NOT NULL FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid), false),
            'job_count', (SELECT count(*) FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid),
            'job_state', COALESCE((SELECT state FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid), ''),
            'provider_checkpoint', COALESCE((SELECT provider_identity_deleted_at IS NOT NULL FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid), false),
            'app_checkpoint', COALESCE((SELECT app_data_deleted_at IS NOT NULL FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid), false),
            'provider_coordinates_cleared', COALESCE((SELECT oidc_issuer IS NULL AND oidc_subject IS NULL FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid), false),
            'requested_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'requested'),
            'sessions_revoked_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'sessions_revoked'),
            'identity_deleted_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'identity_deleted'),
            'app_data_deleted_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'app_data_deleted'),
            'completed_events', (SELECT count(*) FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid AND to_state = 'completed')
        )::text;
        """,
        "completed deletion snapshot",
    )


def assert_provider_absent(config: Config, subject: str) -> None:
    token = admin_access_token(config)
    response = HTTP.get(
        f"{config.admin_realm_url}/users/{checked_uuid(subject, 'Keycloak user ID')}",
        headers={"Authorization": f"Bearer {token}"},
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, 404, "verify provider identity deletion")


def assert_refresh_revoked(config: Config, refresh_token: str) -> None:
    response = HTTP.post(
        config.token_url,
        data={
            "grant_type": "refresh_token",
            "client_id": config.oidc_client_id,
            "refresh_token": refresh_token,
        },
        allow_redirects=False,
        timeout=15,
    )
    if response.status_code not in {400, 401}:
        raise AcceptanceError("revoked provider session accepted a refresh request")
    try:
        payload = response.json()
    except ValueError:
        payload = {}
    if isinstance(payload, dict) and isinstance(payload.get("access_token"), str):
        raise AcceptanceError("revoked provider session returned a new access token")


def verify(config: Config) -> None:
    state = load_state(config)
    if state is None:
        raise AcceptanceError("live account-deletion state is missing")
    user_id = checked_uuid(state.get("local_user_id"), "local user ID")
    subject = checked_uuid(state.get("keycloak_user_id"), "Keycloak user ID")
    operation_id = checked_uuid(state.get("operation_id"), "operation ID")
    access_token = state.get("access_token")
    refresh_token = state.get("refresh_token")
    if not isinstance(access_token, str) or not isinstance(refresh_token, str):
        raise AcceptanceError("live state omitted its in-memory token pair")

    wait_for_completed(config, operation_id)
    first = completion_snapshot(config, user_id, operation_id)
    required_once = {
        "user_count": 0,
        "ledger_count": 1,
        "externalized": True,
        "ledger_completed": True,
        "job_count": 1,
        "job_state": "completed",
        "provider_checkpoint": True,
        "app_checkpoint": True,
        "provider_coordinates_cleared": True,
        "requested_events": 1,
        "sessions_revoked_events": 1,
        "identity_deleted_events": 1,
        "app_data_deleted_events": 1,
        "completed_events": 1,
    }
    if first != required_once:
        raise AcceptanceError(
            "worker completion did not persist every deletion checkpoint"
        )
    assert_external_ledger(config, operation_id)
    assert_provider_absent(config, subject)
    assert_refresh_revoked(config, refresh_token)

    ledger_check = maintenance_command(config, "verify-ledger")
    if ledger_check.get("verified_records") != 1:
        raise AcceptanceError(
            "signed external ledger verification did not find one record"
        )

    replay = expect_status(
        api_request(config, "DELETE", "/v1/me", access_token),
        202,
        "post-completion deletion replay",
    )
    replay_operation, replay_state = deletion_envelope(
        replay, "post-completion deletion replay"
    )
    if replay_operation != operation_id or replay_state != "completed":
        raise AcceptanceError("post-completion replay changed the deletion operation")
    blocked = api_request(config, "GET", "/v1/me", access_token)
    expect_status(blocked, 403, "old access token after application purge")
    if api_error_code(blocked) != "ACCOUNT_DELETION_PENDING":
        raise AcceptanceError("old access token did not remain tombstoned")

    reapply = maintenance_command(config, "reapply-ledger")
    if (
        reapply.get("verified_records") != 1
        or reapply.get("requeued_provider_reconciliation") != 1
        or any(
            reapply.get(field) != 0
            for field in (
                "unchanged",
                "restored_and_queued",
                "requeued_resurrected_data",
            )
        )
    ):
        raise AcceptanceError(
            "ledger reapply did not queue one provider reconciliation"
        )
    wait_for_completed(config, operation_id)
    second = completion_snapshot(config, user_id, operation_id)
    for field in (
        "requested_events",
        "sessions_revoked_events",
        "identity_deleted_events",
        "app_data_deleted_events",
        "completed_events",
    ):
        if second.get(field) != 2:
            raise AcceptanceError("provider reconciliation was not repeat-safe")
    for field in ("user_count", "ledger_count", "job_count"):
        if second.get(field) != required_once[field]:
            raise AcceptanceError("provider reconciliation duplicated durable state")
    if second.get("job_state") != "completed" or not second.get("ledger_completed"):
        raise AcceptanceError("provider reconciliation did not return to completed")
    assert_provider_absent(config, subject)
    print(
        "PASS worker revoked sessions, deleted the provider identity, and purged app data"
    )
    print(
        "PASS signed ledger verification and completed API replay remained idempotent"
    )
    print(
        "PASS restore-ledger provider reconciliation succeeded with an absent identity"
    )


def cleanup_database(config: Config, state: dict[str, Any]) -> None:
    operation = state.get("operation_id")
    user = state.get("local_user_id")
    statements = ["BEGIN;"]
    if operation:
        operation_id = checked_uuid(operation, "cleanup operation ID")
        statements.extend(
            [
                f"DELETE FROM account_deletion_events WHERE operation_id = '{operation_id}'::uuid;",
                f"DELETE FROM account_deletion_jobs WHERE operation_id = '{operation_id}'::uuid;",
                f"DELETE FROM account_deletion_ledger WHERE operation_id = '{operation_id}'::uuid;",
            ]
        )
    if user:
        user_id = checked_uuid(user, "cleanup user ID")
        statements.extend(
            [
                "DELETE FROM shared_rate_limit_buckets WHERE bucket = 'account_delete' "
                f"AND scope_key = 'user:{user_id}';",
                f"DELETE FROM users WHERE id = '{user_id}'::uuid;",
            ]
        )
    statements.append("COMMIT;")
    psql(config, "\n".join(statements))


def cleanup_keycloak(config: Config, state: dict[str, Any]) -> None:
    subject = state.get("keycloak_user_id")
    if not subject:
        return
    token = admin_access_token(config)
    response = HTTP.delete(
        f"{config.admin_realm_url}/users/{checked_uuid(subject, 'cleanup Keycloak user ID')}",
        headers={"Authorization": f"Bearer {token}"},
        allow_redirects=False,
        timeout=15,
    )
    expect_status(response, (204, 404), "cleanup disposable Keycloak identity")


def cleanup(config: Config) -> None:
    state = load_state(config)
    if state is None:
        return
    cleanup_database(config, state)
    cleanup_keycloak(config, state)
    state["cleaned"] = True
    save_state(config, state)


def audit_logs(config: Config) -> None:
    state = load_state(config) or {}
    candidates: list[Any] = [
        config.token_sentinel,
        state.get("access_token"),
        state.get("refresh_token"),
        state.get("keycloak_user_id"),
        state.get("local_user_id"),
    ]
    if config.worker_secret_file.exists():
        candidates.append(config.worker_secret_file.read_text(encoding="utf-8"))
    protected: list[str] = [
        value for value in candidates if isinstance(value, str) and value
    ]
    for path in config.log_files:
        if not path.exists():
            continue
        contents = path.read_text(encoding="utf-8", errors="replace")
        if any(secret in contents for secret in protected):
            raise AcceptanceError(
                "captured process logs contain protected acceptance data"
            )
    print(
        "PASS captured API and worker logs contain no token or client-secret sentinel"
    )


class ContractTests(unittest.TestCase):
    def test_loopback_origins_are_bounded(self) -> None:
        self.assertEqual(
            loopback_http_origin("http://127.0.0.1:18084", "TEST"),
            "http://127.0.0.1:18084",
        )
        for value in (
            "https://127.0.0.1:18084",
            "http://example.com:18084",
            "http://user:secret@localhost:18084",
            "http://localhost",
            "http://localhost:18084/path",
        ):
            with self.subTest(value=value), self.assertRaises(AcceptanceError):
                loopback_http_origin(value, "TEST")

    def test_postgres_target_must_be_loopback(self) -> None:
        self.assertEqual(
            loopback_postgres_url("postgres://u:p@127.0.0.1:5432/pakperk"),
            "postgres://u:p@127.0.0.1:5432/pakperk",
        )
        with self.assertRaises(AcceptanceError):
            loopback_postgres_url("postgres://u:p@db.example/pakperk")

    def test_provider_navigation_and_callback_are_exact(self) -> None:
        provider = "http://127.0.0.1:8081"
        action = f"{provider}/realms/pakperk/login-actions/authenticate?code=one"
        self.assertEqual(
            same_http_origin_url(action, provider, "TEST"),
            action,
        )
        for value in (
            "http://127.0.0.1:8082/realms/pakperk/login-actions/authenticate",
            "http://example.com:8081/realms/pakperk/login-actions/authenticate",
            "http://user:secret@127.0.0.1:8081/login",
        ):
            with self.subTest(value=value), self.assertRaises(AcceptanceError):
                same_http_origin_url(value, provider, "TEST")

        redirect = "pakperk-auth-dev://oauth/callback?code=one&state=two"
        self.assertEqual(
            exact_native_redirect_query(
                redirect,
                "pakperk-auth-dev://oauth/callback",
            ),
            {"code": ["one"], "state": ["two"]},
        )
        for value in (
            "pakperk-auth-dev://oauth/callback-evil?code=one&state=two",
            "pakperk-auth-dev://other/callback?code=one&state=two",
            "pakperk-auth-dev://oauth/callback?code=one&state=two#fragment",
        ):
            with self.subTest(value=value), self.assertRaises(AcceptanceError):
                exact_native_redirect_query(
                    value,
                    "pakperk-auth-dev://oauth/callback",
                )

    def test_safe_error_projection_never_returns_response_detail(self) -> None:
        class Response:
            @staticmethod
            def json() -> dict[str, Any]:
                return {
                    "error": {
                        "code": "REAUTHENTICATION_REQUIRED",
                        "message": "protected-response-sentinel",
                    }
                }

        self.assertEqual(safe_response_error(Response()), "REAUTHENTICATION_REQUIRED")
        self.assertNotIn("protected-response-sentinel", safe_response_error(Response()))

    def test_harness_and_manual_workflow_keep_live_execution_opt_in(self) -> None:
        root = Path(__file__).resolve().parents[1]
        wrapper = (root / "scripts/test_live_account_deletion.sh").read_text(
            encoding="utf-8"
        )
        workflow = (root / ".github/workflows/live-account-deletion.yml").read_text(
            encoding="utf-8"
        )
        ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("LIVE_ACCOUNT_DELETION_CONFIRM:-", wrapper)
        self.assertIn("RUN_DISPOSABLE_KEYCLOAK_DELETION", wrapper)
        self.assertIn("ACCOUNT_DELETION_ENABLED=true", wrapper)
        self.assertIn('"$worker_binary" run', wrapper)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertIn("RUN_DISPOSABLE_KEYCLOAK_DELETION", workflow)
        self.assertIn("test_live_account_deletion.sh --self-test", ci)


def run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("validate", "prepare", "verify", "cleanup", "audit", "self-test"),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "self-test":
        return run_self_tests()
    try:
        config = Config.load()
        if arguments.command == "validate":
            print("PASS live account-deletion targets are bounded to loopback")
            return 0
        load_http_dependencies()
        if arguments.command == "prepare":
            prepare(config)
        elif arguments.command == "verify":
            verify(config)
        elif arguments.command == "cleanup":
            cleanup(config)
        else:
            audit_logs(config)
    except AcceptanceError as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - never serialize external details.
        print(f"FAIL unexpected {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
