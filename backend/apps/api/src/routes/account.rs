use accounts::{AccountServiceError, PatchValue, ProfileUpdateCommand};
use axum::{
    Extension, Json,
    extract::{Request, State},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{CACHE_CONTROL, ETAG, IF_MATCH},
    },
    middleware::Next,
    response::{IntoResponse, Response},
};

use crate::{
    AppState,
    dto::{AccountProfileEnvelope, ProfilePatchField, ProfileUpdateBody},
    error::{ApiError, RequestId, account_service_error, profile_entity_tag},
    middleware::AuthenticatedPrincipal,
};

const ACCOUNT_CACHE_CONTROL: &str = "private, no-store";
const MAX_IF_MATCH_BYTES: usize = 64;

pub(crate) async fn private_account_cache_control(request: Request, next: Next) -> Response {
    let path = request.uri().path();
    let is_private_account_route = path == "/v1/me" || path.starts_with("/v1/me/");
    let mut response = next.run(request).await;
    if is_private_account_route {
        response.headers_mut().insert(
            CACHE_CONTROL,
            HeaderValue::from_static(ACCOUNT_CACHE_CONTROL),
        );
    }
    response
}

#[utoipa::path(
    get,
    path = "/v1/me",
    tag = "accounts",
    description = "Registered only when ACCOUNTS_ENABLED=true; the route is absent when the account feature is disabled.",
    security(("oidcBearer" = [])),
    responses(
        (
            status = 200,
            description = "Current account profile and terms state",
            body = AccountProfileEnvelope,
            headers(
                ("ETag" = String, description = "Strong profile validator in the form quoted profile-N"),
                ("Cache-Control" = String, description = "Always private, no-store")
            ),
            example = json!({
                "account": {
                    "id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
                    "handle": "ada_reader",
                    "display_name": "Ada Reader",
                    "status": "active",
                    "profile_version": 2,
                    "profile_complete": true,
                    "terms_version": "2026-07-31",
                    "terms_accepted_at": "2026-07-31T12:00:00.000Z",
                    "current_terms_version": "2026-07-31",
                    "terms_current": true,
                    "created_at": "2026-07-31T11:00:00.000Z",
                    "updated_at": "2026-07-31T12:00:00.000Z"
                }
            })
        ),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or ACCOUNT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn get_me(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<Response, ApiError> {
    let service = account_service(&state, request_id)?;
    let user = service
        .get_profile(principal.user_id)
        .await
        .map_err(|error| account_service_error(request_id, &error))?;
    account_response(&state, request_id, &user)
}

#[utoipa::path(
    patch,
    path = "/v1/me",
    tag = "accounts",
    description = "Registered only when ACCOUNTS_ENABLED=true; the route is absent when the account feature is disabled. Updates use an exact strong profile ETag for compare-and-swap.",
    security(("oidcBearer" = [])),
    params(
        ("If-Match" = String, Header, description = "Required exact strong profile validator returned by GET /v1/me", example = "\"profile-2\"")
    ),
    request_body(
        content = ProfileUpdateBody,
        description = "Supported profile fields; explicit null clears only display_name",
        example = json!({"handle": "ada_reader", "display_name": "Ada Reader", "accept_terms_version": "2026-07-31"})
    ),
    responses(
        (
            status = 200,
            description = "Updated account profile",
            body = AccountProfileEnvelope,
            headers(
                ("ETag" = String, description = "New strong profile validator"),
                ("Cache-Control" = String, description = "Always private, no-store")
            )
        ),
        (status = 400, description = "INVALID_REQUEST, INVALID_PROFILE_VERSION, INVALID_PROFILE_UPDATE, INVALID_HANDLE, INVALID_DISPLAY_NAME, INVALID_TERMS_VERSION, or TERMS_VERSION_MISMATCH", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "HANDLE_ALREADY_SET or HANDLE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "PROFILE_VERSION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema, headers(("ETag" = String, description = "Current strong profile validator"))),
        (status = 428, description = "PROFILE_VERSION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or ACCOUNT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn patch_me(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<ProfileUpdateBody>,
) -> Result<Response, ApiError> {
    let expected_profile_version = expected_profile_version(&headers, request_id)?;
    let handle = match body.handle {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Value(value) => Some(value),
        ProfilePatchField::Null => {
            return Err(ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_HANDLE",
                "The account handle cannot be null.",
                false,
            ));
        }
    };
    let display_name = match body.display_name {
        ProfilePatchField::Omitted => PatchValue::Omitted,
        ProfilePatchField::Null => PatchValue::Null,
        ProfilePatchField::Value(value) => PatchValue::Value(value),
    };
    let accept_terms_version = match body.accept_terms_version {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Value(value) => Some(value),
        ProfilePatchField::Null => {
            return Err(ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_TERMS_VERSION",
                "The accepted terms version cannot be null.",
                false,
            ));
        }
    };
    let service = account_service(&state, request_id)?;
    let user = service
        .update_profile(
            principal.user_id,
            ProfileUpdateCommand {
                expected_profile_version,
                handle,
                display_name,
                accept_terms_version,
            },
        )
        .await
        .map_err(|error| account_service_error(request_id, &error))?;
    account_response(&state, request_id, &user)
}

fn account_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&accounts::AccountService, ApiError> {
    state.accounts.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Account features are disabled.",
            false,
        )
    })
}

