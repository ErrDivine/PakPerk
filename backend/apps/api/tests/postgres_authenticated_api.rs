use std::{
    fs,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use account_deletion::{AccountDeletionPolicy, DeletionLedgerSigner, ProviderIdentityCipher};
use accounts::IdentityFingerprintKeyring;
use arxiv_client::ArxivClientConfig;
use auth::{AuthRuntimeStatus, OidcAlgorithm, OidcVerifierConfig};
use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{
        HeaderValue, Method, Request, StatusCode,
        header::{
            ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS,
            ACCESS_CONTROL_ALLOW_ORIGIN, ACCESS_CONTROL_REQUEST_HEADERS,
            ACCESS_CONTROL_REQUEST_METHOD, AUTHORIZATION, CONTENT_TYPE, ETAG, IF_MATCH, ORIGIN,
            WWW_AUTHENTICATE,
        },
    },
    response::Response,
    routing::get,
};
use chrono::{TimeDelta, Utc};
use db::Database;
use domain::{
    ArxivIdentifier, Author, CommunityGuidelinesVersion, FulltextPolicy, PaperMetadata,
    TermsVersion,
};
use jsonwebtoken::{Algorithm, EncodingKey, Header as JwtHeader, encode};
use pakperk_api::{
    AccountDeletionFeatureConfig, AccountFeatureConfig, ApiConfig, ApiEnvironment, AppState,
    CommentFeatureConfig, FeatureFlags, LibraryFeatureConfig, RequestOriginConfig, build_router,
    initialize_auth_runtime,
};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};
use tower::ServiceExt as _;
use url::Url;
use uuid::Uuid;

const AUDIENCE: &str = "pakperk-api";
const KEY_ID: &str = "integration-current";
const PUBLIC_ED25519_X: &str = "2-Jj2UvNCvQiUPNYRgSi0cJSPiJI6Rs6D0UTeEpQVj8";
const IDENTITY_KEY: &str = "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=";

