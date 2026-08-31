use std::time::Instant;

use axum::{
    Extension, Json,
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
};
use chrono::Utc;
use engagement::{BriefMode, ReadingBrief};
use observability::{
    OperationClass, OperationOutcome, ReadingFeedModeClass, record_operation,
    record_reading_feed_cursor_stale, record_reading_feed_decision,
};
use reading_feed::{
    FeedMode, ReadingFeedPage, ReadingFeedPolicyError, ReadingFeedRequest, ReadingFeedServiceError,
    RecommendationMode,
};
use research_profiles::{PreferredDiscoveryMode, ProfileSettings};
use tracing::{error, info, warn};

use crate::{
    AppState,
    dto::{ReadingFeedBriefResponse, ReadingFeedEnvelope, ReadingFeedParams},
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::support::apply_summary_policy,
};

#[utoipa::path(
    get,
    path = "/v1/me/reading-feed",
    tag = "reading feed",
    description = "Returns the authenticated queue-first feed and current shadow/strict rollout policy from one account-scoped snapshot. Active To Read rows always suppress recommendations, and this route never schedules paper preparation. When recommendation_mode is omitted, the current research-profile preference is used if profiles are enabled; an unavailable profile safely falls back to Recent. An explicit query always wins, and the effective mode is bound into every cursor. An optional brief_id adds only an authority-revalidated progress summary; brief creation, selection, and mutation remain owned by the dedicated /v1/me/reading-briefs endpoints. Registered only when accounts, library, and reading feed are enabled.",
    security(("oidcBearer" = [])),
    params(
        ("category" = Option<String>, Query, max_length = 32, description = "Optional bounded arXiv category applied only to recommendations", example = "cs.AI"),
        ("recommendation_mode" = Option<String>, Query, description = "Explicit preference applied only after this request proves the active queue empty: recent, following, for_you, or explore. Omission uses the current research-profile preference when enabled, otherwise Recent.", example = "recent"),
        ("cursor" = Option<String>, Query, max_length = 512, description = "Opaque account, mode, revision, query, and expiry-bound continuation"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 50, description = "Bounded page size; defaults to 20"),
        ("brief_id" = Option<uuid::Uuid>, Query, description = "Optional account-owned brief whose progress summary is returned only when its exact queue or recommendation authority still matches this page")
    ),
    responses(
        (status = 200, description = "Authoritative To Read page or recommendations selected only after the same snapshot proves the queue empty", body = crate::openapi::ReadingFeedEnvelopeSchema, headers(
            ("Cache-Control" = String, description = "Always private, no-store"),
            ("Vary" = String, description = "Always Authorization")
        )),
        (status = 400, description = "INVALID_REQUEST, INVALID_READING_FEED_CATEGORY, INVALID_READING_FEED_CURSOR, or INVALID_READING_FEED_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "READING_FEED_CURSOR_STALE; discard the cursor and restart page one", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED, AUTHENTICATION_UNAVAILABLE, or QUEUE_AUTHORITY_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(name = "reading_feed.request", skip_all)]
pub(crate) async fn reading_feed(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<ReadingFeedParams>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().reading_feed {
        return Err(feature_disabled(request_id));
    }
    let requested_brief_id = params.brief_id;
    let service = state
        .reading_feed
        .as_ref()
        .ok_or_else(|| feature_disabled(request_id))?;
    let recommendation_mode = match params.recommendation_mode {
        Some(explicit) => explicit,
        None => effective_recommendation_mode(
            None,
            discovery_defaults(&state, principal.user_id, request_id, 20).await,
        ),
    };
    let started = Instant::now();
    let result = service
        .page(ReadingFeedRequest {
            user_id: principal.user_id,
            category: params.category,
            recommendation_mode,
            cursor: params.cursor,
            limit: params.limit,
            now: Utc::now(),
        })
        .await;
    if matches!(result, Err(ReadingFeedServiceError::CursorStale)) {
        record_reading_feed_cursor_stale();
    }
    let result = match result {
        Ok(mut page) => mask_paper_summaries(&state, request_id, &mut page)
            .await
            .map(|()| page),
        Err(error_value) => Err(reading_feed_error(request_id, error_value)),
    };
    record_operation(
        OperationClass::ReadingFeed,
        reading_feed_outcome(&result),
        started.elapsed(),
    );
    let page = result?;
    let metric_mode = match page.mode {
        FeedMode::ToRead => ReadingFeedModeClass::ToRead,
        FeedMode::Recommendations => ReadingFeedModeClass::Recommendations,
    };
    record_reading_feed_decision(
        metric_mode,
        u64::try_from(page.items.len()).unwrap_or(u64::MAX),
        page.decision.active_to_read_count,
        started.elapsed(),
    );
    let brief = bound_brief_summary(
        &state,
        principal.user_id,
        request_id,
        requested_brief_id,
        &page,
    )
    .await;
    info!(
        reading_feed.mode = mode_name(page.mode),
        reading_feed.item_count_bucket = item_count_bucket(page.items.len()),
        "authenticated reading-feed decision completed"
    );
    Ok(Json(ReadingFeedEnvelope::new(
        page,
        state.feature_flags().to_read_first_enforcement,
        brief,
    )))
}

async fn bound_brief_summary(
    state: &AppState,
    user_id: domain::AuthenticatedUserId,
    request_id: RequestId,
    requested_brief_id: Option<uuid::Uuid>,
    page: &ReadingFeedPage,
) -> Option<ReadingFeedBriefResponse> {
    let requested_brief_id = requested_brief_id.filter(|brief_id| !brief_id.is_nil())?;
    if !state.feature_flags().reading_briefs {
        return None;
    }
    let engagement = state.engagement.as_ref()?;
    match engagement.brief(user_id, requested_brief_id).await {
        Ok(Some(brief)) if brief_matches_page(&brief, page) => Some((&brief).into()),
        Ok(Some(_) | None) => None,
        Err(_error_value) => {
            warn!(
                request_id = %request_id.0,
                error.kind = "reading_brief_binding_unavailable",
                "reading-brief progress binding was unavailable; returning the authoritative feed without brief metadata"
            );
            None
        }
    }
}

fn brief_matches_page(brief: &ReadingBrief, page: &ReadingFeedPage) -> bool {
    if brief.library_revision != page.decision.library_revision {
        return false;
    }
    match (brief.mode, page.mode) {
        (BriefMode::Queue, FeedMode::ToRead) => {
            brief.recommendation_mode.is_none()
                && brief.recommendation_batch_id.is_none()
                && page.batch_id.is_none()
        }
        (BriefMode::Discovery, FeedMode::Recommendations) => {
            brief.recommendation_batch_id.is_some()
                && brief.recommendation_batch_id == page.batch_id
                && brief.recommendation_mode.is_some()
                && page.items.iter().all(|item| {
                    item.recommendation
                        .as_ref()
                        .is_some_and(|metadata| Some(metadata.mode) == brief.recommendation_mode)
                })
        }
        (BriefMode::Queue, FeedMode::Recommendations)
        | (BriefMode::Discovery, FeedMode::ToRead) => false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct DiscoveryDefaults {
    pub(super) recommendation_mode: RecommendationMode,
    pub(super) brief_size: u32,
}

/// Resolve only presentation/ranking defaults. Queue authority remains wholly
/// inside `ReadingFeedService`; a missing or unavailable profile can therefore
/// degrade to deterministic Recent without weakening the queue gate.
pub(super) async fn discovery_defaults(
    state: &AppState,
    user_id: domain::AuthenticatedUserId,
    request_id: RequestId,
    fallback_brief_size: u32,
) -> DiscoveryDefaults {
    let fallback = DiscoveryDefaults {
        recommendation_mode: RecommendationMode::Recent,
        brief_size: fallback_brief_size,
    };
    let Some(profiles) = state.research_profiles.as_ref() else {
        return fallback;
    };
    match profiles.get(user_id).await {
        Ok(profile) => defaults_from_settings(&profile.settings).unwrap_or_else(|| {
            warn!(
                request_id = %request_id.0,
                error.kind = "research_profile_preference_invalid",
                "research-profile discovery defaults were invalid; using safe defaults"
            );
            fallback
        }),
        Err(_error_value) => {
            warn!(
                request_id = %request_id.0,
                error.kind = "research_profile_preference_unavailable",
                "research-profile discovery defaults were unavailable; using safe defaults"
            );
            fallback
        }
    }
}

fn defaults_from_settings(settings: &ProfileSettings) -> Option<DiscoveryDefaults> {
    (15..=25)
        .contains(&settings.brief_size)
        .then_some(DiscoveryDefaults {
            recommendation_mode: preferred_mode(settings.preferred_discovery_mode),
            brief_size: u32::from(settings.brief_size),
        })
}

pub(super) const fn effective_recommendation_mode(
    explicit: Option<RecommendationMode>,
    defaults: DiscoveryDefaults,
) -> RecommendationMode {
    match explicit {
        Some(mode) => mode,
        None => defaults.recommendation_mode,
    }
}

const fn preferred_mode(mode: PreferredDiscoveryMode) -> RecommendationMode {
    match mode {
        PreferredDiscoveryMode::Recent => RecommendationMode::Recent,
        PreferredDiscoveryMode::Following => RecommendationMode::Following,
        PreferredDiscoveryMode::ForYou => RecommendationMode::ForYou,
        PreferredDiscoveryMode::Explore => RecommendationMode::Explore,
    }
}

async fn mask_paper_summaries(
    state: &AppState,
    request_id: RequestId,
    page: &mut ReadingFeedPage,
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict || page.items.is_empty() {
        return Ok(());
    }
    let paper_ids = page
        .items
        .iter()
        .map(|item| item.paper.paper_id)
        .collect::<Vec<_>>();
    let licenses = state
        .papers
        .license_uris(&paper_ids)
        .await
        .map_err(|_error_value| {
            error!(
                request_id = %request_id.0,
                error.kind = "reading_feed_policy_lookup",
                "reading-feed metadata policy lookup failed"
            );
            queue_authority_unavailable(request_id)
        })?;
    for item in &mut page.items {
        let license = licenses.get(&item.paper.paper_id).and_then(Option::as_ref);
        apply_summary_policy(state.fulltext_policy, license, &mut item.paper);
    }
    Ok(())
}

fn feature_disabled(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "FEATURE_DISABLED",
        "The authenticated reading feed is disabled.",
        false,
    )
}

fn reading_feed_error(request_id: RequestId, error_value: ReadingFeedServiceError) -> ApiError {
    match error_value {
        ReadingFeedServiceError::Policy(ReadingFeedPolicyError::InvalidPageLimit) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_READING_FEED_LIMIT",
            "The reading-feed page limit is invalid.",
            false,
        ),
        ReadingFeedServiceError::Policy(ReadingFeedPolicyError::InvalidCategory) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_READING_FEED_CATEGORY",
            "The reading-feed category is invalid.",
            false,
        ),
        ReadingFeedServiceError::InvalidCursor => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_READING_FEED_CURSOR",
            "The reading-feed cursor is invalid or expired.",
            false,
        ),
        ReadingFeedServiceError::CursorStale => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "READING_FEED_CURSOR_STALE",
            "The To Read list changed. Restart from the first page.",
            true,
        ),
        ReadingFeedServiceError::Suspended => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
            false,
        ),
        ReadingFeedServiceError::DeletionPending | ReadingFeedServiceError::Deleted => {
            ApiError::new(
                request_id,
                StatusCode::FORBIDDEN,
                "ACCOUNT_DELETION_PENDING",
                "This account is unavailable.",
                false,
            )
        }
        ReadingFeedServiceError::Policy(
            ReadingFeedPolicyError::InvalidPageLimits | ReadingFeedPolicyError::InvalidCursorTtl,
        )
        | ReadingFeedServiceError::AccountNotFound
        | ReadingFeedServiceError::QueueAuthorityUnavailable
        | ReadingFeedServiceError::CursorUnavailable
        | ReadingFeedServiceError::RecommendationsUnavailable => {
            error!(
                request_id = %request_id.0,
                error.kind = "reading_feed_authority",
                "authenticated reading feed could not prove queue authority"
            );
            queue_authority_unavailable(request_id)
        }
    }
}

