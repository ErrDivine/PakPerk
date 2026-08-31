use std::{sync::Arc, time::Duration};

use arxiv_client::ArxivError;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use db::Database;
use domain::{ArxivIdentifier, Author, LibraryState, PaperMetadata};
use library::{LibraryPolicy, LibraryService};
use paper_resolution::{
    PaperImportService, PaperInputKind, PaperMetadataSource, PaperResolutionService,
};
use url::Url;
use uuid::Uuid;

struct NoNetwork;

#[async_trait]
impl PaperMetadataSource for NoNetwork {
    async fn fetch_by_id(&self, _arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError> {
        panic!("a cached exact import must not call arXiv")
    }

    async fn search_by_title(
        &self,
        _normalized_title: &str,
        _limit: usize,
    ) -> Result<Vec<PaperMetadata>, ArxivError> {
        panic!("an exact import must not invoke title search")
    }
}

type ProcessingState = (i32, String, bool, bool, bool, bool, DateTime<Utc>);

#[tokio::test]
async fn postgres_cached_import_is_idempotent_and_leaves_preparation_untouched() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL import preparation coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let user = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://paper-import-no-preparation.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let suffix = 10_000 + (Uuid::now_v7().as_u128() % 80_000) as u32;
    let metadata = metadata(&format!("2608.{suffix:05}"));
    let paper = database.papers().upsert_metadata(&metadata).await.unwrap();
    let before = processing_state(&database, paper.id).await;
    assert_eq!(before.1, "not_requested");
    assert_eq!(job_count(&database, paper.id).await, 0);

    let resolution = PaperResolutionService::with_dependencies(
        Arc::new(database.papers()),
        Arc::new(NoNetwork),
        Duration::from_secs(3),
        Duration::from_secs(86_400),
    );
    let library = LibraryService::new(
        database.library(),
        database.rate_limits(),
        LibraryPolicy::new(120, Duration::from_secs(3_600)).unwrap(),
    );
    let imports = PaperImportService::new(
        resolution,
        database.paper_imports(),
        library,
        database.rate_limits(),
        20,
    );
    let operation_id = Uuid::now_v7();
    let first = imports
        .import(
            user.id,
            operation_id,
            PaperInputKind::ArxivId,
            &metadata.arxiv_id.base_id,
        )
        .await
        .unwrap();
    let replay = imports
        .import(
            user.id,
            operation_id,
            PaperInputKind::ArxivId,
            &metadata.arxiv_id.base_id,
        )
        .await
        .unwrap();

    assert_eq!(first.paper.paper_id, paper.id);
    assert_eq!(first.item.state, LibraryState::Inbox);
    assert!(!first.replayed);
    assert!(replay.replayed);
    assert_eq!(replay.item, first.item);
    assert_eq!(processing_state(&database, paper.id).await, before);
    assert_eq!(job_count(&database, paper.id).await, 0);
    let persisted: (i64, i64) = sqlx::query_as(
        r"
        SELECT
          (SELECT count(*) FROM user_paper_library
           WHERE user_id = $1 AND paper_id = $2 AND state = 'to_read'
             AND removed_at IS NULL)::bigint,
          (SELECT count(*) FROM paper_import_operations
           WHERE user_id = $1 AND operation_id = $3 AND status = 'completed')::bigint
        ",
    )
    .bind(user.id.into_inner())
    .bind(paper.id)
    .bind(operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(persisted, (1, 1));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

async fn processing_state(database: &Database, paper_id: Uuid) -> ProcessingState {
    sqlx::query_as(
        r"
        SELECT generation, stage, metadata_ready, introduction_ready,
               chat_ready, connections_ready, updated_at
        FROM paper_processing
        WHERE paper_id = $1
        ",
    )
    .bind(paper_id)
    .fetch_one(database.pool())
    .await
    .unwrap()
}

async fn job_count(database: &Database, paper_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM jobs WHERE paper_id = $1")
        .bind(paper_id)
        .fetch_one(database.pool())
        .await
        .unwrap()
}

fn metadata(base_id: &str) -> PaperMetadata {
    let now = Utc::now();
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Cached exact import without preparation".to_owned(),
        abstract_text: "Bounded metadata used to prove that import has no preparation side effect."
            .to_owned(),
        authors: vec![Author::from("Ada Reader".to_owned())],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
        published_at: now,
        updated_at: now,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: None,
        metadata_fetched_at: now,
    }
}
