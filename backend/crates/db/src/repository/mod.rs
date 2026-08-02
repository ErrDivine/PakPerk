use std::{
    collections::HashMap,
    path::Path,
    sync::OnceLock,
    time::{Duration, Instant},
};

use chrono::{DateTime, Utc};
use domain::{
    ArxivIdentifier, Author, Capabilities, ChatAnswer, ChatRole, ChatTurn, ConnectionReference,
    ConnectionsResponse, FailureCategory, FeedPage, Introduction, IntroductionCitation,
    IntroductionCitationReference, IntroductionDetection, IntroductionParagraph, KeyConnection,
    OverallProcessingState, Paper, PaperId, PaperMetadata, PaperSummary, ParsedPaper,
    ProcessingError, ProcessingGeneration, ProcessingStage, ProcessingState,
    ReferenceResolutionStatus, RelationType, SectionKind,
};
use jobs::JobKind;
use opaque_cursor::OpaqueCursorCodec;
use pgvector::Vector;
use regex::Regex;
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction, postgres::PgPoolOptions};
use thiserror::Error;
use tracing::{debug, info, instrument};
use url::Url;
use uuid::Uuid;

use crate::{CursorError, FeedCursor};

mod account_deletion;
mod accounts;
mod chat;
mod comments;
mod library;
mod moderation;
mod papers;
mod rate_limits;
mod rows;

pub use account_deletion::{
    AccountDeletionFailure, AccountDeletionRepository, AccountDeletionRequest,
    AccountDeletionRequestOutcome, ClaimedAccountDeletion, DeletionLedgerRecord,
    DeletionReapplyAction, DeletionReapplyOutcome, ExternalLedgerPurgeAuthorization,
    ExternalLedgerPurgeAuthorizationState, StoredAccountDeletionBacklogMetrics,
    StoredAccountDeletionStatus, StoredDeletionIdentityVerification,
};
pub use accounts::{AccountRepository, ProfilePatch, ProfileUpdateOutcome};
pub use comments::{
    CommentCreateOutcome, CommentCreatePrecondition, CommentCreateResolution,
    CommentDeleteResolution, CommentEditResolution, CommentMutationOutcome, CommentReadOutcome,
    CommentReportOutcome, CommentReportResolution, CommentRepository, CommentWriteGuard,
    StoredReport, StoredUserReport, UserBlockOutcome, UserBlockResolution, UserReportOutcome,
    UserReportResolution, UserUnblockResolution,
};
pub use library::{
    LibraryChangesOutcome, LibraryMutationIntent, LibraryMutationOutcome,
    LibraryOperationResolution, LibraryReadOutcome, LibraryRepository, StoredLibraryChangesPage,
    StoredLibraryPage,
};
pub use moderation::{
    AdminCommentAction, AdminCommentOutcome, AdminReportOutcome, AdminReportResolution,
    AdminUserStatusOutcome, ModerationRepository, StoredAdminActor, StoredInspectionReport,
    StoredModerationInspection, StoredModerationQueuePage, StoredModerationQueueRecord,
    StoredReportAgeMetrics, StoredReportQueuePage, StoredReportQueueRecord,
    StoredUserReportInspection, StoredUserReportQueuePage, StoredUserReportQueueRecord,
};
pub use rate_limits::{
    RateLimitConfigError, RateLimitDecision, RateLimitRepository, RateLimitRequest,
};

use rows::{
    CapabilityToPublish, CapabilityTransition, ChatTurnRow, CitationContextRow,
    ConnectionReferenceRow, IntroductionHeaderRow, IntroductionResolvedReferenceRow,
    IntroductionSectionRow, KeyConnectionRow, LicenseUriRow, PAPER_SELECT_BY_ARXIV,
    PAPER_SELECT_BY_ID, PAPER_SUMMARY_BY_ID, PROCESSING_SELECT, PaperRow, PaperSummaryRow,
    ProcessingRow, ReferenceRow, RetrievalRow, StoredSectionRow, TitleCandidateRow,
    build_introduction_content, failure_category_name, i64_to_usize, lock_current_generation,
    observe_capability_transition, option_u32_to_i32, processing_stage_name, publish_capability,
    reference_status_name, relation_type_name, require_current_generation, section_kind_name,
    usize_to_i32,
};
#[cfg(test)]
use rows::{decode_authors, legacy_numeric_citations, parse_processing_stage, parse_section_kind};

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");
const REQUIRED_POSTGRES_EXTENSIONS: [&str; 3] = ["vector", "pg_trgm", "pgcrypto"];

