#!/usr/bin/env python3
"""Phase 5 live comments acceptance driver.

The shell wrapper owns processes and Compose services. This driver owns only
disposable Keycloak identities, disposable PostgreSQL fixtures, and the HTTP
acceptance matrix. It deliberately keeps bearer tokens in memory and reports
failures without echoing request bodies, credentials, or response bodies.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from typing import Any, Iterable
from urllib.parse import parse_qs, urlencode, urljoin, urlparse
import uuid

import requests
from bs4 import BeautifulSoup


class AcceptanceError(RuntimeError):
    """A bounded, safe-to-print acceptance failure."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise AcceptanceError(f"{name} is required")
    return value


PROJECT_DIR = Path(required_env("LIVE_COMMENTS_PROJECT_DIR"))
STATE_FILE = Path(required_env("LIVE_COMMENTS_STATE_FILE"))
WRITE_API = required_env("LIVE_COMMENTS_WRITE_API").rstrip("/")
READ_ONLY_API = required_env("LIVE_COMMENTS_READ_ONLY_API").rstrip("/")
UNAVAILABLE_API = required_env("LIVE_COMMENTS_UNAVAILABLE_API").rstrip("/")
KEYCLOAK_BASE = required_env("LIVE_COMMENTS_KEYCLOAK_BASE_URL").rstrip("/")
KEYCLOAK_REALM = os.environ.get("LIVE_COMMENTS_KEYCLOAK_REALM", "pakperk")
OIDC_CLIENT_ID = os.environ.get(
    "LIVE_COMMENTS_OIDC_CLIENT_ID", "pakperk-mobile-dev"
)
OIDC_REDIRECT_URI = os.environ.get(
    "LIVE_COMMENTS_OIDC_REDIRECT_URI", "pakperk-auth-dev://oauth/callback"
)
ADMIN_OIDC_AUDIENCE = required_env("LIVE_COMMENTS_ADMIN_OIDC_AUDIENCE")
ADMIN_USERNAME = required_env("LIVE_COMMENTS_KEYCLOAK_ADMIN_USERNAME")
ADMIN_PASSWORD = required_env("LIVE_COMMENTS_KEYCLOAK_ADMIN_PASSWORD")
POSTGRES_USER = os.environ.get("LIVE_COMMENTS_POSTGRES_USER", "pakperk")
POSTGRES_DB = os.environ.get("LIVE_COMMENTS_POSTGRES_DB", "pakperk")
RUN_ID = required_env("LIVE_COMMENTS_RUN_ID")
UGC_SENTINEL = required_env("LIVE_COMMENTS_UGC_SENTINEL")
TOKEN_SENTINEL = required_env("LIVE_COMMENTS_TOKEN_SENTINEL")
COMMENT_SECRET_FILE = Path(required_env("LIVE_COMMENTS_COMMENT_SECRET_FILE"))
ADMIN_BINARY = Path(required_env("LIVE_COMMENTS_ADMIN_BINARY"))
ADMIN_DATABASE_URL = required_env("LIVE_COMMENTS_DATABASE_URL")
ADMIN_ACCESS_TOKEN_FILE = Path(
    required_env("LIVE_COMMENTS_ADMIN_ACCESS_TOKEN_FILE")
)
UNAUTHORIZED_ADMIN_ACCESS_TOKEN_FILE = Path(
    required_env("LIVE_COMMENTS_ADMIN_UNAUTHORIZED_ACCESS_TOKEN_FILE")
)
CURRENT_TERMS_VERSION = os.environ.get(
    "LIVE_COMMENTS_CURRENT_TERMS_VERSION", "2026-07-31"
)
CURRENT_GUIDELINES_VERSION = os.environ.get(
    "LIVE_COMMENTS_CURRENT_GUIDELINES_VERSION", "2026-07-31"
)
API_LOGS = [
    Path(value)
    for value in required_env("LIVE_COMMENTS_API_LOGS").split(os.pathsep)
    if value
]

ISSUER = f"{KEYCLOAK_BASE}/realms/{KEYCLOAK_REALM}"
ADMIN_REALM_URL = f"{KEYCLOAK_BASE}/admin/realms/{KEYCLOAK_REALM}"
TOKEN_URL = f"{ISSUER}/protocol/openid-connect/token"
AUTHORIZE_URL = f"{ISSUER}/protocol/openid-connect/auth"
LOCAL_HTTP = requests.Session()
# Every network target in this harness is an explicitly configured loopback
# service. Ambient developer/CI proxy variables must never intercept bearer
# tokens, Keycloak sessions, or localhost acceptance traffic.
LOCAL_HTTP.trust_env = False


def safe_response_error(response: requests.Response) -> str:
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


def expect_status(
    response: requests.Response,
    expected: int | Iterable[int],
    operation: str,
) -> requests.Response:
    expected_values = {expected} if isinstance(expected, int) else set(expected)
    if response.status_code not in expected_values:
        wanted = "/".join(str(value) for value in sorted(expected_values))
        raise AcceptanceError(
            f"{operation} returned HTTP {response.status_code}, expected {wanted} "
            f"({safe_response_error(response)})"
        )
    return response


def response_json(response: requests.Response, operation: str) -> dict[str, Any]:
    try:
        value = response.json()
    except ValueError as error:
        raise AcceptanceError(f"{operation} did not return JSON") from error
    if not isinstance(value, dict):
        raise AcceptanceError(f"{operation} returned a non-object JSON envelope")
    return value


