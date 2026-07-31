use std::time::Duration;

use db::{Database, ProfilePatch, ProfileUpdateOutcome, RateLimitRequest};
use domain::{AccountStatus, DisplayName, Handle, TermsVersion};
use uuid::Uuid;

/// Opt-in `PostgreSQL` coverage. CI supplies `TEST_DATABASE_URL`; developer
/// machines without it keep the test visible and explicitly skip it.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_accounts_jit_profile_cas_and_shared_rate_limit() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL account coverage");
        return;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://issuer.example/{unique}");
    let subject = format!("subject-{unique}");
    let accounts = database.accounts();

    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..24 {
        let accounts = accounts.clone();
        let issuer = issuer.clone();
        let subject = subject.clone();
        tasks.spawn(async move {
            accounts
                .provision_oidc_identity(&issuer, &subject, Duration::from_secs(15 * 60))
                .await
                .unwrap()
        });
    }
    let mut provisioned = Vec::new();
    while let Some(result) = tasks.join_next().await {
        provisioned.push(result.unwrap());
    }
    let user = provisioned.first().unwrap();
    assert!(provisioned.iter().all(|candidate| candidate.id == user.id));
    let identity_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM users WHERE oidc_issuer = $1 AND oidc_subject = $2",
    )
    .bind(&issuer)
    .bind(&subject)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(identity_count, 1);

    let user_id = user.id;
    let profile = match accounts
        .update_profile(
            user_id,
            user.profile_version,
            &ProfilePatch {
                handle: Some(Handle::parse("Ada_Account").unwrap()),
                display_name: Some(Some(DisplayName::parse("  Ａda  ").unwrap())),
                terms_version: Some(TermsVersion::parse("2026-07-31").unwrap()),
            },
        )
        .await
        .unwrap()
    {
        ProfileUpdateOutcome::Updated(user) => user,
        outcome => panic!("expected updated profile, got {outcome:?}"),
    };
    assert_eq!(profile.handle.unwrap().as_str(), "ada_account");
    assert_eq!(profile.display_name.unwrap().as_str(), "Ada");
    assert_eq!(profile.profile_version, user.profile_version + 1);
    assert_eq!(profile.terms_version.unwrap().as_str(), "2026-07-31");
    assert!(profile.terms_accepted_at.is_some());

    assert!(matches!(
        accounts
            .update_profile(
                user_id,
                user.profile_version,
                &ProfilePatch {
                    display_name: Some(None),
                    ..ProfilePatch::default()
                },
            )
            .await
            .unwrap(),
        ProfileUpdateOutcome::VersionConflict {
            current_version
        } if current_version == user.profile_version + 1
    ));

    let second_subject = format!("second-{unique}");
    let second = accounts
        .provision_oidc_identity(&issuer, &second_subject, Duration::from_secs(15 * 60))
        .await
        .unwrap();
    assert!(matches!(
        accounts
            .update_profile(
                second.id,
                second.profile_version,
                &ProfilePatch {
                    handle: Some(Handle::parse("ADA_ACCOUNT").unwrap()),
                    ..ProfilePatch::default()
                },
            )
            .await
            .unwrap(),
        ProfileUpdateOutcome::HandleUnavailable
    ));

    sqlx::query("UPDATE users SET status = 'suspended' WHERE id = $1")
        .bind(user_id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let reprovisioned = accounts
        .provision_oidc_identity(&issuer, &subject, Duration::from_secs(15 * 60))
        .await
        .unwrap();
    assert_eq!(reprovisioned.status, AccountStatus::Suspended);
    assert_eq!(reprovisioned.id, user_id);

    // Separate repository values model independent API replicas while sharing
    // the same PostgreSQL source of truth.
    let limiter_a = database.rate_limits();
    let limiter_b = Database::from_pool(database.pool().clone()).rate_limits();
    let bucket = format!("profile_test_{unique}");
    let scope = format!("user:{user_id}");
    let rule =
        RateLimitRequest::new(bucket.clone(), scope.clone(), 3, Duration::from_secs(60)).unwrap();
    assert!(limiter_a.check(&rule).await.unwrap().allowed);
    assert!(limiter_b.check(&rule).await.unwrap().allowed);
    let third = limiter_a.check(&rule).await.unwrap();
    assert!(third.allowed);
    assert_eq!(third.remaining, 0);
    let denied = limiter_b.check(&rule).await.unwrap();
    assert!(!denied.allowed);
    assert!(
        denied
            .retry_after_seconds
            .is_some_and(|seconds| seconds >= 1)
    );

    sqlx::query("DELETE FROM shared_rate_limit_buckets WHERE bucket = $1 AND scope_key = $2")
        .bind(bucket)
        .bind(scope)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(issuer)
        .execute(database.pool())
        .await
        .unwrap();
}