fn queue_authority_unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "QUEUE_AUTHORITY_UNAVAILABLE",
        "The To Read queue could not be verified.",
        true,
    )
}

fn reading_feed_outcome(result: &Result<ReadingFeedPage, ApiError>) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(error) if error.retryable => OperationOutcome::RetryableFailure,
        Err(error) if error.status.is_client_error() => OperationOutcome::Rejected,
        Err(_) => OperationOutcome::TerminalFailure,
    }
}

const fn mode_name(mode: FeedMode) -> &'static str {
    match mode {
        FeedMode::ToRead => "to_read",
        FeedMode::Recommendations => "recommendations",
    }
}

const fn item_count_bucket(item_count: usize) -> &'static str {
    match item_count {
        0 => "0",
        1 => "1",
        2..=5 => "2_5",
        6..=20 => "6_20",
        _ => "21_plus",
    }
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, sync::Arc, time::Duration};

    use accounts::{AccountPolicy, AccountService, AccountStore, RateLimitStore};
    use arxiv_client::ArxivClientConfig;
    use async_trait::async_trait;
    use auth::{AuthRuntime, TokenVerifier, VerifiedOidcClaims, VerifyError};
    use axum::{
        body::Body,
        http::{Request, header::AUTHORIZATION},
    };
    use db::{
        DbError, EncryptedReadingFeedCursorCodec, ProfilePatch, ProfileUpdateOutcome,
        RateLimitDecision, RateLimitRequest,
    };
    use domain::{
        AccountStatus, AuthenticatedUserId, DisplayName, FulltextPolicy, TermsVersion, User,
    };
    use reading_feed::{
        ChronologicalRecommendationSource, ReadingFeedService, ReadingFeedSnapshot,
        ReadingFeedSnapshotRequest, ReadingFeedStore, ReadingFeedStoreError, RecommendationPage,
    };
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;
    use uuid::Uuid;

    use super::*;
    use crate::{
        AccountFeatureConfig, ApiConfig, ApiEnvironment, FeatureFlags, LibraryFeatureConfig,
        build_router,
    };

    #[test]
    fn stable_errors_distinguish_invalid_and_stale_cursors() {
        let request_id = RequestId(uuid::Uuid::nil());
        let invalid = reading_feed_error(request_id, ReadingFeedServiceError::InvalidCursor);
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.code, "INVALID_READING_FEED_CURSOR");
        assert!(!invalid.retryable);

        let stale = reading_feed_error(request_id, ReadingFeedServiceError::CursorStale);
        assert_eq!(stale.status, StatusCode::CONFLICT);
        assert_eq!(stale.code, "READING_FEED_CURSOR_STALE");
        assert!(stale.retryable);
    }

    #[test]
    fn observability_labels_are_closed() {
        assert_eq!(mode_name(FeedMode::ToRead), "to_read");
        assert_eq!(mode_name(FeedMode::Recommendations), "recommendations");
        assert_eq!(item_count_bucket(0), "0");
        assert_eq!(item_count_bucket(4), "2_5");
        assert_eq!(item_count_bucket(50), "21_plus");
    }

    #[test]
    fn omitted_mode_uses_profile_following_or_for_you_and_explicit_recent_wins() {
        for preferred in [
            PreferredDiscoveryMode::Following,
            PreferredDiscoveryMode::ForYou,
        ] {
            let settings = ProfileSettings {
                preferred_discovery_mode: preferred,
                brief_size: 25,
                ..ProfileSettings::default()
            };
            let defaults = defaults_from_settings(&settings).unwrap();
            let expected = preferred_mode(preferred);
            assert_eq!(effective_recommendation_mode(None, defaults), expected);
            assert_eq!(defaults.brief_size, 25);
            assert_eq!(
                effective_recommendation_mode(Some(RecommendationMode::Recent), defaults),
                RecommendationMode::Recent
            );
        }
        assert!(
            defaults_from_settings(&ProfileSettings {
                brief_size: 26,
                ..ProfileSettings::default()
            })
            .is_none(),
            "invalid stored settings must take the closed safe fallback"
        );
    }

    #[test]
    fn brief_summary_requires_exact_page_authority() {
        let batch_id = Uuid::from_u128(11);
        let now = Utc::now();
        let mut brief = ReadingBrief {
            id: Uuid::from_u128(12),
            mode: BriefMode::Discovery,
            recommendation_mode: Some(RecommendationMode::ForYou),
            library_revision: 7,
            recommendation_batch_id: Some(batch_id),
            local_date: now.date_naive(),
            position: 5,
            progress_revision: 2,
            status: engagement::BriefStatus::Current,
            items: Vec::new(),
            completed_at: None,
            created_at: now,
            updated_at: now,
        };
        let mut page = ReadingFeedPage {
            mode: FeedMode::Recommendations,
            decision: reading_feed::ReadingFeedDecision {
                library_revision: 7,
                active_to_read_count: 0,
                queue_proven_empty: true,
            },
            batch_id: Some(batch_id),
            batch_metadata: Some(reading_feed::RecommendationBatchMetadata {
                profile_revision: Some(3),
                feedback_revision: 4,
                algorithm_version: "recommendations_v1".to_owned(),
                recommendation_policy_version: "weighted_v1".to_owned(),
            }),
            items: Vec::new(),
            next_cursor: None,
            server_time: now,
        };
        assert!(brief_matches_page(&brief, &page));
        page.batch_id = Some(Uuid::from_u128(13));
        assert!(!brief_matches_page(&brief, &page));
        page.batch_id = Some(batch_id);
        brief.library_revision = 8;
        assert!(!brief_matches_page(&brief, &page));

        brief.mode = BriefMode::Queue;
        brief.recommendation_mode = None;
        brief.recommendation_batch_id = None;
        brief.library_revision = 7;
        page.mode = FeedMode::ToRead;
        page.batch_id = None;
        page.batch_metadata = None;
        assert!(brief_matches_page(&brief, &page));
    }

    #[tokio::test]
    async fn authenticated_route_emits_strict_when_enforcement_is_enabled() {
        let config = strict_reading_feed_config();
        let user = active_user();
        let user_id = user.id;
        let auth = AuthRuntime::ready(Arc::new(AcceptingVerifier));
        let mut state = AppState::new_with_auth(lazy_database(), &config, auth).unwrap();
        state.accounts = Some(AccountService::with_stores(
            Arc::new(FakeAccountStore { user }),
            Arc::new(AllowingRateLimit),
            AccountPolicy::new(
                TermsVersion::parse("2026-07-31").unwrap(),
                domain::CommunityGuidelinesVersion::parse("2026-08-01").unwrap(),
                Duration::from_secs(15 * 60),
                5,
                Duration::from_secs(60 * 60),
            )
            .unwrap(),
        ));
        state.reading_feed = Some(ReadingFeedService::with_dependencies(
            Arc::new(EmptyReadingFeedStore { user_id }),
            Arc::new(ChronologicalRecommendationSource),
            Arc::new(EncryptedReadingFeedCursorCodec::new(config.cursors.codec())),
            config.reading_feed.policy().unwrap(),
        ));

        let response = build_router(state, &config)
            .oneshot(
                Request::get("/v1/me/reading-feed")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["enforcement"], "strict");
        assert_eq!(body["mode"], "recommendations");
        assert_eq!(body["decision"]["queue_proven_empty"], true);
    }

    struct EmptyReadingFeedStore {
        user_id: AuthenticatedUserId,
    }

    #[async_trait]
    impl ReadingFeedStore for EmptyReadingFeedStore {
        async fn snapshot(
            &self,
            request: &ReadingFeedSnapshotRequest,
        ) -> Result<ReadingFeedSnapshot, ReadingFeedStoreError> {
            assert_eq!(request.user_id, self.user_id);
            Ok(ReadingFeedSnapshot::Empty {
                library_revision: 7,
                recommendations: RecommendationPage {
                    items: Vec::new(),
                    next_position: None,
                },
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

    struct FakeAccountStore {
        user: User,
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
            Ok(self.user.clone())
        }

        async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
            Ok((self.user.id == user_id).then(|| self.user.clone()))
        }

        async fn update_profile(
            &self,
            _user_id: AuthenticatedUserId,
            _expected_profile_version: i64,
            _patch: &ProfilePatch,
        ) -> Result<ProfileUpdateOutcome, DbError> {
            Ok(ProfileUpdateOutcome::NotFound)
        }
    }

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

    fn active_user() -> User {
        let now = Utc::now();
        User {
            id: AuthenticatedUserId::new(Uuid::now_v7()),
            handle: None,
            display_name: Some(DisplayName::parse("Ada Reader").unwrap()),
            status: AccountStatus::Active,
            profile_version: 1,
            terms_version: None,
            terms_accepted_at: None,
            community_guidelines_version: None,
            community_guidelines_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        }
    }

    fn strict_reading_feed_config() -> ApiConfig {
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags {
                accounts: true,
                library: true,
                reading_feed: true,
                to_read_first_enforcement: true,
                ..FeatureFlags::default()
            },
            accounts: Some(AccountFeatureConfig {
                oidc: auth::OidcVerifierConfig::new(
                    "https://identity.example/realms/pakperk".parse().unwrap(),
                    "pakperk-api",
                    vec![auth::OidcAlgorithm::Rs256],
                ),
                current_terms_version: TermsVersion::parse("2026-07-31").unwrap(),
                current_community_guidelines_version: domain::CommunityGuidelinesVersion::parse(
                    "2026-08-01",
                )
                .unwrap(),
                last_seen_interval: Duration::from_secs(15 * 60),
                profile_update_limit: 5,
                profile_update_window: Duration::from_secs(60 * 60),
                auth_retry_initial: Duration::from_secs(5),
                auth_retry_maximum: Duration::from_secs(5 * 60),
                identity_fingerprints: None,
            }),
            library: Some(LibraryFeatureConfig {
                mutation_limit: 120,
                mutation_window: Duration::from_secs(60 * 60),
            }),
            comments: None,
            account_deletion: None,
            visual_assets: None,
            paper_resolution: crate::config::PaperResolutionFeatureConfig::default(),
            reading_feed: crate::config::ReadingFeedFeatureConfig::default(),
            request_origin: crate::config::RequestOriginConfig::for_local_development(
                "reading-feed-route-request-origin-secret-0123456789",
            )
            .unwrap(),
            cursors: crate::config::CursorConfig::for_local_development(
                "reading-feed-route-cursor-test-seed",
            )
            .unwrap(),
            bind: SocketAddr::from(([127, 0, 0, 1], 0)),
            database_url: "postgres://test:test@127.0.0.1/test".to_owned(),
            database_pool_size: 1,
            run_migrations: false,
            request_timeout: Duration::from_secs(5),
            chat_request_timeout: Duration::from_secs(5),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv: ArxivClientConfig {
                user_agent: "PakperkReadingFeedApiTest/0.1".to_owned(),
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
}