def error_code(response: requests.Response) -> str | None:
    try:
        payload = response.json()
    except ValueError:
        return None
    error = payload.get("error") if isinstance(payload, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def api_request(
    method: str,
    base: str,
    path: str,
    *,
    token: str | None = None,
    json_body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> requests.Response:
    request_headers = {
        "Accept": "application/json",
        "X-Pakperk-Live-Token-Sentinel": TOKEN_SENTINEL,
    }
    if token is not None:
        request_headers["Authorization"] = f"Bearer {token}"
    if headers:
        request_headers.update(headers)
    try:
        return LOCAL_HTTP.request(
            method,
            f"{base}{path}",
            headers=request_headers,
            json=json_body,
            timeout=15,
        )
    except requests.RequestException as error:
        raise AcceptanceError(f"{method} {path} could not reach the API") from error


def admin_access_token() -> str:
    try:
        response = LOCAL_HTTP.post(
            f"{KEYCLOAK_BASE}/realms/master/protocol/openid-connect/token",
            data={
                "client_id": "admin-cli",
                "grant_type": "password",
                "username": ADMIN_USERNAME,
                "password": ADMIN_PASSWORD,
            },
            timeout=15,
        )
    except requests.RequestException as error:
        raise AcceptanceError("Keycloak administration endpoint is unavailable") from error
    expect_status(response, 200, "Keycloak administrator bootstrap")
    token = response_json(response, "Keycloak administrator bootstrap").get("access_token")
    if not isinstance(token, str) or not token:
        raise AcceptanceError("Keycloak administrator bootstrap returned no access token")
    return token


def create_keycloak_user(username: str, password: str, state: dict[str, Any]) -> str:
    token = admin_access_token()
    response = LOCAL_HTTP.post(
        f"{ADMIN_REALM_URL}/users",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "username": username,
            "email": f"{username}@pakperk.test",
            "firstName": "Pakperk",
            "lastName": "Acceptance",
            "emailVerified": True,
            "enabled": True,
            "requiredActions": [],
            "credentials": [
                {"type": "password", "value": password, "temporary": False}
            ],
        },
        timeout=15,
    )
    expect_status(response, 201, "create disposable Keycloak user")
    location = response.headers.get("Location", "")
    user_id = location.rstrip("/").rsplit("/", 1)[-1]
    try:
        uuid.UUID(user_id)
    except ValueError as error:
        raise AcceptanceError("Keycloak user creation returned no stable user ID") from error
    state["keycloak_user_ids"].append(user_id)
    save_state(state)
    return user_id


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def jwt_payload(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise AcceptanceError("OIDC access token is not a compact JWT")
    padded = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        value = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, json.JSONDecodeError) as error:
        raise AcceptanceError("OIDC access token payload is malformed") from error
    if not isinstance(value, dict):
        raise AcceptanceError("OIDC access token payload is not an object")
    return value


def authorization_code_pkce(username: str, password: str, expected_sub: str) -> str:
    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state_value = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    session = requests.Session()
    session.trust_env = False
    response = session.get(
        AUTHORIZE_URL,
        params={
            "client_id": OIDC_CLIENT_ID,
            "redirect_uri": OIDC_REDIRECT_URI,
            "response_type": "code",
            "scope": "openid profile",
            "state": state_value,
            "nonce": nonce,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        },
        timeout=15,
    )
    expect_status(response, 200, "Authorization Code + PKCE authorization")
    soup = BeautifulSoup(response.text, "html.parser")
    form = soup.select_one("form#kc-form-login")
    if form is None or not form.get("action"):
        raise AcceptanceError("Keycloak did not present its login form")

    # Keycloak correctly marks its authorization-session cookies Secure. Real
    # browsers apply the localhost secure-context exception even when the
    # checked-in development issuer uses HTTP; Requests intentionally follows
    # the stricter generic cookie-jar rule. Relax only those in-memory cookies
    # for this exact loopback development issuer so the form submission has
    # the same browser session continuity. Cookie values are never serialized.
    issuer_url = urlparse(ISSUER)
    if issuer_url.scheme == "http" and issuer_url.hostname in {
        "localhost",
        "127.0.0.1",
        "::1",
    }:
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
    form_data["username"] = username
    form_data["password"] = password
    login = session.post(
        urljoin(response.url, str(form["action"])),
        data=form_data,
        headers={"Referer": response.url},
        allow_redirects=False,
        timeout=15,
    )
    expect_status(login, (302, 303), "Keycloak login form submission")
    location = login.headers.get("Location", "")
    if not location.startswith(OIDC_REDIRECT_URI):
        target = urlparse(location)
        safe_target = f"{target.scheme}://{target.hostname or ''}{target.path}"
        raise AcceptanceError(
            "Keycloak login did not return to the native redirect URI "
            f"(returned {safe_target})"
        )
    query = parse_qs(urlparse(location).query)
    if query.get("state") != [state_value] or len(query.get("code", [])) != 1:
        raise AcceptanceError("Authorization redirect state/code validation failed")
    code = query["code"][0]

    exchanged = session.post(
        TOKEN_URL,
        data={
            "grant_type": "authorization_code",
            "client_id": OIDC_CLIENT_ID,
            "redirect_uri": OIDC_REDIRECT_URI,
            "code": code,
            "code_verifier": verifier,
        },
        timeout=15,
    )
    expect_status(exchanged, 200, "Authorization Code + PKCE token exchange")
    token = response_json(exchanged, "Authorization Code + PKCE token exchange").get(
        "access_token"
    )
    if not isinstance(token, str) or not token:
        raise AcceptanceError("Authorization Code + PKCE returned no access token")
    claims = jwt_payload(token)
    audience = claims.get("aud")
    audiences = {audience} if isinstance(audience, str) else set(audience or [])
    if (
        claims.get("iss") != ISSUER
        or claims.get("sub") != expected_sub
        or "pakperk-api" not in audiences
        or ADMIN_OIDC_AUDIENCE not in audiences
        or not isinstance(claims.get("auth_time"), int)
    ):
        raise AcceptanceError("Authorization Code + PKCE token claims are not API-bound")
    return token


def write_private_access_token(path: Path, token: str) -> None:
    if not path.is_absolute():
        raise AcceptanceError("live-comments admin access-token path is not absolute")
    if not token or len(token.encode("utf-8")) > 16 * 1024 or any(
        character.isspace() for character in token
    ):
        raise AcceptanceError("OIDC access token is not safe for the admin token file")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(
                descriptor, "w", encoding="utf-8", closefd=False
            ) as token_file:
                token_file.write(token)
                token_file.write("\n")
                token_file.flush()
                os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        raise AcceptanceError("could not create the private admin token file") from error

    try:
        mode = path.stat().st_mode
    except OSError as error:
        raise AcceptanceError("could not verify the private admin token file") from error
    if mode & 0o077:
        raise AcceptanceError("admin access-token file is not owner-only")


def assert_user_direct_grant_disabled(username: str, password: str) -> None:
    response = LOCAL_HTTP.post(
        TOKEN_URL,
        data={
            "grant_type": "password",
            "client_id": OIDC_CLIENT_ID,
            "username": username,
            "password": password,
        },
        timeout=15,
    )
    if response.status_code == 200 or "access_token" in response.text:
        raise AcceptanceError("native client unexpectedly accepted a direct password grant")
    if response.status_code not in {400, 401}:
        raise AcceptanceError(
            "native client direct-grant rejection returned an unexpected status"
        )


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def checked_uuid(value: str) -> str:
    return str(uuid.UUID(value))


def psql(sql: str) -> str:
    command = [
        "docker",
        "compose",
        "--project-directory",
        str(PROJECT_DIR),
        "exec",
        "-T",
        "postgres",
        "psql",
        "-X",
        "--quiet",
        "--set",
        "ON_ERROR_STOP=1",
        "--username",
        POSTGRES_USER,
        "--dbname",
        POSTGRES_DB,
        "--tuples-only",
        "--no-align",
        "--command",
        sql,
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise AcceptanceError("PostgreSQL fixture command failed")
    return result.stdout.strip()


def seed_paper(state: dict[str, Any]) -> str:
    paper_id = str(uuid.uuid4())
    state["paper_id"] = paper_id
    save_state(state)
    arxiv_base_id = f"live-comments-{RUN_ID[:16]}"
    psql(
        f"""
        INSERT INTO papers (
            id, arxiv_base_id, arxiv_version, title, abstract, authors,
            primary_category, categories, published_at, updated_at,
            abs_url, pdf_url, metadata_fetched_at
        ) VALUES (
            {sql_literal(paper_id)}::uuid,
            {sql_literal(arxiv_base_id)},
            1,
            'Live comments acceptance paper',
            'Disposable metadata-only paper for the live comments acceptance harness.',
            '[\"Pakperk Acceptance\"]'::jsonb,
            'cs.AI',
            ARRAY['cs.AI'],
            statement_timestamp(),
            statement_timestamp(),
            'https://arxiv.org/abs/2401.00001',
            'https://arxiv.org/pdf/2401.00001',
            statement_timestamp()
        );
        """
    )
    return paper_id


def preparation_snapshot(paper_id: str) -> str:
    value = psql(
        f"""
        SELECT json_build_object(
            'processing_rows', (
                SELECT count(*) FROM paper_processing
                WHERE paper_id = {sql_literal(checked_uuid(paper_id))}::uuid
            ),
            'job_rows', (
                SELECT count(*) FROM jobs
                WHERE paper_id = {sql_literal(checked_uuid(paper_id))}::uuid
            ),
            'processing_stage', COALESCE((
                SELECT stage FROM paper_processing
                WHERE paper_id = {sql_literal(checked_uuid(paper_id))}::uuid
            ), ''),
            'processing_updated_at', COALESCE((
                SELECT max(updated_at)::text FROM paper_processing
                WHERE paper_id = {sql_literal(checked_uuid(paper_id))}::uuid
            ), ''),
            'jobs_updated_at', COALESCE((
                SELECT max(updated_at)::text FROM jobs
                WHERE paper_id = {sql_literal(checked_uuid(paper_id))}::uuid
            ), '')
        )::text;
        """
    )
    try:
        snapshot = json.loads(value)
    except json.JSONDecodeError as error:
        raise AcceptanceError("could not decode preparation/job snapshot") from error
    if (
        snapshot["processing_rows"] != 1
        or snapshot["processing_stage"] != "not_requested"
        or snapshot["job_rows"] != 0
    ):
        raise AcceptanceError(
            "disposable paper did not have its canonical not_requested baseline"
        )
    return json.dumps(snapshot, sort_keys=True)


def save_state(state: dict[str, Any]) -> None:
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(STATE_FILE)


def load_state() -> dict[str, Any] | None:
    if not STATE_FILE.exists():
        return None
    try:
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError("could not read live-comments cleanup state") from error
    if not isinstance(state, dict):
        raise AcceptanceError("live-comments cleanup state is malformed")
    return state


def onboard(token: str, handle: str, state: dict[str, Any]) -> str:
    current_response = expect_status(
        api_request("GET", WRITE_API, "/v1/me", token=token),
        200,
        "GET /v1/me",
    )
    current = response_json(current_response, "GET /v1/me").get("account")
    if not isinstance(current, dict):
        raise AcceptanceError("GET /v1/me omitted the account projection")
    user_id = checked_uuid(str(current.get("id", "")))
    if user_id not in state["local_user_ids"]:
        state["local_user_ids"].append(user_id)
        save_state(state)
    if current.get("current_terms_version") != CURRENT_TERMS_VERSION:
        raise AcceptanceError("API current Terms version differs from the harness contract")
    if current.get("current_community_guidelines_version") != CURRENT_GUIDELINES_VERSION:
        raise AcceptanceError(
            "API current Community Guidelines version differs from the harness contract"
        )
    etag = current_response.headers.get("ETag")
    if not etag:
        raise AcceptanceError("GET /v1/me omitted its strong profile ETag")
    updated_response = expect_status(
        api_request(
            "PATCH",
            WRITE_API,
            "/v1/me",
            token=token,
            headers={"If-Match": etag},
            json_body={
                "handle": handle,
                "accept_terms_version": CURRENT_TERMS_VERSION,
                "accept_community_guidelines_version": CURRENT_GUIDELINES_VERSION,
            },
        ),
        200,
        "PATCH /v1/me onboarding",
    )
    updated = response_json(updated_response, "PATCH /v1/me onboarding").get("account")
    if not isinstance(updated, dict) or not all(
        updated.get(field) is True
        for field in (
            "terms_current",
            "community_guidelines_current",
            "comment_profile_complete",
        )
    ):
        raise AcceptanceError("comment onboarding did not become complete")
    return user_id


def comment_ids(items: Any) -> set[str]:
    if not isinstance(items, list):
        raise AcceptanceError("comment page items are not an array")
    return {str(item.get("id")) for item in items if isinstance(item, dict)}


def block_ids(items: Any) -> set[str]:
    if not isinstance(items, list):
        raise AcceptanceError("blocked-user page items are not an array")
    values: set[str] = set()
    for item in items:
        if isinstance(item, dict) and isinstance(item.get("user"), dict):
            values.add(str(item["user"].get("id")))
    return values


def record_comment(state: dict[str, Any], comment_id: str) -> None:
    checked_uuid(comment_id)
    if comment_id not in state["comment_ids"]:
        state["comment_ids"].append(comment_id)
        save_state(state)


def run_admin_process(
    operator_user_id: str,
    access_token_file: Path,
    *arguments: str,
) -> subprocess.CompletedProcess[str]:
    issuer_scheme = urlparse(ISSUER).scheme
    environment = os.environ.copy()
    environment.update(
        {
            "DATABASE_URL": ADMIN_DATABASE_URL,
            "ADMIN_DATABASE_POOL_SIZE": "2",
            "ADMIN_OIDC_ISSUER_URL": ISSUER,
            "ADMIN_OIDC_AUDIENCE": ADMIN_OIDC_AUDIENCE,
            "ADMIN_OIDC_ALLOWED_ALGORITHMS": "RS256",
            "ADMIN_OIDC_ALLOW_INSECURE_HTTP": str(
                issuer_scheme == "http"
            ).lower(),
            "ADMIN_AUTH_MAX_AGE_SECONDS": "900",
            "ADMIN_AUTHORIZED_USER_IDS": checked_uuid(operator_user_id),
            "PAKPERK_ADMIN_ACCESS_TOKEN_FILE": str(access_token_file),
        }
    )
    return subprocess.run(
        [str(ADMIN_BINARY), *arguments],
        capture_output=True,
        text=True,
        env=environment,
        timeout=30,
        check=False,
    )


def admin_command(
    operator_user_id: str, *arguments: str
) -> tuple[dict[str, Any], str]:
    result = run_admin_process(
        operator_user_id, ADMIN_ACCESS_TOKEN_FILE, *arguments
    )
    if result.returncode != 0:
        action = " ".join(arguments[:2])
        raise AcceptanceError(f"pakperk-admin {action} failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AcceptanceError("pakperk-admin returned malformed JSON") from error
    if not isinstance(payload, dict):
        raise AcceptanceError("pakperk-admin returned a non-object JSON envelope")
    return payload, result.stdout


def assert_unallowlisted_admin_fails(
    reader_token: str, operator_user_id: str
) -> None:
    if UNAUTHORIZED_ADMIN_ACCESS_TOKEN_FILE == ADMIN_ACCESS_TOKEN_FILE:
        raise AcceptanceError("admin acceptance token fixtures must use separate files")
    write_private_access_token(UNAUTHORIZED_ADMIN_ACCESS_TOKEN_FILE, reader_token)
    try:
        result = run_admin_process(
            operator_user_id,
            UNAUTHORIZED_ADMIN_ACCESS_TOKEN_FILE,
            "comments",
            "list",
            "--status",
            "open",
            "--limit",
            "1",
        )
    finally:
        try:
            UNAUTHORIZED_ADMIN_ACCESS_TOKEN_FILE.unlink(missing_ok=True)
        except OSError as error:
            raise AcceptanceError(
                "could not remove the unauthorized admin token fixture"
            ) from error

    if result.returncode == 0:
        raise AcceptanceError("a valid non-allowlisted user gained admin access")
    captured = result.stdout + result.stderr
    forbidden = (
        reader_token,
        reader_token[-32:],
        UGC_SENTINEL,
        TOKEN_SENTINEL,
        '"body"',
        '"detail"',
    )
    if any(value and value in captured for value in forbidden):
        raise AcceptanceError(
            "failed admin authorization disclosed token material or protected UGC"
        )


def run_admin_matrix(
    author_token: str,
    author_user_id: str,
    operator_user_id: str,
    paper_comments_path: str,
    published_comment_id: str,
    pending_comment_id: str,
    report_id: str,
    user_report_id: str,
) -> int:
    non_inspect_outputs: list[str] = []

    def operator_command(*arguments: str) -> tuple[dict[str, Any], str]:
        return admin_command(operator_user_id, *arguments)

    pending_page, raw = operator_command(
        "comments", "list", "--status", "pending_review", "--limit", "100"
    )
    non_inspect_outputs.append(raw)
    pending_ids = {
        str(item.get("comment_id"))
        for item in pending_page.get("items", [])
        if isinstance(item, dict)
    }
    if pending_comment_id not in pending_ids:
        raise AcceptanceError("pakperk-admin pending queue omitted the held comment")

    report_page, raw = operator_command(
        "comments", "list", "--status", "open", "--limit", "100"
    )
    non_inspect_outputs.append(raw)
    report_ids = {
        str(item.get("report_id"))
        for item in report_page.get("items", [])
        if isinstance(item, dict)
    }
    if report_id not in report_ids:
        raise AcceptanceError("pakperk-admin open-report queue omitted the canonical report")

    user_report_page, raw = operator_command(
        "user-reports", "list", "--status", "open", "--limit", "100"
    )
    non_inspect_outputs.append(raw)
    user_report_ids = {
        str(item.get("report_id"))
        for item in user_report_page.get("items", [])
        if isinstance(item, dict)
    }
    if user_report_id not in user_report_ids:
        raise AcceptanceError("pakperk-admin user-report queue omitted the canonical report")

    for raw_output in non_inspect_outputs:
        if UGC_SENTINEL in raw_output or '"body"' in raw_output or '"detail"' in raw_output:
            raise AcceptanceError("pakperk-admin list output serialized protected UGC")

    inspection, inspection_raw = operator_command(
        "comments", "inspect", published_comment_id
    )
    if (
        inspection.get("comment_id") != published_comment_id
        or UGC_SENTINEL not in inspection_raw
        or not any(
            isinstance(report, dict) and str(report.get("report_id")) == report_id
            for report in inspection.get("reports", [])
        )
    ):
        raise AcceptanceError("explicit pakperk-admin inspect omitted its selected UGC/report")

    user_report_inspection, user_report_inspection_raw = operator_command(
        "user-reports", "inspect", user_report_id
    )
    if (
        str(user_report_inspection.get("report_id")) != user_report_id
        or str(user_report_inspection.get("reported_user_id")) != author_user_id
        or '"detail"' not in user_report_inspection_raw
    ):
        raise AcceptanceError("explicit user-report inspect omitted its selected report")

    hidden, raw = operator_command(
        "comments", "hide", published_comment_id, "--reason", "live_acceptance"
    )
    non_inspect_outputs.append(raw)
    if hidden.get("status") != "hidden" or hidden.get("replayed") is not False:
        raise AcceptanceError("pakperk-admin hide did not apply")
    hidden_page = response_json(
        expect_status(
            api_request("GET", READ_ONLY_API, paper_comments_path),
            200,
            "public API after admin hide",
        ),
        "public API after admin hide",
    )
    if published_comment_id in comment_ids(hidden_page.get("items")):
        raise AcceptanceError("admin-hidden comment remained publicly visible")

    restored, raw = operator_command("comments", "restore", published_comment_id)
    non_inspect_outputs.append(raw)
    if restored.get("status") != "published" or restored.get("replayed") is not False:
        raise AcceptanceError("pakperk-admin restore did not apply")
    restored_version = restored.get("version")
    if not isinstance(restored_version, int):
        raise AcceptanceError("pakperk-admin restore omitted the canonical version")
    restored_page = response_json(
        expect_status(
            api_request("GET", WRITE_API, paper_comments_path),
            200,
            "public API after admin restore",
        ),
        "public API after admin restore",
    )
    if published_comment_id not in comment_ids(restored_page.get("items")):
        raise AcceptanceError("admin-restored comment did not become publicly visible")

    suspended, raw = operator_command(
        "users", "suspend", author_user_id, "--reason", "live_acceptance"
    )
    non_inspect_outputs.append(raw)
    if suspended.get("status") != "suspended" or suspended.get("replayed") is not False:
        raise AcceptanceError("pakperk-admin user suspension did not apply")
    suspended_me = api_request("GET", WRITE_API, "/v1/me", token=author_token)
    expect_status(suspended_me, 403, "API account access after admin suspension")
    if error_code(suspended_me) != "ACCOUNT_SUSPENDED":
        raise AcceptanceError("admin suspension did not fail API account access closed")

    reinstated, raw = operator_command("users", "reinstate", author_user_id)
    non_inspect_outputs.append(raw)
    if reinstated.get("status") != "active" or reinstated.get("replayed") is not False:
        raise AcceptanceError("pakperk-admin user reinstatement did not apply")
    expect_status(
        api_request("GET", READ_ONLY_API, "/v1/me", token=author_token),
        200,
        "API account access after admin reinstatement",
    )

    resolved, raw = operator_command(
        "reports", "resolve", report_id, "--action", "dismissed"
    )
    non_inspect_outputs.append(raw)
    if resolved.get("status") != "dismissed" or resolved.get("replayed") is not False:
        raise AcceptanceError("pakperk-admin report resolution did not apply")
    if psql(
        "SELECT status FROM comment_reports WHERE id = "
        f"{sql_literal(checked_uuid(report_id))}::uuid;"
    ) != "dismissed":
        raise AcceptanceError("admin report resolution was not durable")

    resolved_user_report, raw = operator_command(
        "user-reports", "resolve", user_report_id, "--action", "dismissed"
    )
    non_inspect_outputs.append(raw)
    if (
        resolved_user_report.get("status") != "dismissed"
        or resolved_user_report.get("replayed") is not False
    ):
        raise AcceptanceError("pakperk-admin user-report resolution did not apply")
    if psql(
        "SELECT status FROM user_reports WHERE id = "
        f"{sql_literal(checked_uuid(user_report_id))}::uuid;"
    ) != "dismissed":
        raise AcceptanceError("admin user-report resolution was not durable")

    for raw_output in non_inspect_outputs:
        if UGC_SENTINEL in raw_output or '"body"' in raw_output or '"detail"' in raw_output:
            raise AcceptanceError("non-inspect pakperk-admin output serialized protected UGC")

    audit_json = psql(
        "SELECT COALESCE(json_agg(action ORDER BY created_at, id)::text, '[]') "
        "FROM comment_moderation_events WHERE actor_kind = 'admin' "
        f"AND actor_user_id = {sql_literal(checked_uuid(operator_user_id))}::uuid "
        "AND actor_label IS NULL;"
    )
    try:
        audit_actions = json.loads(audit_json)
    except json.JSONDecodeError as error:
        raise AcceptanceError("could not decode admin audit actions") from error
    required_actions = {
        "admin_hide",
        "admin_restore",
        "report_resolved",
        "user_report_resolved",
        "user_suspended",
        "user_reinstated",
    }
    if not required_actions.issubset(set(audit_actions)):
        raise AcceptanceError("admin actions did not produce the complete audit trail")
    audit_serialized = psql(
        "SELECT COALESCE(json_agg(json_build_object("
        "'action', action, 'reason_code', reason_code, 'metadata', metadata) "
        "ORDER BY created_at, id)::text, '[]') FROM comment_moderation_events "
        "WHERE actor_kind = 'admin' "
        f"AND actor_user_id = {sql_literal(checked_uuid(operator_user_id))}::uuid "
        "AND actor_label IS NULL;"
    )
    if UGC_SENTINEL in audit_serialized:
        raise AcceptanceError("admin audit rows persisted protected UGC")
    return restored_version


def run_http_matrix(
    author_token: str,
    reader_token: str,
    author_user_id: str,
    operator_user_id: str,
    paper_id: str,
    state: dict[str, Any],
) -> list[str]:
    results: list[str] = []
    comments_path = f"/v1/papers/{paper_id}/comments"
    create_request_id = str(uuid.uuid4())
    published_body = f"{UGC_SENTINEL} A bounded observation about the ablation."
    create_payload = {
        "client_request_id": create_request_id,
        "body": published_body,
    }
    created_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            comments_path,
            token=author_token,
            json_body=create_payload,
        ),
        201,
        "create published comment",
    )
    created = response_json(created_response, "create published comment").get("comment")
    if not isinstance(created, dict) or created.get("status") != "published":
        raise AcceptanceError("low-risk comment was not published")
    comment_id = checked_uuid(str(created.get("id", "")))
    record_comment(state, comment_id)
    version = created.get("version")
    if version != 1:
        raise AcceptanceError("new comment did not begin at version 1")

    replay_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            comments_path,
            token=author_token,
            json_body=create_payload,
        ),
        200,
        "exact create replay",
    )
    replayed = response_json(replay_response, "exact create replay").get("comment")
    if replayed != created:
        raise AcceptanceError("exact create replay did not return the canonical comment")
    mismatch = api_request(
        "POST",
        WRITE_API,
        comments_path,
        token=author_token,
        json_body={
            "client_request_id": create_request_id,
            "body": f"{UGC_SENTINEL} Different intent under the same request ID.",
        },
    )
    expect_status(mismatch, 409, "mismatched create replay")
    if error_code(mismatch) != "IDEMPOTENCY_CONFLICT":
        raise AcceptanceError("mismatched create replay used the wrong stable error code")
    if int(
        psql(
            "SELECT count(*) FROM paper_comments WHERE client_request_id = "
            f"{sql_literal(create_request_id)}::uuid;"
        )
    ) != 1:
        raise AcceptanceError("create idempotency persisted more than one row")
    results.append("durable exact create replay and mismatch conflict")

    edited_response = expect_status(
        api_request(
            "PATCH",
            WRITE_API,
            f"/v1/comments/{comment_id}",
            token=author_token,
            json_body={
                "body": f"{UGC_SENTINEL} The edited observation is still low risk.",
                "expected_version": version,
            },
        ),
        200,
        "edit comment",
    )
    edited = response_json(edited_response, "edit comment").get("comment")
    if not isinstance(edited, dict) or edited.get("version") != 2:
        raise AcceptanceError("comment edit did not advance the canonical version")
    stale = api_request(
        "PATCH",
        WRITE_API,
        f"/v1/comments/{comment_id}",
        token=author_token,
        json_body={
            "body": f"{UGC_SENTINEL} Stale edit must never win.",
            "expected_version": version,
        },
    )
    expect_status(stale, 409, "stale comment edit")
    if error_code(stale) != "COMMENT_EDIT_CONFLICT":
        raise AcceptanceError("stale edit used the wrong stable error code")
    results.append("optimistic edit and stale-write rejection")

    first_report_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            f"/v1/comments/{comment_id}/reports",
            token=reader_token,
            json_body={"reason": "other", "detail": "Bounded acceptance context."},
        ),
        200,
        "first comment report",
    )
    first_report = response_json(first_report_response, "first comment report").get(
        "report"
    )
    second_report_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            f"/v1/comments/{comment_id}/reports",
            token=reader_token,
            json_body={"reason": "privacy", "detail": None},
        ),
        200,
        "canonical report replay",
    )
    second_report = response_json(second_report_response, "canonical report replay").get(
        "report"
    )
    if (
        not isinstance(first_report, dict)
        or second_report != first_report
        or first_report.get("reason") != "other"
    ):
        raise AcceptanceError("report replay did not preserve its canonical first reason")
    results.append("canonical report replay despite a different replayed reason")

    first_user_report_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            f"/v1/users/{author_user_id}/reports",
            token=reader_token,
            json_body={
                "reason": "impersonation",
                "detail": "Bounded account-level acceptance context.",
            },
        ),
        200,
        "first user report",
    )
    first_user_report = response_json(
        first_user_report_response, "first user report"
    ).get("report")
    second_user_report = response_json(
        expect_status(
            api_request(
                "POST",
                READ_ONLY_API,
                f"/v1/users/{author_user_id}/reports",
                token=reader_token,
                json_body={"reason": "spam", "detail": None},
            ),
            200,
            "canonical user-report replay",
        ),
        "canonical user-report replay",
    ).get("report")
    if (
        not isinstance(first_user_report, dict)
        or second_user_report != first_user_report
        or first_user_report.get("reported_user_id") != author_user_id
        or first_user_report.get("reason") != "impersonation"
    ):
        raise AcceptanceError("user-report replay did not preserve its canonical record")
    if int(
        psql(
            "SELECT count(*) FROM user_blocks WHERE blocker_user_id = "
            f"(SELECT reporter_user_id FROM user_reports WHERE id = "
            f"{sql_literal(checked_uuid(str(first_user_report.get('id', ''))))}::uuid) "
            f"AND blocked_user_id = {sql_literal(author_user_id)}::uuid;"
        )
    ) != 0:
        raise AcceptanceError("submitting a user report unexpectedly created a block")
    results.append("canonical user report remains independent from user block")

    block_response = expect_status(
        api_request(
            "PUT",
            WRITE_API,
            f"/v1/me/blocked-users/{author_user_id}",
            token=reader_token,
        ),
        200,
        "block comment author",
    )
    blocked = response_json(block_response, "block comment author").get("blocked_user")
    if not isinstance(blocked, dict) or str(blocked.get("user", {}).get("id")) != author_user_id:
        raise AcceptanceError("block response did not identify the canonical author")
    persisted_blocks = response_json(
        expect_status(
            api_request(
                "GET", READ_ONLY_API, "/v1/me/blocked-users", token=reader_token
            ),
            200,
            "read block list from second API",
        ),
        "read block list from second API",
    )
    if author_user_id not in block_ids(persisted_blocks.get("items")):
        raise AcceptanceError("block was not durable across API processes")
    filtered = response_json(
        expect_status(
            api_request("GET", READ_ONLY_API, comments_path, token=reader_token),
            200,
            "read filtered comments from second API",
        ),
        "read filtered comments from second API",
    )
    if comment_id in comment_ids(filtered.get("items")):
        raise AcceptanceError("blocked author's comment remained visible")
    expect_status(
        api_request(
            "DELETE",
            READ_ONLY_API,
            f"/v1/me/blocked-users/{author_user_id}",
            token=reader_token,
        ),
        204,
        "unblock author on second API",
    )
    unblocked = response_json(
        expect_status(
            api_request("GET", WRITE_API, "/v1/me/blocked-users", token=reader_token),
            200,
            "read unblocked list from first API",
        ),
        "read unblocked list from first API",
    )
    if author_user_id in block_ids(unblocked.get("items")):
        raise AcceptanceError("unblock was not durable across API processes")
    visible = response_json(
        expect_status(
            api_request("GET", WRITE_API, comments_path, token=reader_token),
            200,
            "read comments after unblock",
        ),
        "read comments after unblock",
    )
    if comment_id not in comment_ids(visible.get("items")):
        raise AcceptanceError("unblocked author's published comment did not return")
    results.append("durable cross-process block/filter/unblock persistence")

    risky_request_id = str(uuid.uuid4())
    risky_response = expect_status(
        api_request(
            "POST",
            WRITE_API,
            comments_path,
            token=author_token,
            json_body={
                "client_request_id": risky_request_id,
                "body": f"{UGC_SENTINEL} home address should be exposed",
            },
        ),
        201,
        "create deterministic high-risk comment",
    )
    risky = response_json(risky_response, "create deterministic high-risk comment").get(
        "comment"
    )
    if not isinstance(risky, dict) or risky.get("status") != "pending_review":
        raise AcceptanceError("deterministic high-risk comment was not private pending review")
    risky_id = checked_uuid(str(risky.get("id", "")))
    record_comment(state, risky_id)
    guest_page = response_json(
        expect_status(
            api_request("GET", WRITE_API, comments_path),
            200,
            "guest comment list with pending item",
        ),
        "guest comment list with pending item",
    )
    if risky_id in comment_ids(guest_page.get("items")):
        raise AcceptanceError("pending-review comment leaked into the public list")
    own_page = response_json(
        expect_status(
            api_request("GET", WRITE_API, "/v1/me/comments", token=author_token),
            200,
            "author comment list",
        ),
        "author comment list",
    )
    own = {
        str(item.get("id")): item
        for item in own_page.get("items", [])
        if isinstance(item, dict)
    }
    if risky_id not in own or own[risky_id].get("status") != "pending_review":
        raise AcceptanceError("author could not see the private pending-review projection")
    results.append("deterministic high-risk content remains private pending review")

    report_id = checked_uuid(str(first_report.get("id", "")))
    user_report_id = checked_uuid(str(first_user_report.get("id", "")))
    current_version = run_admin_matrix(
        author_token,
        author_user_id,
        operator_user_id,
        comments_path,
        comment_id,
        risky_id,
        report_id,
        user_report_id,
    )
    results.append(
        "content-free admin queues, explicit inspect, hide/restore, report resolution, suspend/reinstate, and audit"
    )

    disabled_request_id = str(uuid.uuid4())
    disabled = api_request(
        "POST",
        READ_ONLY_API,
        comments_path,
        token=author_token,
        json_body={
            "client_request_id": disabled_request_id,
            "body": f"{UGC_SENTINEL} creation-disabled request",
        },
    )
    expect_status(disabled, 503, "create through COMMENT_CREATION_ENABLED=false API")
    if error_code(disabled) != "FEATURE_DISABLED":
        raise AcceptanceError("comment creation kill switch used the wrong stable error code")
    if int(
        psql(
            "SELECT count(*) FROM paper_comments WHERE client_request_id = "
            f"{sql_literal(disabled_request_id)}::uuid;"
        )
    ) != 0:
        raise AcceptanceError("creation-disabled API persisted a rejected comment")
    off_guest = response_json(
        expect_status(
            api_request("GET", READ_ONLY_API, comments_path),
            200,
            "guest comments through creation-disabled API",
        ),
        "guest comments through creation-disabled API",
    )
    if comment_id not in comment_ids(off_guest.get("items")):
        raise AcceptanceError("creation-disabled API disabled existing comment reads")
    paper = response_json(
        expect_status(
            api_request("GET", READ_ONLY_API, f"/v1/papers/{paper_id}"),
            200,
            "paper reading through creation-disabled API",
        ),
        "paper reading through creation-disabled API",
    )
    if str(paper.get("paper_id")) != paper_id:
        raise AcceptanceError("creation-disabled API did not preserve paper reading")
    replay_off = response_json(
        expect_status(
            api_request(
                "POST",
                READ_ONLY_API,
                f"/v1/comments/{comment_id}/reports",
                token=reader_token,
                json_body={"reason": "spam", "detail": None},
            ),
            200,
            "report safety route through creation-disabled API",
        ),
        "report safety route through creation-disabled API",
    ).get("report")
    if (
        not isinstance(replay_off, dict)
        or replay_off.get("id") != first_report.get("id")
        or replay_off.get("comment_id") != first_report.get("comment_id")
        or replay_off.get("reason") != first_report.get("reason")
        or replay_off.get("status") != "dismissed"
    ):
        raise AcceptanceError("creation-disabled API changed the canonical safety report")
    replay_user_report_off = response_json(
        expect_status(
            api_request(
                "POST",
                READ_ONLY_API,
                f"/v1/users/{author_user_id}/reports",
                token=reader_token,
                json_body={"reason": "privacy", "detail": None},
            ),
            200,
            "user-report safety route through creation-disabled API",
        ),
        "user-report safety route through creation-disabled API",
    ).get("report")
    if (
        not isinstance(replay_user_report_off, dict)
        or replay_user_report_off.get("id") != user_report_id
        or replay_user_report_off.get("reported_user_id") != author_user_id
        or replay_user_report_off.get("reason") != first_user_report.get("reason")
        or replay_user_report_off.get("status") != "dismissed"
    ):
        raise AcceptanceError(
            "creation-disabled API changed the canonical user-report safety record"
        )
    expect_status(
        api_request(
            "PUT",
            READ_ONLY_API,
            f"/v1/me/blocked-users/{author_user_id}",
            token=reader_token,
        ),
        200,
        "block safety route through creation-disabled API",
    )
    expect_status(
        api_request(
            "DELETE",
            READ_ONLY_API,
            f"/v1/me/blocked-users/{author_user_id}",
            token=reader_token,
        ),
        204,
        "unblock safety route through creation-disabled API",
    )
    off_edit = response_json(
        expect_status(
            api_request(
                "PATCH",
                READ_ONLY_API,
                f"/v1/comments/{comment_id}",
                token=author_token,
                json_body={
                    "body": f"{UGC_SENTINEL} Author edit while new creation is disabled.",
                    "expected_version": current_version,
                },
            ),
            200,
            "author edit through creation-disabled API",
        ),
        "author edit through creation-disabled API",
    ).get("comment")
    if (
        not isinstance(off_edit, dict)
        or off_edit.get("version") != current_version + 1
    ):
        raise AcceptanceError("creation-disabled API did not preserve author editing")
    expect_status(
        api_request(
            "DELETE",
            READ_ONLY_API,
            f"/v1/comments/{comment_id}",
            token=author_token,
        ),
        204,
        "author delete through creation-disabled API",
    )
    expect_status(
        api_request(
            "DELETE",
            READ_ONLY_API,
            f"/v1/comments/{comment_id}",
            token=author_token,
        ),
        204,
        "repeat author delete through creation-disabled API",
    )
    results.append(
        "creation kill switch disables only create; reads, safety, edit/delete, and paper reading remain"
    )

    unavailable_auth = api_request(
        "GET", UNAVAILABLE_API, "/v1/me", token=author_token
    )
    expect_status(unavailable_auth, 503, "authenticated route with unavailable Keycloak")
    if error_code(unavailable_auth) != "AUTHENTICATION_UNAVAILABLE":
        raise AcceptanceError("unavailable issuer did not fail authenticated access closed")
    unavailable_guest = response_json(
        expect_status(
            api_request("GET", UNAVAILABLE_API, comments_path),
            200,
            "guest comment GET with unavailable Keycloak",
        ),
        "guest comment GET with unavailable Keycloak",
    )
    if risky_id in comment_ids(unavailable_guest.get("items")):
        raise AcceptanceError("unavailable-auth guest read exposed pending-review content")
    expect_status(
        api_request("GET", UNAVAILABLE_API, f"/v1/papers/{paper_id}"),
        200,
        "guest paper GET with unavailable Keycloak",
    )
    results.append("guest comment/paper GET survives unavailable Keycloak while auth fails closed")
    return results