fn latest_embedded_migration_version() -> Result<i64, DbError> {
    MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .max()
        .ok_or_else(|| DbError::InvalidData("no database migrations are embedded".to_owned()))
}

#[derive(Debug, Clone, FromRow)]
struct AppliedSchemaMigration {
    version: i64,
    success: bool,
    checksum: Vec<u8>,
}

fn validate_schema_migration_readiness(
    applied_migrations: &[AppliedSchemaMigration],
    latest_successful_version: Option<i64>,
    minimum_version: i64,
) -> Result<(), DbError> {
    if applied_migrations
        .iter()
        .any(|migration| !migration.success)
    {
        return Err(DbError::InvalidData(
            "database migration history contains an unsuccessful migration".to_owned(),
        ));
    }
    if latest_successful_version.is_none_or(|version| version < minimum_version) {
        return Err(DbError::InvalidData(
            "database schema is older than this binary; apply database migrations".to_owned(),
        ));
    }
    for embedded in MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
    {
        let Some(applied) = applied_migrations
            .iter()
            .find(|migration| migration.version == embedded.version)
        else {
            return Err(DbError::InvalidData(
                "database migration history is incomplete; apply database migrations".to_owned(),
            ));
        };
        if applied.checksum.as_slice() != embedded.checksum.as_ref() {
            return Err(DbError::InvalidData(format!(
                "database migration {} checksum does not match this binary",
                embedded.version
            )));
        }
    }
    Ok(())
}

fn validate_required_extension_readiness(
    installed_extensions: &[(String, String)],
) -> Result<(), DbError> {
    for required_extension in REQUIRED_POSTGRES_EXTENSIONS {
        let mut matching_extensions = installed_extensions
            .iter()
            .filter(|(extension, _)| extension == required_extension);
        let exactly_once_in_public = matching_extensions
            .next()
            .is_some_and(|(_, namespace)| namespace == "public")
            && matching_extensions.next().is_none();
        if !exactly_once_in_public {
            return Err(DbError::InvalidData(format!(
                "required PostgreSQL extension {required_extension} must be installed exactly once in public"
            )));
        }
    }
    Ok(())
}