// RFC 8410 PKCS#8 Ed25519 fixture. It is test-only and has no deployment use.
const PRIVATE_ED25519_KEY: &[u8] = &[
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    0x6a, 0xc3, 0xfd, 0xee, 0xee, 0x29, 0x8a, 0x92, 0x63, 0x8b, 0x70, 0x0c, 0x4b, 0x11, 0x7c, 0xc3,
    0x2e, 0x2d, 0x2a, 0xce, 0x0d, 0xfd, 0x78, 0x76, 0x94, 0xe2, 0x4c, 0xae, 0x8a, 0xd5, 0x82, 0x34,
];

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_oidc_routes_enforce_auth_consent_mutations_flags_cors_and_recent_replay() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped authenticated PostgreSQL API coverage");
        return;
    };
    let database = Database::connect(&database_url, 16).await.unwrap();
    database.migrate_embedded().await.unwrap();
    database.ready().await.unwrap();

    let oidc = DeterministicOidcServer::start().await;
    let unique = Uuid::now_v7().simple().to_string();
    let subject = format!("api-subject-{unique}");
    let expired_subject = format!("expired-subject-{unique}");
    let ledger_directory = owner_only_tempdir();
    let config = api_config(
        database_url,
        oidc.verifier_config(),
        ledger_directory.path(),
        &unique,
    );
    let auth = initialize_auth_runtime(config.accounts.as_ref()).await;
    assert_eq!(auth.status(), AuthRuntimeStatus::Ready);
    assert_eq!(oidc.discovery_calls.load(Ordering::SeqCst), 1);
    assert_eq!(oidc.jwks_calls.load(Ordering::SeqCst), 1);

    // Build independent router/service state over one PostgreSQL source of
    // truth to catch wiring that only works inside one in-memory instance.
    let first = build_router(
        AppState::new_with_auth(database.clone(), &config, auth.clone()).unwrap(),
        &config,
    );
    let second = build_router(
        AppState::new_with_auth(database.clone(), &config, auth.clone()).unwrap(),
        &config,
    );
    let now = Utc::now().timestamp();
    let recent_token = token(&oidc.issuer, &subject, now + 600, now - 30);
    let stale_auth_token = token(&oidc.issuer, &subject, now + 600, now - 600);
    let expired_token = token(&oidc.issuer, &expired_subject, now - 120, now - 600);

    let missing = first
        .clone()
        .oneshot(Request::get("/v1/me").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(missing.headers()[WWW_AUTHENTICATE], "Bearer");
    assert_eq!(
        response_json(missing).await["error"]["code"],
        "UNAUTHENTICATED"
    );

    // Expiration is rejected by the real signature/claims verifier before JIT.
    let expired = first
        .clone()
        .oneshot(authorized_get("/v1/me", &expired_token))
        .await
        .unwrap();
    assert_eq!(expired.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(expired.headers()[WWW_AUTHENTICATE], "Bearer");
    assert_eq!(
        response_json(expired).await["error"]["code"],
        "TOKEN_EXPIRED"
    );
    let expired_identity_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM users WHERE oidc_issuer = $1 AND oidc_subject = $2",
    )
    .bind(oidc.issuer.as_str())
    .bind(&expired_subject)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(expired_identity_count, 0);

    let me = first
        .clone()
        .oneshot(authorized_get("/v1/me", &recent_token))
        .await
        .unwrap();
    assert_eq!(me.status(), StatusCode::OK);
    let profile_etag = me.headers()[ETAG].clone();
    let me = response_json(me).await;
    let user_id = Uuid::parse_str(me["account"]["id"].as_str().unwrap()).unwrap();
    assert_eq!(me["account"]["profile_complete"], false);
    assert!(!me.to_string().contains(&subject));
    let same_me = second
        .clone()
        .oneshot(authorized_get("/v1/me", &recent_token))
        .await
        .unwrap();
    assert_eq!(same_me.status(), StatusCode::OK);
    assert_eq!(
        response_json(same_me).await["account"]["id"],
        user_id.to_string()
    );
    let identity_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM users WHERE oidc_issuer = $1 AND oidc_subject = $2",
    )
    .bind(oidc.issuer.as_str())
    .bind(&subject)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(identity_count, 1);

    let handle = format!("reader_{}", &unique[..12]);
    let profile = first
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::PATCH)
                .uri("/v1/me")
                .header(AUTHORIZATION, bearer(&recent_token))
                .header(CONTENT_TYPE, "application/json")
                .header(IF_MATCH, profile_etag)
                .body(Body::from(
                    json!({
                        "handle": handle,
                        "display_name": "API Reader",
                        "accept_terms_version": "2026-08-01",
                        "accept_community_guidelines_version": "2026-08-01"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(profile.status(), StatusCode::OK);
    let profile = response_json(profile).await;
    assert_eq!(profile["account"]["handle"], handle);
    assert_eq!(profile["account"]["terms_current"], true);
    assert_eq!(profile["account"]["community_guidelines_current"], true);
    assert_eq!(profile["account"]["comment_profile_complete"], true);

    let paper = database
        .papers()
        .upsert_metadata(&metadata(&unique))
        .await
        .unwrap();
    let library_operation = Uuid::now_v7();
    let saved = first
        .clone()
        .oneshot(
            Request::put(format!("/v1/me/library/{}", paper.id))
                .header(AUTHORIZATION, bearer(&recent_token))
                .header(CONTENT_TYPE, "application/json")
                .header("idempotency-key", library_operation.to_string())
                .body(Body::from(
                    json!({"operation_id": library_operation, "state": "to_read"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(saved.status(), StatusCode::OK);
    let saved = response_json(saved).await;
    assert_eq!(saved["item"]["paper_id"], paper.id.to_string());
    assert_eq!(
        saved["item"]["last_operation_id"],
        library_operation.to_string()
    );

    let library = second
        .clone()
        .oneshot(authorized_get(
            "/v1/me/library?state=to_read&limit=10",
            &recent_token,
        ))
        .await
        .unwrap();
    assert_eq!(library.status(), StatusCode::OK);
    let library = response_json(library).await;
    assert_eq!(library["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        library["items"][0]["item"]["paper_id"],
        paper.id.to_string()
    );

    let comment_request_id = Uuid::now_v7();
    let comment = first
        .clone()
        .oneshot(comment_request(
            paper.id,
            &recent_token,
            comment_request_id,
            "The evaluation setup makes the comparison especially clear.",
        ))
        .await
        .unwrap();
    assert_eq!(comment.status(), StatusCode::CREATED);
    let comment = response_json(comment).await;
    let comment_id = Uuid::parse_str(comment["comment"]["id"].as_str().unwrap()).unwrap();
    assert_eq!(comment["comment"]["status"], "published");
    assert_eq!(comment["comment"]["author"]["id"], user_id.to_string());

    let public_comments = second
        .clone()
        .oneshot(
            Request::get(format!("/v1/papers/{}/comments?limit=10", paper.id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(public_comments.status(), StatusCode::OK);
    assert_eq!(
        response_json(public_comments).await["items"][0]["id"],
        comment_id.to_string()
    );

    let mut creation_disabled_config = config.clone();
    creation_disabled_config.features.comment_creation = false;
    let creation_disabled = build_router(
        AppState::new_with_auth(database.clone(), &creation_disabled_config, auth.clone()).unwrap(),
        &creation_disabled_config,
    );
    let denied_comment = creation_disabled
        .clone()
        .oneshot(comment_request(
            paper.id,
            &recent_token,
            Uuid::now_v7(),
            "This request must be stopped by the publication kill switch.",
        ))
        .await
        .unwrap();
    assert_eq!(denied_comment.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        response_json(denied_comment).await["error"]["code"],
        "FEATURE_DISABLED"
    );
    let still_readable = creation_disabled
        .clone()
        .oneshot(
            Request::get(format!("/v1/papers/{}/comments?limit=10", paper.id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(still_readable.status(), StatusCode::OK);

    let preflight = first
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::OPTIONS)
                .uri("/v1/me")
                .header(ORIGIN, "https://reader.example")
                .header(ACCESS_CONTROL_REQUEST_METHOD, "PATCH")
                .header(
                    ACCESS_CONTROL_REQUEST_HEADERS,
                    "authorization,content-type,if-match",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(preflight.status().is_success());
    assert_eq!(
        preflight.headers()[ACCESS_CONTROL_ALLOW_ORIGIN],
        "https://reader.example"
    );
    assert!(
        preflight.headers()[ACCESS_CONTROL_ALLOW_METHODS]
            .to_str()
            .unwrap()
            .contains("PATCH")
    );
    let allowed_headers = preflight.headers()[ACCESS_CONTROL_ALLOW_HEADERS]
        .to_str()
        .unwrap()
        .to_ascii_lowercase();
    assert!(allowed_headers.contains("authorization"));
    assert!(allowed_headers.contains("if-match"));
    assert!(
        !preflight
            .headers()
            .contains_key("access-control-allow-credentials")
    );

    // A stale-but-unexpired token cannot begin deletion.
    let stale_initial = first
        .clone()
        .oneshot(delete_request(&stale_auth_token))
        .await
        .unwrap();
    assert_eq!(stale_initial.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        response_json(stale_initial).await["error"]["code"],
        "REAUTHENTICATION_REQUIRED"
    );
    let status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(status, "active");

    let deletion = first
        .clone()
        .oneshot(delete_request(&recent_token))
        .await
        .unwrap();
    assert_eq!(deletion.status(), StatusCode::ACCEPTED);
    let deletion = response_json(deletion).await;
    let operation_id =
        Uuid::parse_str(deletion["deletion"]["operation_id"].as_str().unwrap()).unwrap();

    let recent_replay = second
        .clone()
        .oneshot(delete_request(&recent_token))
        .await
        .unwrap();
    assert_eq!(recent_replay.status(), StatusCode::ACCEPTED);
    assert_eq!(
        response_json(recent_replay).await["deletion"]["operation_id"],
        operation_id.to_string()
    );

    // Regression: the durable operation must not turn replay into a bypass of
    // DELETE /v1/me's recent-auth contract.
    let stale_replay = second
        .oneshot(delete_request(&stale_auth_token))
        .await
        .unwrap();
    assert_eq!(stale_replay.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        response_json(stale_replay).await["error"]["code"],
        "REAUTHENTICATION_REQUIRED"
    );

    cleanup_fixture(&database, user_id, paper.id, comment_id, operation_id).await;
}

struct DeterministicOidcServer {
    issuer: Url,
    discovery_calls: Arc<AtomicUsize>,
    jwks_calls: Arc<AtomicUsize>,
    task: JoinHandle<()>,
}

impl DeterministicOidcServer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let issuer = Url::parse(&format!("http://{address}/realms/pakperk")).unwrap();
        let discovery = json!({
            "issuer": issuer.as_str(),
            "jwks_uri": format!("{issuer}/jwks")
        });
        let jwks = json!({
            "keys": [{
                "kty": "OKP",
                "use": "sig",
                "crv": "Ed25519",
                "x": PUBLIC_ED25519_X,
                "kid": KEY_ID,
                "alg": "EdDSA"
            }]
        });
        let discovery_calls = Arc::new(AtomicUsize::new(0));
        let jwks_calls = Arc::new(AtomicUsize::new(0));
        let discovery_route_calls = Arc::clone(&discovery_calls);
        let jwks_route_calls = Arc::clone(&jwks_calls);
        let app = Router::new()
            .route(
                "/realms/pakperk/.well-known/openid-configuration",
                get(move || {
                    let body = discovery.clone();
                    let calls = Arc::clone(&discovery_route_calls);
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Json(body)
                    }
                }),
            )
            .route(
                "/realms/pakperk/jwks",
                get(move || {
                    let body = jwks.clone();
                    let calls = Arc::clone(&jwks_route_calls);
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Json(body)
                    }
                }),
            );
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            issuer,
            discovery_calls,
            jwks_calls,
            task,
        }
    }

    fn verifier_config(&self) -> OidcVerifierConfig {
        let mut config =
            OidcVerifierConfig::new(self.issuer.clone(), AUDIENCE, vec![OidcAlgorithm::EdDsa]);
        config.allow_insecure_http = true;
        config.clock_skew = Duration::ZERO;
        config.discovery_timeout = Duration::from_secs(2);
        config
    }
}

impl Drop for DeterministicOidcServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn api_config(
    database_url: String,
    oidc: OidcVerifierConfig,
    ledger_directory: &std::path::Path,
    unique: &str,
) -> ApiConfig {
    let identity_fingerprints =
        IdentityFingerprintKeyring::parse(&format!("identity_1:{IDENTITY_KEY}")).unwrap();
    let account = AccountFeatureConfig {
        oidc,
        current_terms_version: TermsVersion::parse("2026-08-01").unwrap(),
        current_community_guidelines_version: CommunityGuidelinesVersion::parse("2026-08-01")
            .unwrap(),
        last_seen_interval: Duration::from_secs(15 * 60),
        profile_update_limit: 10,
        profile_update_window: Duration::from_secs(60 * 60),
        auth_retry_initial: Duration::from_secs(1),
        auth_retry_maximum: Duration::from_secs(10),
        identity_fingerprints: Some(identity_fingerprints.clone()),
    };
    let deletion = AccountDeletionFeatureConfig {
        identity_fingerprints,
        external_ledger_directory: ledger_directory.to_path_buf(),
        signer: DeletionLedgerSigner::new("development", "signing_1", vec![0x62; 32]).unwrap(),
        provider_identity_cipher: ProviderIdentityCipher::new("provider_1", vec![0x73; 32])
            .unwrap(),
        policy: AccountDeletionPolicy::new(
            Duration::from_secs(300),
            2,
            Duration::from_secs(60 * 60),
            4,
            Duration::from_secs(24 * 60 * 60),
            Duration::from_secs(3 * 24 * 60 * 60),
            Duration::from_secs(24 * 60 * 60),
        )
        .unwrap(),
    };
    ApiConfig {
        environment: ApiEnvironment::Development,
        features: FeatureFlags {
            accounts: true,
            library: true,
            library_writes: true,
            comments: true,
            comment_creation: true,
            account_deletion: true,
        },
        accounts: Some(account),
        library: Some(LibraryFeatureConfig {
            mutation_limit: 100,
            mutation_window: Duration::from_secs(60 * 60),
        }),
        comments: Some(CommentFeatureConfig::for_test().unwrap()),
        account_deletion: Some(deletion),
        request_origin: RequestOriginConfig::for_local_development(&format!(
            "authenticated-api-origin-{unique}-strong-secret"
        ))
        .unwrap(),
        bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        database_url,
        database_pool_size: 16,
        run_migrations: false,
        request_timeout: Duration::from_secs(5),
        chat_request_timeout: Duration::from_secs(5),
        max_request_bytes: 64 * 1024,
        cors_allowed_origins: vec![HeaderValue::from_static("https://reader.example")],
        arxiv: ArxivClientConfig {
            contact_email: "integration@pakperk.dev".to_owned(),
            max_retries: 0,
            ..ArxivClientConfig::default()
        },
        arxiv_cache_ttl: Duration::from_secs(60),
        fulltext_policy: FulltextPolicy::Prototype,
        embedding_dimension: None,
        llm: None,
        prepare_requests_per_minute: 100,
        chat_requests_per_minute: 100,
    }
}

fn token(issuer: &Url, subject: &str, expires_at: i64, auth_time: i64) -> String {
    let now = Utc::now().timestamp();
    let claims = json!({
        "iss": issuer.as_str(),
        "sub": subject,
        "aud": AUDIENCE,
        "exp": expires_at,
        "nbf": now - 60,
        "iat": now - 60,
        "auth_time": auth_time
    });
    let mut header = JwtHeader::new(Algorithm::EdDSA);
    header.kid = Some(KEY_ID.to_owned());
    encode(
        &header,
        &claims,
        &EncodingKey::from_ed_der(PRIVATE_ED25519_KEY),
    )
    .unwrap()
}

fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

fn authorized_get(uri: &str, token: &str) -> Request<Body> {
    Request::get(uri)
        .header(AUTHORIZATION, bearer(token))
        .body(Body::empty())
        .unwrap()
}

fn comment_request(
    paper_id: Uuid,
    token: &str,
    client_request_id: Uuid,
    body: &str,
) -> Request<Body> {
    let mut request = Request::post(format!("/v1/papers/{paper_id}/comments"))
        .header(AUTHORIZATION, bearer(token))
        .header(CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"client_request_id": client_request_id, "body": body}).to_string(),
        ))
        .unwrap();
    request.extensions_mut().insert(ConnectInfo(SocketAddr::new(
        IpAddr::V4(Ipv4Addr::new(198, 51, 100, 42)),
        41_234,
    )));
    request
}

fn delete_request(token: &str) -> Request<Body> {
    Request::delete("/v1/me")
        .header(AUTHORIZATION, bearer(token))
        .body(Body::empty())
        .unwrap()
}

fn owner_only_tempdir() -> TempDir {
    let directory = tempfile::tempdir().unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    }
    directory
}

fn metadata(unique: &str) -> PaperMetadata {
    let now = Utc::now();
    let base_id = format!("test.authenticated.api.{unique}");
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.clone(),
            version: 1,
        },
        title: "Authenticated API integration fixture".to_owned(),
        abstract_text: "A metadata-only fixture for authenticated route coverage.".to_owned(),
        authors: vec![Author {
            name: "Ada Tester".to_owned(),
        }],
        primary_category: "cs.SE".to_owned(),
        categories: vec!["cs.SE".to_owned()],
        published_at: now - TimeDelta::days(1),
        updated_at: now,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: now,
    }
}

async fn cleanup_fixture(
    database: &Database,
    user_id: Uuid,
    paper_id: Uuid,
    comment_id: Uuid,
    operation_id: Uuid,
) {
    sqlx::query("DELETE FROM comment_moderation_events WHERE comment_id = $1")
        .bind(comment_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_events WHERE operation_id = $1")
        .bind(operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = $1")
        .bind(operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = $1")
        .bind(operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM shared_rate_limit_buckets WHERE scope_key = $1")
        .bind(format!("user:{user_id}"))
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper_id)
        .execute(database.pool())
        .await
        .unwrap();
}

async fn response_json(response: Response) -> Value {
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