def audit_logs(tokens: list[str]) -> None:
    forbidden: list[tuple[str, str]] = [
        (UGC_SENTINEL, "UGC sentinel"),
        (TOKEN_SENTINEL, "token-header sentinel"),
    ]
    for token in tokens:
        forbidden.append((token, "complete bearer token"))
        forbidden.append((token[-32:], "bearer-token signature fingerprint"))
    for path in API_LOGS:
        try:
            captured = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            raise AcceptanceError(f"could not inspect captured API log {path.name}") from error
        for value, label in forbidden:
            if value and value in captured:
                raise AcceptanceError(f"captured API log {path.name} contains a {label}")


def cleanup_database(state: dict[str, Any]) -> None:
    paper_id = state.get("paper_id")
    local_user_ids = [checked_uuid(value) for value in state.get("local_user_ids", [])]
    if paper_id is not None:
        paper_id = checked_uuid(paper_id)
    user_values = ", ".join(f"{sql_literal(value)}::uuid" for value in local_user_ids)
    user_predicate = f"IN ({user_values})" if user_values else "IN (NULL::uuid)"

    origin_scope = state.get("origin_scope")
    rate_predicates: list[str] = []
    for user_id in local_user_ids:
        rate_predicates.append(f"scope_key = {sql_literal(f'user:{user_id}')}")
    if isinstance(origin_scope, str) and origin_scope:
        rate_predicates.append(f"scope_key = {sql_literal(origin_scope)}")
    explicit_comments = [checked_uuid(value) for value in state.get("comment_ids", [])]
    for comment_id in explicit_comments:
        rate_predicates.append(f"scope_key = {sql_literal(f'comment:{comment_id}')}")
    if paper_id is not None:
        rate_predicates.append(
            "scope_key IN (SELECT 'comment:' || id::text FROM paper_comments "
            f"WHERE paper_id = {sql_literal(paper_id)}::uuid)"
        )
    rate_where = " OR ".join(rate_predicates) or "false"
    paper_comment_predicate = (
        f"paper_id = {sql_literal(paper_id)}::uuid" if paper_id is not None else "false"
    )
    psql(
        f"""
        BEGIN;
        DELETE FROM shared_rate_limit_buckets WHERE {rate_where};
        DELETE FROM comment_moderation_events
        WHERE comment_id IN (
            SELECT id FROM paper_comments
            WHERE {paper_comment_predicate} OR author_user_id {user_predicate}
        ) OR target_user_id {user_predicate};
        DELETE FROM users WHERE id {user_predicate};
        {f"DELETE FROM papers WHERE id = {sql_literal(paper_id)}::uuid;" if paper_id is not None else ""}
        COMMIT;
        """
    )
    if local_user_ids:
        remaining = int(
            psql(f"SELECT count(*) FROM users WHERE id {user_predicate};") or "0"
        )
        if remaining != 0:
            raise AcceptanceError("disposable local API users were not removed")
    if paper_id is not None:
        remaining = int(
            psql(
                "SELECT count(*) FROM papers WHERE id = "
                f"{sql_literal(paper_id)}::uuid;"
            )
            or "0"
        )
        if remaining != 0:
            raise AcceptanceError("disposable paper/comment data was not removed")