#[derive(Debug, Error)]
pub enum DbError {
    #[error("database operation failed")]
    Sql(#[from] sqlx::Error),
    #[error("database migration failed")]
    Migration(#[from] sqlx::migrate::MigrateError),
    #[error("persisted URL is invalid")]
    InvalidUrl(#[from] url::ParseError),
    #[error("persisted data is invalid: {0}")]
    InvalidData(String),
    #[error("cursor operation failed")]
    Cursor(#[from] CursorError),
    #[error("paper generation changed while work was in progress")]
    StaleGeneration,
    #[error("requested chat thread is not owned by this session and paper")]
    InvalidChatThread,
    #[error("verified identity has a durable account-deletion tombstone")]
    IdentityTombstoned,
}

#[derive(Clone)]
pub struct Database {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

impl Database {
    pub async fn connect(database_url: &str, max_connections: u32) -> Result<Self, DbError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections.max(1))
            .min_connections(1)
            .acquire_timeout(Duration::from_secs(10))
            .idle_timeout(Duration::from_secs(300))
            .after_connect(|connection, _metadata| {
                Box::pin(async move {
                    // URL-level `options` can set a hostile startup path. Reset
                    // and verify every physical connection before the pool can
                    // hand it to migrations, restore replay, or application
                    // repositories.
                    sqlx::query("SET search_path TO public, pg_catalog")
                        .execute(&mut *connection)
                        .await?;
                    let (search_path, current_schema): (String, Option<String>) = sqlx::query_as(
                        r"
                            SELECT
                                pg_catalog.current_setting('search_path'),
                                pg_catalog.current_schema()::text
                            ",
                    )
                    .fetch_one(&mut *connection)
                    .await?;
                    if search_path != "public, pg_catalog"
                        || current_schema.as_deref() != Some("public")
                    {
                        return Err(sqlx::Error::Protocol(
                            "database search_path could not be bound to public, pg_catalog"
                                .to_owned(),
                        ));
                    }
                    Ok(())
                })
            })
            .connect(database_url)
            .await?;
        Ok(Self {
            pool,
            cursor_codec: None,
        })
    }

    #[must_use]
    pub const fn from_pool(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    /// Installs the deployment-shared rotating cursor keyring. Cursor-bearing
    /// operations fail closed until application composition supplies it.
    #[must_use]
    pub fn with_cursor_codec(mut self, cursor_codec: OpaqueCursorCodec) -> Self {
        self.cursor_codec = Some(cursor_codec);
        self
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn migrate(&self, migration_path: impl AsRef<Path>) -> Result<(), DbError> {
        let migrator = sqlx::migrate::Migrator::new(migration_path.as_ref()).await?;
        migrator.run(&self.pool).await?;
        Ok(())
    }

    /// Runs migrations embedded in the binary at compile time. Runtime
    /// containers therefore do not need the source migration directory.
    pub async fn migrate_embedded(&self) -> Result<(), DbError> {
        MIGRATOR.run(&self.pool).await?;
        Ok(())
    }

    pub async fn ready(&self) -> Result<(), DbError> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        let minimum_version = latest_embedded_migration_version()?;
        let applied_migrations = sqlx::query_as::<_, AppliedSchemaMigration>(
            r"
            SELECT version, success, checksum
            FROM public._sqlx_migrations
            ORDER BY version
            ",
        )
        .fetch_all(&self.pool)
        .await?;
        let latest_successful_version = applied_migrations
            .iter()
            .filter(|migration| migration.success)
            .map(|migration| migration.version)
            .max();
        // A newer schema remains acceptable during expand/contract rollouts,
        // but this binary must never serve against an older, dirty, gapped, or
        // checksum-divergent schema.
        validate_schema_migration_readiness(
            &applied_migrations,
            latest_successful_version,
            minimum_version,
        )?;
        // Fail startup/readiness unless every required extension resolves from
        // the application-owned public schema. Name-only presence is not
        // enough because repositories deliberately call public.digest and
        // otherwise rely on public-qualified extension objects.
        let installed_extensions = sqlx::query_as::<_, (String, String)>(
            r"
            SELECT extension.extname, namespace.nspname
            FROM pg_catalog.pg_extension AS extension
            JOIN pg_catalog.pg_namespace AS namespace
              ON namespace.oid = extension.extnamespace
            WHERE extension.extname IN ('vector', 'pg_trgm', 'pgcrypto')
            ORDER BY extension.extname
            ",
        )
        .fetch_all(&self.pool)
        .await?;
        validate_required_extension_readiness(&installed_extensions)?;
        let arxiv_gate_ready: bool = sqlx::query_scalar(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'external_rate_limits'
                  AND column_name = 'blocked_until'
            ) AND EXISTS (
                SELECT 1
                FROM public.external_rate_limits
                WHERE service = 'arxiv'
            )
            ",
        )
        .fetch_one(&self.pool)
        .await?;
        if !arxiv_gate_ready {
            return Err(DbError::InvalidData(
                "shared arXiv rate-limit schema is missing; apply database migrations".to_owned(),
            ));
        }
        Ok(())
    }

    #[must_use]
    pub fn papers(&self) -> PaperRepository {
        PaperRepository::with_cursor_codec(self.pool.clone(), self.cursor_codec.clone())
    }

    #[must_use]
    pub fn accounts(&self) -> AccountRepository {
        AccountRepository::new(self.pool.clone())
    }

    #[must_use]
    pub fn account_deletions(&self) -> AccountDeletionRepository {
        AccountDeletionRepository::new(self.pool.clone())
    }

    #[must_use]
    pub fn library(&self) -> LibraryRepository {
        LibraryRepository::with_cursor_codec(self.pool.clone(), self.cursor_codec.clone())
    }

    #[must_use]
    pub fn comments(&self) -> CommentRepository {
        CommentRepository::with_cursor_codec(self.pool.clone(), self.cursor_codec.clone())
    }

    #[must_use]
    pub fn moderation(&self) -> ModerationRepository {
        ModerationRepository::with_cursor_codec(self.pool.clone(), self.cursor_codec.clone())
    }

    #[must_use]
    pub fn rate_limits(&self) -> RateLimitRepository {
        RateLimitRepository::new(self.pool.clone())
    }
}

#[derive(Debug, Clone)]
pub struct FeedQuery {
    pub category: Option<String>,
    pub cursor: Option<FeedCursor>,
    pub limit: u32,
}

impl Default for FeedQuery {
    fn default() -> Self {
        Self {
            category: None,
            cursor: None,
            limit: 20,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PrepareResult {
    pub state: ProcessingState,
    pub enqueued: bool,
}

#[derive(Debug, Clone)]
pub struct StoredSection {
    pub id: Uuid,
    pub kind: SectionKind,
    pub heading: Option<String>,
    pub text: String,
    pub paragraphs: Vec<domain::ParsedParagraph>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub ordinal: usize,
}

#[derive(Debug, Clone)]
pub struct RetrievalCandidate {
    pub chunk: domain::Chunk,
    /// Rank within this retrieval method, starting at one.
    pub rank: usize,
}

#[derive(Debug, Clone)]
pub struct TitleCandidate {
    pub paper: Paper,
    pub similarity: f32,
}

#[derive(Debug, Clone)]
pub struct ChatSession {
    pub thread_id: Uuid,
    pub recent_turns: Vec<ChatTurn>,
}

#[derive(Debug, Clone)]
pub struct VerificationMetrics {
    pub paper: Paper,
    pub processing: ProcessingState,
    pub introduction_paragraph_count: usize,
    pub chat_chunk_count: usize,
    pub resolved_reference_count: usize,
    pub key_connection_count: usize,
    pub resolved_arxiv_base_ids: Vec<String>,
    pub relationship_prompt_versions: Vec<String>,
}

#[derive(Clone)]
pub struct PaperRepository {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

impl PaperRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    fn with_cursor_codec(pool: PgPool, cursor_codec: Option<OpaqueCursorCodec>) -> Self {
        Self { pool, cursor_codec }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub fn decode_feed_cursor(
        &self,
        category: Option<&str>,
        value: &str,
    ) -> Result<FeedCursor, CursorError> {
        let codec = self.cursor_codec.as_ref().ok_or(CursorError::Unavailable)?;
        FeedCursor::decode(codec, category, value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn embedded_migration_history() -> Vec<AppliedSchemaMigration> {
        MIGRATOR
            .iter()
            .filter(|migration| migration.migration_type.is_up_migration())
            .map(|migration| AppliedSchemaMigration {
                version: migration.version,
                success: true,
                checksum: migration.checksum.to_vec(),
            })
            .collect()
    }

    fn latest_successful_version(applied_migrations: &[AppliedSchemaMigration]) -> Option<i64> {
        applied_migrations
            .iter()
            .filter(|migration| migration.success)
            .map(|migration| migration.version)
            .max()
    }

    fn validate_test_migration_history(
        applied_migrations: &[AppliedSchemaMigration],
    ) -> Result<(), DbError> {
        validate_schema_migration_readiness(
            applied_migrations,
            latest_successful_version(applied_migrations),
            latest_embedded_migration_version().unwrap(),
        )
    }

    fn required_extensions_in_public() -> Vec<(String, String)> {
        REQUIRED_POSTGRES_EXTENSIONS
            .into_iter()
            .map(|extension| (extension.to_owned(), "public".to_owned()))
            .collect()
    }

    #[test]
    fn database_readiness_rejects_an_old_schema() {
        let minimum_version = latest_embedded_migration_version().unwrap();
        let mut applied_migrations = embedded_migration_history();
        applied_migrations.retain(|migration| migration.version != minimum_version);
        let error = validate_test_migration_history(&applied_migrations).unwrap_err();

        assert_eq!(
            error.to_string(),
            "persisted data is invalid: database schema is older than this binary; apply database migrations",
        );
    }

    #[test]
    fn database_readiness_rejects_absent_migration_history() {
        let error = validate_test_migration_history(&[]).unwrap_err();

        assert_eq!(
            error.to_string(),
            "persisted data is invalid: database schema is older than this binary; apply database migrations",
        );
    }

    #[test]
    fn database_readiness_rejects_an_unsuccessful_migration() {
        let minimum_version = latest_embedded_migration_version().unwrap();
        let mut applied_migrations = embedded_migration_history();
        applied_migrations
            .iter_mut()
            .find(|migration| migration.version == minimum_version)
            .unwrap()
            .success = false;
        let error = validate_test_migration_history(&applied_migrations).unwrap_err();

        assert_eq!(
            error.to_string(),
            "persisted data is invalid: database migration history contains an unsuccessful migration",
        );
    }

    #[test]
    fn database_readiness_accepts_the_current_schema() {
        validate_test_migration_history(&embedded_migration_history()).unwrap();
    }

    #[test]
    fn database_readiness_accepts_a_future_schema_for_rollouts() {
        let minimum_version = latest_embedded_migration_version().unwrap();
        let future_version = minimum_version.checked_add(1).unwrap();
        let mut applied_migrations = embedded_migration_history();
        applied_migrations.push(AppliedSchemaMigration {
            version: future_version,
            success: true,
            checksum: vec![0x42; 48],
        });

        validate_test_migration_history(&applied_migrations).unwrap();
    }

    #[test]
    fn database_readiness_rejects_a_gapped_history_with_a_future_version() {
        let minimum_version = latest_embedded_migration_version().unwrap();
        let future_version = minimum_version.checked_add(1).unwrap();
        let mut applied_migrations = embedded_migration_history();
        applied_migrations.retain(|migration| migration.version != minimum_version);
        applied_migrations.push(AppliedSchemaMigration {
            version: future_version,
            success: true,
            checksum: vec![0x42; 48],
        });
        let error = validate_test_migration_history(&applied_migrations).unwrap_err();

        assert_eq!(
            error.to_string(),
            "persisted data is invalid: database migration history is incomplete; apply database migrations",
        );
    }

    #[test]
    fn database_readiness_rejects_checksum_drift() {
        let mut applied_migrations = embedded_migration_history();
        applied_migrations[0].checksum[0] ^= 0xff;
        let divergent_version = applied_migrations[0].version;
        let error = validate_test_migration_history(&applied_migrations).unwrap_err();

        assert_eq!(
            error.to_string(),
            format!(
                "persisted data is invalid: database migration {divergent_version} checksum does not match this binary"
            ),
        );
    }

    #[test]
    fn database_readiness_accepts_required_extensions_exactly_once_in_public() {
        validate_required_extension_readiness(&required_extensions_in_public()).unwrap();
    }

    #[test]
    fn database_readiness_rejects_missing_duplicate_or_wrong_namespace_extensions() {
        let mut missing = required_extensions_in_public();
        missing.retain(|(extension, _)| extension != "pgcrypto");
        let missing_error = validate_required_extension_readiness(&missing).unwrap_err();
        assert_eq!(
            missing_error.to_string(),
            "persisted data is invalid: required PostgreSQL extension pgcrypto must be installed exactly once in public",
        );

        let mut duplicated = required_extensions_in_public();
        duplicated.push(("vector".to_owned(), "public".to_owned()));
        let duplicate_error = validate_required_extension_readiness(&duplicated).unwrap_err();
        assert_eq!(
            duplicate_error.to_string(),
            "persisted data is invalid: required PostgreSQL extension vector must be installed exactly once in public",
        );

        for extension in REQUIRED_POSTGRES_EXTENSIONS {
            let mut wrong_namespace = required_extensions_in_public();
            wrong_namespace
                .iter_mut()
                .find(|(installed, _)| installed == extension)
                .unwrap()
                .1 = "extensions".to_owned();
            let error = validate_required_extension_readiness(&wrong_namespace).unwrap_err();
            assert_eq!(
                error.to_string(),
                format!(
                    "persisted data is invalid: required PostgreSQL extension {extension} must be installed exactly once in public"
                ),
            );
        }
    }

    #[test]
    fn enums_round_trip_database_names() {
        for stage in [
            ProcessingStage::NotRequested,
            ProcessingStage::Queued,
            ProcessingStage::FetchingLicense,
            ProcessingStage::FetchingPdf,
            ProcessingStage::ParsingPdf,
            ProcessingStage::IntroductionReady,
            ProcessingStage::IndexingChat,
            ProcessingStage::ResolvingReferences,
            ProcessingStage::Ready,
            ProcessingStage::FailedRetryable,
            ProcessingStage::FailedTerminal,
        ] {
            assert_eq!(
                parse_processing_stage(processing_stage_name(stage)).unwrap(),
                stage
            );
        }
        for kind in [
            SectionKind::Abstract,
            SectionKind::Introduction,
            SectionKind::Background,
            SectionKind::RelatedWork,
            SectionKind::Method,
            SectionKind::Experiment,
            SectionKind::Result,
            SectionKind::Discussion,
            SectionKind::Limitation,
            SectionKind::Conclusion,
            SectionKind::Appendix,
            SectionKind::Acknowledgment,
            SectionKind::References,
            SectionKind::Other,
        ] {
            assert_eq!(parse_section_kind(section_kind_name(kind)).unwrap(), kind);
        }
    }

    #[test]
    fn author_decoder_accepts_current_and_legacy_shapes() {
        let current = serde_json::json!([{"name": "Ada"}, {"name": "Grace"}]);
        let legacy = serde_json::json!(["Ada", "Grace"]);
        assert_eq!(
            decode_authors(current).unwrap(),
            decode_authors(legacy).unwrap()
        );
    }

    #[test]
    fn introduction_content_keeps_nested_headings_and_links_only_resolved_markers() {
        let resolved_paper_id = Uuid::new_v4();
        let rows = vec![
            IntroductionSectionRow {
                heading: Some("1 Introduction".to_owned()),
                paragraphs: serde_json::json!([{
                    "ordinal": 0,
                    "text": "Préface cites [1] and [2].",
                    "citations": [
                        {
                            "start": 14,
                            "end": 17,
                            "marker": "[1]",
                            "reference_ordinals": [0]
                        },
                        {
                            "start": 22,
                            "end": 25,
                            "marker": "[2]",
                            "reference_ordinals": [1]
                        }
                    ],
                    "page_start": 1,
                    "page_end": 1
                }]),
                detection_confidence: Some(0.99),
            },
            IntroductionSectionRow {
                heading: Some("1.1 Motivation".to_owned()),
                // This legacy paragraph shape deliberately lacks `citations`.
                paragraphs: serde_json::json!([{
                    "ordinal": 0,
                    "text": "A nested subsection remains readable.",
                    "page_start": 2,
                    "page_end": 2
                }]),
                detection_confidence: Some(0.99),
            },
        ];
        let resolved = vec![IntroductionResolvedReferenceRow {
            ordinal: 0,
            paper_id: resolved_paper_id,
            title: "Resolved work".to_owned(),
            context_text: None,
        }];

        let (heading, confidence, paragraphs) = build_introduction_content(rows, resolved).unwrap();

        assert_eq!(heading.as_deref(), Some("1 Introduction"));
        assert!((confidence - 0.99).abs() < f32::EPSILON);
        assert_eq!(paragraphs[0].citations.len(), 1);
        assert_eq!(paragraphs[0].citations[0].marker, "[1]");
        assert_eq!(
            paragraphs[0].citations[0].references[0].paper_id,
            resolved_paper_id
        );
        assert!(paragraphs[0].text.contains("[2]"));
        assert_eq!(paragraphs[1].heading.as_deref(), Some("1.1 Motivation"));
        assert!(paragraphs[1].citations.is_empty());
    }

    #[test]
    fn legacy_numeric_citations_handle_unicode_lists_ranges_and_unresolved_markers() {
        let resolved_references = [0usize, 1, 2, 3, 4, 11]
            .into_iter()
            .map(|ordinal| {
                (
                    ordinal,
                    IntroductionCitationReference {
                        paper_id: Uuid::new_v4(),
                        title: format!("Resolved reference {}", ordinal + 1),
                    },
                )
            })
            .collect::<HashMap<_, _>>();
        let legacy_contexts = HashMap::from([
            (0, vec!["combines [1, 3]".to_owned()]),
            (1, vec!["a context for another marker [9]".to_owned()]),
            (
                2,
                vec!["combines [1, 3]".to_owned(), "spans [2–4]".to_owned()],
            ),
            (3, vec!["spans [2–4]".to_owned()]),
            (4, vec!["spans [2–4]".to_owned()]),
            (11, vec!["Résumé cites [12]".to_owned()]),
        ]);
        let text = "Résumé cites [12], combines [1, 3], spans [2–4], and leaves [5] unresolved.";

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert_eq!(
            citations
                .iter()
                .map(|citation| citation.marker.as_str())
                .collect::<Vec<_>>(),
            ["[12]", "[1, 3]", "[2–4]"]
        );
        assert_eq!(citations[0].references.len(), 1);
        assert_eq!(citations[1].references.len(), 2);
        assert_eq!(citations[2].references.len(), 3);
        for citation in &citations {
            assert_eq!(
                text.chars()
                    .skip(citation.start)
                    .take(citation.end - citation.start)
                    .collect::<String>(),
                citation.marker
            );
        }
        assert!(text.contains("[5]"));
        assert!(citations.iter().all(|citation| citation.marker != "[5]"));
    }

    #[test]
    fn context_backed_legacy_mapping_ignores_spurious_self_entry_offset() {
        let wrong_paper_id = Uuid::new_v4();
        let correct_paper_id = Uuid::new_v4();
        let resolved_references = HashMap::from([
            (
                6,
                IntroductionCitationReference {
                    paper_id: wrong_paper_id,
                    title: "Xception".to_owned(),
                },
            ),
            (
                7,
                IntroductionCitationReference {
                    paper_id: correct_paper_id,
                    title: "The actual seventh citation".to_owned(),
                },
            ),
        ]);
        let legacy_contexts = HashMap::from([
            (
                6,
                vec!["A spurious self-entry belongs to a different context [1].".to_owned()],
            ),
            (
                7,
                vec!["The model follows [7] for sequence transduction.".to_owned()],
            ),
        ]);
        let text = "The model follows [7] for sequence transduction.";

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert_eq!(citations.len(), 1);
        assert_eq!(citations[0].marker, "[7]");
        assert_eq!(citations[0].references[0].paper_id, correct_paper_id);
        assert_ne!(citations[0].references[0].paper_id, wrong_paper_id);
    }

    #[test]
    fn legacy_numeric_citations_reject_ambiguous_or_partial_markers() {
        let first = IntroductionCitationReference {
            paper_id: Uuid::new_v4(),
            title: "Ordinal zero".to_owned(),
        };
        let second = IntroductionCitationReference {
            paper_id: Uuid::new_v4(),
            title: "Ordinal one".to_owned(),
        };
        let resolved_references = HashMap::from([(0, first), (1, second)]);
        let text = "Ambiguous [1]; partial [1, 2]; malformed [2–1], [1,,2], and [[1]].";
        let legacy_contexts = HashMap::from([
            (
                0,
                vec!["Ambiguous [1]".to_owned(), "partial [1, 2]".to_owned()],
            ),
            (1, vec!["Ambiguous [1]".to_owned()]),
        ]);

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert!(citations.is_empty());
    }

    #[test]
    fn processing_rows_reject_out_of_order_capability_publication() {
        let invalid = processing_row("indexing_chat", false, true, false);
        assert!(matches!(
            ProcessingState::try_from(invalid),
            Err(DbError::InvalidData(message)) if message.contains("publication order")
        ));

        let valid = processing_row("resolving_references", true, true, false);
        let state = ProcessingState::try_from(valid).unwrap();
        assert!(state.capabilities.introduction);
        assert!(state.capabilities.chat);
        assert!(!state.capabilities.connections);
    }

    fn processing_row(
        stage: &str,
        introduction_ready: bool,
        chat_ready: bool,
        connections_ready: bool,
    ) -> ProcessingRow {
        ProcessingRow {
            paper_id: Uuid::new_v4(),
            generation: 1,
            stage: stage.to_owned(),
            metadata_ready: true,
            introduction_ready,
            chat_ready,
            connections_ready,
            retryable: false,
            last_error_category: None,
            last_error_code: None,
            last_error_message: None,
            started_at: Some(Utc::now()),
            updated_at: Utc::now(),
            completed_at: None,
            parser_version: Some("fixture-parser".to_owned()),
            embedding_model: None,
            summary_model: None,
        }
    }

    /// Requires a disposable `PostgreSQL` database with `pgvector`, `pg_trgm`
    /// and `pgcrypto` available. This is intentionally opt-in for local/CI service
    /// jobs; unit tests never require a live database.
    #[tokio::test]
    #[ignore = "set TEST_DATABASE_URL to a disposable PostgreSQL database"]
    async fn migrations_apply_and_required_extensions_are_ready() {
        let url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let database = Database::connect(&url, 2).await.unwrap();
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../migrations");
        database.migrate(path).await.unwrap();
        database.ready().await.unwrap();

        let mut hostile_search_path_url = Url::parse(&url).unwrap();
        hostile_search_path_url
            .query_pairs_mut()
            .append_pair("options", "-c search_path=pg_catalog");
        let bound_database = Database::connect(hostile_search_path_url.as_str(), 2)
            .await
            .unwrap();
        let effective_search_path: String =
            sqlx::query_scalar("SELECT pg_catalog.current_setting('search_path')")
                .fetch_one(bound_database.pool())
                .await
                .unwrap();
        let current_schema: Option<String> =
            sqlx::query_scalar("SELECT pg_catalog.current_schema()::text")
                .fetch_one(bound_database.pool())
                .await
                .unwrap();
        assert_eq!(effective_search_path, "public, pg_catalog");
        assert_eq!(current_schema.as_deref(), Some("public"));
        bound_database.ready().await.unwrap();

        sqlx::query("CREATE SCHEMA pakperk_wrong_extension_namespace")
            .execute(bound_database.pool())
            .await
            .unwrap();
        sqlx::query("ALTER EXTENSION pgcrypto SET SCHEMA pakperk_wrong_extension_namespace")
            .execute(bound_database.pool())
            .await
            .unwrap();
        let wrong_namespace = bound_database.ready().await;
        sqlx::query("ALTER EXTENSION pgcrypto SET SCHEMA public")
            .execute(bound_database.pool())
            .await
            .unwrap();
        sqlx::query("DROP SCHEMA pakperk_wrong_extension_namespace")
            .execute(bound_database.pool())
            .await
            .unwrap();
        assert!(matches!(
            wrong_namespace,
            Err(DbError::InvalidData(message))
                if message == "required PostgreSQL extension pgcrypto must be installed exactly once in public"
        ));
        bound_database.ready().await.unwrap();
    }
}