fn account_response(
    state: &AppState,
    request_id: RequestId,
    user: &domain::User,
) -> Result<Response, ApiError> {
    let service = account_service(state, request_id)?;
    let entity_tag = profile_entity_tag(user.profile_version).ok_or_else(|| {
        account_service_error(request_id, &AccountServiceError::InvalidProfileVersion)
    })?;
    let mut response = Json(AccountProfileEnvelope::new(
        user,
        service.policy().current_terms_version(),
    ))
    .into_response();
    response.headers_mut().insert(ETAG, entity_tag);
    response.headers_mut().insert(
        CACHE_CONTROL,
        HeaderValue::from_static(ACCOUNT_CACHE_CONTROL),
    );
    Ok(response)
}

fn expected_profile_version(headers: &HeaderMap, request_id: RequestId) -> Result<i64, ApiError> {
    let mut values = headers.get_all(IF_MATCH).iter();
    let Some(value) = values.next() else {
        return Err(ApiError::new(
            request_id,
            StatusCode::PRECONDITION_REQUIRED,
            "PROFILE_VERSION_REQUIRED",
            "If-Match with the current profile ETag is required.",
            false,
        ));
    };
    if values.next().is_some() {
        return Err(invalid_profile_version(request_id));
    }
    let raw = value
        .to_str()
        .map_err(|_| invalid_profile_version(request_id))?;
    if raw.len() > MAX_IF_MATCH_BYTES {
        return Err(invalid_profile_version(request_id));
    }
    let version = raw
        .strip_prefix("\"profile-")
        .and_then(|value| value.strip_suffix('"'))
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|version| *version > 0)
        .ok_or_else(|| invalid_profile_version(request_id))?;
    if profile_entity_tag(version).as_ref() != Some(value) {
        return Err(invalid_profile_version(request_id));
    }
    Ok(version)
}