def cleanup_keycloak(state: dict[str, Any]) -> None:
    user_ids = [checked_uuid(value) for value in state.get("keycloak_user_ids", [])]
    if not user_ids:
        return
    token = admin_access_token()
    headers = {"Authorization": f"Bearer {token}"}
    for user_id in user_ids:
        response = LOCAL_HTTP.delete(
            f"{ADMIN_REALM_URL}/users/{user_id}", headers=headers, timeout=15
        )
        expect_status(response, (204, 404), "delete disposable Keycloak user")
    for user_id in user_ids:
        response = LOCAL_HTTP.get(
            f"{ADMIN_REALM_URL}/users/{user_id}", headers=headers, timeout=15
        )
        expect_status(response, 404, "verify disposable Keycloak user removal")


def cleanup_state(state: dict[str, Any]) -> None:
    cleanup_database(state)
    cleanup_keycloak(state)
    state["cleaned"] = True
    save_state(state)


def new_state() -> dict[str, Any]:
    secret = COMMENT_SECRET_FILE.read_text(encoding="utf-8").rstrip("\r\n")
    message = (
        b"pakperk:comment-origin:v1\0"
        + bytes([4])
        + ipaddress.ip_address("127.0.0.1").packed
    )
    origin_scope = hmac.new(
        secret.encode("utf-8"), message, hashlib.sha256
    ).hexdigest()
    state: dict[str, Any] = {
        "schema_version": 1,
        "run_id": RUN_ID,
        "keycloak_user_ids": [],
        "local_user_ids": [],
        "comment_ids": [],
        "paper_id": None,
        "origin_scope": origin_scope,
        "cleaned": False,
    }
    save_state(state)
    return state


