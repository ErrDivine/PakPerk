use std::{sync::Arc, time::Duration};

use db::Database;
use research_profiles::{
    AuthorFollowInput, DeleteAuthorCommand, DeleteTopicCommand, DiscoveryMode,
    ExplicitCategoryInput, InterestSource, PreferredDiscoveryMode, ProfileInterests,
    ProfileSettings, ResearchProfilePolicy, ResearchProfileService, ResearchProfileServiceError,
    ResetProfileCommand, ResetScope, TopicPolarity, UpdateProfileCommand, UpsertAuthorCommand,
    UpsertTopicCommand,
};
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_profile_revision_privacy_idempotency_queue_isolation_and_deletion() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL research-profile coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let user = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://research-profile.test/{unique}"),
            &format!("subject-{unique}"),
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let topic_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO topics (
            id, canonical_key, label, normalized_label, source_vocabulary
        ) VALUES ($1, $2, 'Retrieval Augmented Generation',
                  'retrieval augmented generation', 'pakperk')
        ",
    )
    .bind(topic_id)
    .bind(format!("fixture:{unique}"))
    .execute(database.pool())
    .await
    .unwrap();

    let service = ResearchProfileService::new(
        Arc::new(database.research_profiles()),
        Arc::new(database.rate_limits()),
        ResearchProfilePolicy::default(),
    );
    let default = service.get(user.id).await.unwrap();
    assert_eq!(default.profile_revision, 0);
    assert!(!default.settings.personalization_enabled);
    assert!(default.interests.explicit.categories.is_empty());
    let queue_before = queue_authority(&database, user.id.into_inner()).await;
    let ready_batch = Uuid::now_v7();
    let building_batch = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO recommendation_batches (
            id, user_id, mode, query_key, local_date, profile_revision,
            library_revision, queue_proven_empty, algorithm_version,
            policy_version, seed, expires_at, status
        ) VALUES
          ($1, $3, 'recent', 'profile-fixture-ready', current_date, 0,
           0, true, 'profile-test-v1', 'queue-first-v1', 1,
           statement_timestamp() + interval '1 day', 'ready'),
          ($2, $3, 'explore', 'profile-fixture-building', current_date, 0,
           NULL, NULL, 'profile-test-v1', 'queue-first-v1', 2,
           statement_timestamp() + interval '1 day', 'building')
        ",
    )
    .bind(ready_batch)
    .bind(building_batch)
    .bind(user.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();

    let settings_operation = Uuid::now_v7();
    let settings = service
        .update(
            user.id,
            UpdateProfileCommand {
                expected_revision: 0,
                operation_id: settings_operation,
                personalization_enabled: Some(true),
                preferred_discovery_mode: Some(PreferredDiscoveryMode::Following),
                discovery_mode: Some(DiscoveryMode::Focused),
                brief_size: Some(18),
                explicit_categories: Some(vec![ExplicitCategoryInput {
                    category: "cs.CL".to_owned(),
                    weight: 0.8,
                }]),
                ..UpdateProfileCommand::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(settings.profile_revision, 1);
    assert!(settings.settings.personalization_enabled);
    assert_eq!(settings.interests.explicit.categories.len(), 1);
    let superseded: Vec<String> = sqlx::query_scalar(
        "SELECT status FROM recommendation_batches WHERE id = ANY($1) ORDER BY id",
    )
    .bind(vec![ready_batch, building_batch])
    .fetch_all(database.pool())
    .await
    .unwrap();
    assert_eq!(superseded, vec!["superseded", "superseded"]);

    // Exact replay neither consumes another revision nor creates a second
    // operation. A different intent with the same operation ID is rejected.
    let replay = service
        .update(
            user.id,
            UpdateProfileCommand {
                expected_revision: 0,
                operation_id: settings_operation,
                personalization_enabled: Some(true),
                preferred_discovery_mode: Some(PreferredDiscoveryMode::Following),
                discovery_mode: Some(DiscoveryMode::Focused),
                brief_size: Some(18),
                explicit_categories: Some(vec![ExplicitCategoryInput {
                    category: "cs.CL".to_owned(),
                    weight: 0.8,
                }]),
                ..UpdateProfileCommand::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(replay.profile_revision, 1);
    assert!(matches!(
        service
            .reset(
                user.id,
                ResetProfileCommand {
                    expected_revision: 1,
                    operation_id: settings_operation,
                    scope: ResetScope::All,
                },
            )
            .await,
        Err(ResearchProfileServiceError::IdempotencyConflict)
    ));

    let topic = service
        .upsert_topic(
            user.id,
            UpsertTopicCommand {
                expected_revision: 1,
                operation_id: Uuid::now_v7(),
                topic_id,
                polarity: TopicPolarity::Positive,
                strength: 0.9,
                user_alias: Some("RAG".to_owned()),
            },
        )
        .await
        .unwrap();
    assert_eq!(topic.profile_revision, 2);
    assert_eq!(topic.interests.explicit.topics.len(), 1);
    assert_eq!(
        topic.interests.explicit.topics[0].source,
        InterestSource::Explicit
    );

    let author = service
        .upsert_author(
            user.id,
            UpsertAuthorCommand {
                expected_revision: 2,
                operation_id: Uuid::now_v7(),
                author_key: "  invalid whitespace  ".to_owned(),
                display_name: "Ada Researcher".to_owned(),
            },
        )
        .await;
    assert!(matches!(
        author,
        Err(ResearchProfileServiceError::InvalidAuthorKey)
    ));
    let author = service
        .upsert_author(
            user.id,
            UpsertAuthorCommand {
                expected_revision: 2,
                operation_id: Uuid::now_v7(),
                author_key: "Ada Researcher".to_owned(),
                display_name: "Ada Researcher".to_owned(),
            },
        )
        .await
        .unwrap();
    assert_eq!(author.profile_revision, 3);
    assert_eq!(author.interests.explicit.authors.len(), 1);

    // Seed separately labelled feedback and inferred rows as internal
    // producers would. An inferred-only reset must preserve feedback, explicit
    // choices, the personalization toggle, and queue authority.
    let explanation_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO profile_categories (user_id, category, weight, source)
        VALUES ($1, 'cs.LG', 0.5, 'inferred')
        ",
    )
    .bind(user.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO profile_topics (
            user_id, topic_id, polarity, strength, source, explanation_source_id
        ) VALUES ($1, $2, 'positive', 0.4, 'inferred', $3)
        ",
    )
    .bind(user.id.into_inner())
    .bind(topic_id)
    .bind(explanation_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO profile_authors (
            user_id, author_key, display_name, source, explanation_source_id
        ) VALUES ($1, 'inferred author', 'Inferred Author', 'inferred', $2)
        ",
    )
    .bind(user.id.into_inner())
    .bind(explanation_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO profile_categories (user_id, category, weight, source)
        VALUES ($1, 'cs.IR', 0.7, 'feedback')
        ",
    )
    .bind(user.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let with_inference = service.get(user.id).await.unwrap();
    assert_eq!(with_inference.interests.inferred.categories.len(), 1);
    assert_eq!(with_inference.interests.inferred.topics.len(), 1);
    assert_eq!(with_inference.interests.inferred.authors.len(), 1);
    assert_eq!(with_inference.interests.feedback.categories.len(), 1);

    let inferred_reset = service
        .reset(
            user.id,
            ResetProfileCommand {
                expected_revision: 3,
                operation_id: Uuid::now_v7(),
                scope: ResetScope::Inferred,
            },
        )
        .await
        .unwrap();
    assert_eq!(inferred_reset.profile_revision, 4);
    assert!(inferred_reset.settings.personalization_enabled);
    assert_eq!(inferred_reset.interests.feedback.categories.len(), 1);
    assert!(inferred_reset.interests.inferred.categories.is_empty());
    assert!(inferred_reset.interests.inferred.topics.is_empty());
    assert!(inferred_reset.interests.inferred.authors.is_empty());
    assert_eq!(inferred_reset.interests.explicit.categories.len(), 1);
    assert_eq!(inferred_reset.interests.explicit.topics.len(), 1);
    assert_eq!(inferred_reset.interests.explicit.authors.len(), 1);
    assert_eq!(
        queue_authority(&database, user.id.into_inner()).await,
        queue_before
    );

    sqlx::query(
        r"
        INSERT INTO profile_categories (user_id, category, weight, source)
        VALUES ($1, 'cs.LG', 0.5, 'inferred')
        ",
    )
    .bind(user.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();

    // Disabling personalization has the broader privacy semantics: it clears
    // both feedback-derived and inferred interests but retains explicit ones.
    let disabled = service
        .update(
            user.id,
            UpdateProfileCommand {
                expected_revision: 4,
                operation_id: Uuid::now_v7(),
                personalization_enabled: Some(false),
                ..UpdateProfileCommand::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(disabled.profile_revision, 5);
    assert!(!disabled.settings.personalization_enabled);
    assert!(disabled.interests.inferred.categories.is_empty());
    assert!(disabled.interests.inferred.topics.is_empty());
    assert!(disabled.interests.inferred.authors.is_empty());
    assert!(disabled.interests.feedback.categories.is_empty());
    assert_eq!(disabled.interests.explicit.categories.len(), 1);
    assert_eq!(disabled.interests.explicit.topics.len(), 1);
    assert_eq!(disabled.interests.explicit.authors.len(), 1);
    assert_eq!(
        queue_authority(&database, user.id.into_inner()).await,
        queue_before
    );

    assert!(matches!(
        service
            .delete_topic(
                user.id,
                DeleteTopicCommand {
                    expected_revision: 4,
                    operation_id: Uuid::now_v7(),
                    topic_id,
                },
            )
            .await,
        Err(ResearchProfileServiceError::RevisionConflict {
            current_revision: 5
        })
    ));
    let after_topic_delete = service
        .delete_topic(
            user.id,
            DeleteTopicCommand {
                expected_revision: 5,
                operation_id: Uuid::now_v7(),
                topic_id,
            },
        )
        .await
        .unwrap();
    let after_author_delete = service
        .delete_author(
            user.id,
            DeleteAuthorCommand {
                expected_revision: after_topic_delete.profile_revision,
                operation_id: Uuid::now_v7(),
                author_key: "Ada Researcher".to_owned(),
            },
        )
        .await
        .unwrap();
    assert!(after_author_delete.interests.explicit.topics.is_empty());
    assert!(after_author_delete.interests.explicit.authors.is_empty());
    let reset = service
        .reset(
            user.id,
            ResetProfileCommand {
                expected_revision: after_author_delete.profile_revision,
                operation_id: Uuid::now_v7(),
                scope: ResetScope::All,
            },
        )
        .await
        .unwrap();
    assert_eq!(reset.settings, ProfileSettings::default());
    assert_eq!(reset.interests, ProfileInterests::default());
    let retained_batches: i64 =
        sqlx::query_scalar("SELECT count(*) FROM recommendation_batches WHERE user_id = $1")
            .bind(user.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(
        retained_batches, 0,
        "a complete profile reset purges batches"
    );
    assert_eq!(
        queue_authority(&database, user.id.into_inner()).await,
        queue_before
    );

    sqlx::query(
        "UPDATE research_profile_operations SET expires_at = statement_timestamp() - interval '1 second' WHERE user_id = $1",
    )
    .bind(user.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    assert!(service.cleanup_operations(1_000).await.unwrap() > 0);

    // Account deletion's app purge deletes users under a lock. Cascading the
    // same row proves no profile, interest, or idempotency record can survive.
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let account_rows: (i64, i64, i64, i64, i64) = sqlx::query_as(
        r"
        SELECT
          (SELECT count(*) FROM research_profiles WHERE user_id = $1)::bigint,
          (SELECT count(*) FROM profile_categories WHERE user_id = $1)::bigint,
          (SELECT count(*) FROM profile_topics WHERE user_id = $1)::bigint,
          (SELECT count(*) FROM profile_authors WHERE user_id = $1)::bigint,
          (SELECT count(*) FROM research_profile_operations WHERE user_id = $1)::bigint
        ",
    )
    .bind(user.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(account_rows, (0, 0, 0, 0, 0));
    let topic_survives: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM topics WHERE id = $1)")
            .bind(topic_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert!(
        topic_survives,
        "canonical topic vocabulary is not account data"
    );
    sqlx::query("DELETE FROM topics WHERE id = $1")
        .bind(topic_id)
        .execute(database.pool())
        .await
        .unwrap();
}

async fn queue_authority(database: &Database, user_id: Uuid) -> (i64, i64) {
    sqlx::query_as(
        r"
        SELECT
            COALESCE((
                SELECT current_revision FROM library_sync_metadata WHERE user_id = $1
            ), 0)::bigint,
            (SELECT count(*) FROM user_paper_library
             WHERE user_id = $1
               AND removed_at IS NULL
               AND state IN ('to_read', 'inbox', 'read_next', 'reading'))::bigint
        ",
    )
    .bind(user_id)
    .fetch_one(database.pool())
    .await
    .unwrap()
}

#[test]
fn phase_c_store_inputs_cannot_express_queue_mutations() {
    // Compile-time contract: profile authors are normalized labels only, and
    // profile mutations have no paper, library state, or library revision.
    let input = AuthorFollowInput {
        author_key: "ada researcher".to_owned(),
        display_name: "Ada Researcher".to_owned(),
    };
    assert_eq!(input.author_key, "ada researcher");
}