fn invalid_profile_version(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_PROFILE_VERSION",
        "If-Match must be an exact strong profile ETag.",
        false,
    )
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use accounts::{AccountPolicy, AccountService, AccountStore, RateLimitStore};
    use arxiv_client::ArxivClientConfig;
    use async_trait::async_trait;
    use auth::{
        AuthRuntime, AuthUnavailableReason, TokenVerifier, VerifiedOidcClaims, VerifyError,
    };
    use axum::{
        Router,
        body::Body,
        http::{
            Method, Request,
            header::{AUTHORIZATION, CONTENT_TYPE, RETRY_AFTER, WWW_AUTHENTICATE},
        },
        middleware,
        routing::get,
    };
    use chrono::{TimeZone as _, Utc};
    use db::{DbError, ProfilePatch, ProfileUpdateOutcome, RateLimitDecision, RateLimitRequest};
    use domain::{
        AccountStatus, AuthenticatedUserId, DisplayName, FulltextPolicy, Handle, TermsVersion, User,
    };
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;
    use uuid::Uuid;

    use super::*;
    use crate::{
        AccountFeatureConfig, ApiConfig, ApiEnvironment, FeatureFlags, build_router,
        middleware::{OptionalPrincipal, request_id_middleware},
    };

    #[test]
    fn profile_validator_is_exact_strong_and_positive() {
        let request_id = RequestId(Uuid::nil());
        for invalid in [
            "profile-2",
            "W/\"profile-2\"",
            "\"profile-0\"",
            "\"profile-02\"",
            "\"profile--1\"",
            "\"profile-2\", \"profile-3\"",
            "*",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(IF_MATCH, HeaderValue::from_str(invalid).unwrap());
            let error = expected_profile_version(&headers, request_id).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST, "accepted {invalid}");
            assert_eq!(error.code, "INVALID_PROFILE_VERSION");
        }
        let missing = expected_profile_version(&HeaderMap::new(), request_id).unwrap_err();
        assert_eq!(missing.status, StatusCode::PRECONDITION_REQUIRED);
        assert_eq!(missing.code, "PROFILE_VERSION_REQUIRED");

        let mut valid = HeaderMap::new();
        valid.insert(IF_MATCH, HeaderValue::from_static("\"profile-42\""));
        assert_eq!(expected_profile_version(&valid, request_id).unwrap(), 42);
    }

    #[test]
    fn patch_json_distinguishes_omitted_null_and_value_and_denies_unknown_fields() {
        let body: ProfileUpdateBody = serde_json::from_str(r#"{"display_name":null}"#).unwrap();
        assert_eq!(body.handle, ProfilePatchField::Omitted);
        assert_eq!(body.display_name, ProfilePatchField::Null);
        assert_eq!(body.accept_terms_version, ProfilePatchField::Omitted);

        let body: ProfileUpdateBody =
            serde_json::from_str(r#"{"handle":"Ada_Reader","display_name":"Ada"}"#).unwrap();
        assert_eq!(
            body.handle,
            ProfilePatchField::Value("Ada_Reader".to_owned())
        );
        assert_eq!(
            body.display_name,
            ProfilePatchField::Value("Ada".to_owned())
        );
        assert!(serde_json::from_str::<ProfileUpdateBody>(r#"{"admin":true}"#).is_err());
    }

    #[test]
    fn response_completeness_requires_handle_and_current_terms() {
        let terms = TermsVersion::parse("2026-07-31").unwrap();
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let mut user = User {
            id: AuthenticatedUserId::new(Uuid::now_v7()),
            handle: Some(Handle::parse("ada_reader").unwrap()),
            display_name: None,
            status: AccountStatus::Active,
            profile_version: 1,
            terms_version: None,
            terms_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        };
        let envelope = AccountProfileEnvelope::new(&user, &terms);
        assert!(!envelope.account.profile_complete);
        assert!(!envelope.account.terms_current);

        user.terms_version = Some(terms.clone());
        user.terms_accepted_at = Some(now);
        let envelope = AccountProfileEnvelope::new(&user, &terms);
        assert!(envelope.account.profile_complete);
        assert!(envelope.account.terms_current);
    }

    #[derive(Clone)]
    struct FakeAccountStore {
        user: Arc<Mutex<User>>,
        provision_count: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl AccountStore for FakeAccountStore {
        async fn provision_oidc_identity(
            &self,
            issuer: &str,
            subject: &str,
            _last_seen_interval: Duration,
        ) -> Result<User, DbError> {
            assert_eq!(issuer, "https://identity.example/realms/pakperk");
            assert_eq!(subject, "private-subject");
            self.provision_count.fetch_add(1, Ordering::SeqCst);
            Ok(self.user.lock().unwrap().clone())
        }

        async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
            let user = self.user.lock().unwrap().clone();
            Ok((user.id == user_id).then_some(user))
        }

        async fn update_profile(
            &self,
            user_id: AuthenticatedUserId,
            expected_profile_version: i64,
            patch: &ProfilePatch,
        ) -> Result<ProfileUpdateOutcome, DbError> {
            let mut user = self.user.lock().unwrap();
            if user.id != user_id {
                return Ok(ProfileUpdateOutcome::NotFound);
            }
            if user.profile_version != expected_profile_version {
                return Ok(ProfileUpdateOutcome::VersionConflict {
                    current_version: user.profile_version,
                });
            }
            if patch.handle.is_some() && user.handle.is_some() {
                return Ok(ProfileUpdateOutcome::HandleAlreadySet);
            }
            if let Some(handle) = &patch.handle {
                user.handle = Some(handle.clone());
            }
            if let Some(display_name) = &patch.display_name {
                user.display_name = display_name.clone();
            }
            let update_time = user.updated_at + chrono::TimeDelta::seconds(1);
            if let Some(terms) = &patch.terms_version {
                user.terms_version = Some(terms.clone());
                user.terms_accepted_at = Some(update_time);
            }
            user.profile_version += 1;
            user.updated_at = update_time;
            Ok(ProfileUpdateOutcome::Updated(user.clone()))
        }
    }

    #[derive(Debug)]
    struct AllowingRateLimit;

    #[async_trait]
    impl RateLimitStore for AllowingRateLimit {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            Ok(RateLimitDecision {
                allowed: true,
                limit: request.limit(),
                remaining: request.limit().saturating_sub(1),
                reset_at: Utc::now() + chrono::TimeDelta::minutes(1),
                retry_after_seconds: None,
            })
        }
    }

    struct AcceptingVerifier;

    #[async_trait]
    impl TokenVerifier for AcceptingVerifier {
        async fn verify(&self, _bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
            Ok(VerifiedOidcClaims::try_from_verified_parts(
                "https://identity.example/realms/pakperk".to_owned(),
                "private-subject".to_owned(),
                vec!["pakperk-api".to_owned()],
                Utc::now() + chrono::TimeDelta::minutes(5),
                Some(Utc::now()),
                Some(Utc::now()),
            )
            .unwrap())
        }
    }

    struct RejectingVerifier(VerifyError);

    #[async_trait]
    impl TokenVerifier for RejectingVerifier {
        async fn verify(&self, _bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
            Err(self.0)
        }
    }

    fn account_api_config(enabled: bool) -> ApiConfig {
        let terms = TermsVersion::parse("2026-07-31").unwrap();
        let account = enabled.then(|| AccountFeatureConfig {
            oidc: auth::OidcVerifierConfig::new(
                "https://identity.example/realms/pakperk".parse().unwrap(),
                "pakperk-api",
                vec![auth::OidcAlgorithm::Rs256],
            ),
            current_terms_version: terms,
            last_seen_interval: Duration::from_secs(15 * 60),
            profile_update_limit: 5,
            profile_update_window: Duration::from_secs(60 * 60),
            auth_retry_initial: Duration::from_secs(5),
            auth_retry_maximum: Duration::from_secs(5 * 60),
        });
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags {
                accounts: enabled,
                library: false,
                library_writes: false,
                comments: false,
            },
            accounts: account,
            library: None,
            bind: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://test:test@127.0.0.1/test".to_owned(),
            database_pool_size: 1,
            run_migrations: false,
            request_timeout: Duration::from_secs(30),
            chat_request_timeout: Duration::from_secs(70),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv: ArxivClientConfig {
                user_agent: "PakperkAccountApiTest/0.1".to_owned(),
                contact_email: "testing@pakperk.org".to_owned(),
                ..ArxivClientConfig::default()
            },
            arxiv_cache_ttl: Duration::from_secs(60),
            fulltext_policy: FulltextPolicy::Prototype,
            embedding_dimension: None,
            llm: None,
            prepare_requests_per_minute: 10,
            chat_requests_per_minute: 10,
        }
    }

    fn lazy_database() -> db::Database {
        db::Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        )
    }

    fn active_user() -> User {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        User {
            id: AuthenticatedUserId::new(Uuid::now_v7()),
            handle: None,
            display_name: Some(DisplayName::parse("Ada Reader").unwrap()),
            status: AccountStatus::Active,
            profile_version: 1,
            terms_version: None,
            terms_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        }
    }

    fn account_test_app_with(
        verifier: Arc<dyn TokenVerifier>,
        user: User,
    ) -> (Router, Arc<AtomicUsize>) {
        let config = account_api_config(true);
        let auth = AuthRuntime::ready(verifier);
        let mut state = AppState::new_with_auth(lazy_database(), &config, auth).unwrap();
        let user = Arc::new(Mutex::new(user));
        let provision_count = Arc::new(AtomicUsize::new(0));
        state.accounts = Some(AccountService::with_stores(
            Arc::new(FakeAccountStore {
                user,
                provision_count: Arc::clone(&provision_count),
            }),
            Arc::new(AllowingRateLimit),
            AccountPolicy::new(
                TermsVersion::parse("2026-07-31").unwrap(),
                Duration::from_secs(15 * 60),
                5,
                Duration::from_secs(60 * 60),
            )
            .unwrap(),
        ));
        (build_router(state, &config), provision_count)
    }

    fn account_test_app() -> (Router, Arc<AtomicUsize>) {
        account_test_app_with(Arc::new(AcceptingVerifier), active_user())
    }

    #[tokio::test]
    async fn account_router_jit_provisions_and_enforces_profile_etags() {
        let (app, provision_count) = account_test_app();

        let response = app
            .clone()
            .oneshot(Request::get("/v1/me").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);

        let response = app
            .clone()
            .oneshot(
                Request::get("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[ETAG], "\"profile-1\"");
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        let body = response_json(response).await;
        assert_eq!(body["account"]["profile_complete"], false);
        assert_eq!(body["account"]["terms_current"], false);
        assert!(!body.to_string().contains("private-token"));
        assert!(!body.to_string().contains("private-subject"));

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"display_name":null}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PRECONDITION_REQUIRED);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "PROFILE_VERSION_REQUIRED"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(IF_MATCH, "\"profile-1\"")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"handle":"Ada_Reader","accept_terms_version":"2026-07-31"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[ETAG], "\"profile-2\"");
        let body = response_json(response).await;
        assert_eq!(body["account"]["handle"], "ada_reader");
        assert_eq!(body["account"]["profile_complete"], true);
        assert_eq!(body["account"]["terms_current"], true);

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(IF_MATCH, "\"profile-1\"")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"display_name":"Changed"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PRECONDITION_FAILED);
        assert_eq!(response.headers()[ETAG], "\"profile-2\"");
        assert_eq!(
            response_json(response).await["error"]["code"],
            "PROFILE_VERSION_CONFLICT"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 4);
    }

    #[tokio::test]
    async fn account_json_rejections_are_stable_and_private() {
        let (app, _) = account_test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(IF_MATCH, "\"profile-1\"")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"unknown":true}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_REQUEST"
        );
    }

    #[tokio::test]
    async fn account_feature_off_is_404_and_unavailable_oidc_does_not_gate_optional_routes() {
        let disabled_config = account_api_config(false);
        let disabled = build_router(
            AppState::new(lazy_database(), &disabled_config).unwrap(),
            &disabled_config,
        );
        assert_eq!(
            disabled
                .oneshot(Request::get("/v1/me").body(Body::empty()).unwrap())
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );

        let config = account_api_config(true);
        let auth = AuthRuntime::unavailable(
            AuthUnavailableReason::ProviderUnavailable,
            Duration::from_secs(19),
        );
        let state = AppState::new_with_auth(lazy_database(), &config, auth).unwrap();
        let public = Router::new()
            .route(
                "/public",
                get(|principal: OptionalPrincipal| async move {
                    assert!(principal.0.is_none());
                    StatusCode::OK
                }),
            )
            .route(
                "/required",
                get(|_principal: AuthenticatedPrincipal| async { StatusCode::OK }),
            )
            .with_state(state)
            .layer(middleware::from_fn(request_id_middleware));
        let response = public
            .clone()
            .oneshot(
                Request::get("/public")
                    .header(AUTHORIZATION, "Bearer ignored-while-offline")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let response = public
            .oneshot(
                Request::get("/required")
                    .header(AUTHORIZATION, "Bearer cannot-be-verified")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()[RETRY_AFTER], "19");
        assert_eq!(
            response_json(response).await["error"]["code"],
            "AUTHENTICATION_UNAVAILABLE"
        );
    }

    #[tokio::test]
    async fn public_paper_route_treats_ready_metadata_outage_as_guest() {
        let (app, provision_count) = account_test_app_with(
            Arc::new(RejectingVerifier(VerifyError::MetadataUnavailable)),
            active_user(),
        );
        let response = app
            .oneshot(
                Request::get("/v1/papers/by-arxiv/definitely-invalid")
                    .header(AUTHORIZATION, "Bearer cannot-be-verified-now")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_ARXIV_ID"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn public_paper_route_treats_inactive_account_as_guest_but_private_route_denies_it() {
        let mut suspended = active_user();
        suspended.status = AccountStatus::Suspended;
        let (app, provision_count) = account_test_app_with(Arc::new(AcceptingVerifier), suspended);

        let response = app
            .clone()
            .oneshot(
                Request::get("/v1/papers/by-arxiv/definitely-invalid")
                    .header(AUTHORIZATION, "Bearer suspended-account-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_ARXIV_ID"
        );

        let response = app
            .oneshot(
                Request::get("/v1/me")
                    .header(AUTHORIZATION, "Bearer suspended-account-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "ACCOUNT_SUSPENDED"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn public_paper_route_rejects_malformed_and_cryptographically_invalid_bearers() {
        let (app, provision_count) = account_test_app_with(
            Arc::new(RejectingVerifier(VerifyError::InvalidSignature)),
            active_user(),
        );

        for authorization in ["Basic credentials", "Bearer invalid-signature"] {
            let response = app
                .clone()
                .oneshot(
                    Request::get("/v1/papers/by-arxiv/definitely-invalid")
                        .header(AUTHORIZATION, authorization)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");
            assert_eq!(
                response_json(response).await["error"]["code"],
                "UNAUTHENTICATED"
            );
        }
        assert_eq!(provision_count.load(Ordering::SeqCst), 0);
    }

    async fn response_json(response: Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}