def run_acceptance() -> None:
    state = new_state()
    try:
        discovery = LOCAL_HTTP.get(
            f"{ISSUER}/.well-known/openid-configuration", timeout=15
        )
        expect_status(discovery, 200, "Keycloak realm discovery")
        paper_id = seed_paper(state)
        before_preparation = preparation_snapshot(paper_id)

        usernames = [
            f"lc_{RUN_ID[:12]}_a",
            f"lc_{RUN_ID[:12]}_b",
            f"lc_{RUN_ID[:12]}_operator",
        ]
        passwords = [secrets.token_urlsafe(32) + "Aa1!" for _ in usernames]
        keycloak_ids = [
            create_keycloak_user(username, password, state)
            for username, password in zip(usernames, passwords, strict=True)
        ]
        tokens = [
            authorization_code_pkce(username, password, user_id)
            for username, password, user_id in zip(
                usernames, passwords, keycloak_ids, strict=True
            )
        ]
        assert_user_direct_grant_disabled(usernames[0], passwords[0])
        print("PASS three disposable users authenticated only through Authorization Code + PKCE")

        local_ids = [
            onboard(token, f"lc{RUN_ID[:10]}{suffix}", state)
            for token, suffix in zip(tokens, ("a", "b", "o"), strict=True)
        ]
        if len(set(local_ids)) != len(local_ids):
            raise AcceptanceError("distinct OIDC subjects resolved to the same local account")
        print("PASS handle, Terms, and Community Guidelines onboarding for all users")

        # Keep the bearer token out of argv, shell history, logs, and persisted
        # harness state. A dedicated third account is the operator so moderation
        # never grants privileged authority to the author or reporting reader,
        # and suspending the author cannot lock out later CLI invocations.
        assert_unallowlisted_admin_fails(tokens[1], local_ids[2])
        print("PASS valid non-allowlisted identity failed admin authorization closed")
        write_private_access_token(ADMIN_ACCESS_TOKEN_FILE, tokens[2])
        print("PASS provisioned operator token installed in an owner-only file")

        for result in run_http_matrix(
            tokens[0], tokens[1], local_ids[0], local_ids[2], paper_id, state
        ):
            print(f"PASS {result}")

        after_preparation = preparation_snapshot(paper_id)
        if after_preparation != before_preparation:
            raise AcceptanceError("comment actions changed paper preparation or job state")
        print("PASS comment actions made no paper_processing or jobs changes")

        if int(
            psql(
                "SELECT count(*) FROM user_blocks WHERE blocker_user_id = "
                f"{sql_literal(local_ids[1])}::uuid AND blocked_user_id = "
                f"{sql_literal(local_ids[0])}::uuid;"
            )
        ) != 0:
            raise AcceptanceError("final unblock did not persist")
        audit_logs(tokens)
        print("PASS captured API logs contain no UGC, token-header, or bearer-token sentinel")
    except Exception:
        try:
            cleanup_state(state)
        except Exception as cleanup_error:  # noqa: BLE001 - preserve primary failure.
            print(
                f"WARNING cleanup also failed: {type(cleanup_error).__name__}",
                file=sys.stderr,
            )
        raise
    else:
        cleanup_state(state)
        print("PASS disposable Keycloak users, local users, comments, and paper were removed")


def cleanup_only() -> None:
    state = load_state()
    if state is not None:
        cleanup_state(state)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "cleanup"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "run":
            run_acceptance()
        else:
            cleanup_only()
    except AcceptanceError as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    except requests.RequestException:
        print("FAIL an external HTTP dependency became unavailable", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - bounded type-only diagnostic.
        print(f"FAIL unexpected {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
