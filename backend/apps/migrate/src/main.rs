use std::time::Instant;

use anyhow::{Context as _, Result};
use observability::{
    ObservabilityConfig, OperationClass, OperationOutcome, init, record_operation,
};
use sqlx::{Connection as _, PgConnection};
use tracing::warn;
use url::Url;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

const MIGRATION_LOCK_SQL: &str = "SELECT pg_advisory_lock(1346458443, 1)";
const MIGRATION_UNLOCK_SQL: &str = "SELECT pg_advisory_unlock(1346458443, 1)";
const MIGRATION_SEARCH_PATH_SQL: &str = "SET search_path TO public, pg_catalog";

#[derive(Debug)]
struct Config {
    database_url: String,
    environment: String,
    backup_id: String,
    expected_version: i64,
}

impl Config {
    fn from_env() -> Result<Self> {
        let environment = required("APP_ENV")?;
        if !matches!(environment.as_str(), "staging" | "production") {
            anyhow::bail!("APP_ENV must be staging or production for standalone migrations");
        }
        let database_url = required("DATABASE_URL")?;
        let parsed = Url::parse(&database_url).context("DATABASE_URL must be a valid URL")?;
        if !matches!(parsed.scheme(), "postgres" | "postgresql") {
            anyhow::bail!("DATABASE_URL must use postgres:// or postgresql://");
        }
        let backup_id = required("PAKPERK_MIGRATION_BACKUP_ID")?;
        validate_backup_id(&backup_id)?;
        let expected_version = required("PAKPERK_MIGRATION_EXPECTED_VERSION")?
            .parse::<i64>()
            .context("PAKPERK_MIGRATION_EXPECTED_VERSION must be an integer")?;
        if expected_version <= 0 {
            anyhow::bail!("PAKPERK_MIGRATION_EXPECTED_VERSION must be positive");
        }
        let embedded_version = MIGRATOR
            .iter()
            .last()
            .map(|migration| migration.version)
            .context("the migration binary contains no migrations")?;
        if expected_version != embedded_version {
            anyhow::bail!(
                "expected migration version does not match this release binary ({expected_version} != {embedded_version})"
            );
        }
        Ok(Self {
            database_url,
            environment,
            backup_id,
            expected_version,
        })
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    if std::env::args()
        .skip(1)
        .any(|argument| matches!(argument.as_str(), "-h" | "--help" | "help"))
    {
        println!("{}", usage());
        return Ok(());
    }
    if std::env::args().len() != 1 {
        anyhow::bail!("pakperk-migrate takes no arguments; use --help for the contract");
    }

    let config = Config::from_env().context("invalid migration configuration")?;
    let telemetry_config = ObservabilityConfig::from_env("pakperk-migrate")
        .context("invalid telemetry configuration")?;
    let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;
    let started = Instant::now();
    let result = run(&config).await;
    record_operation(
        OperationClass::DatabaseMigration,
        if result.is_ok() {
            OperationOutcome::Success
        } else {
            OperationOutcome::TerminalFailure
        },
        started.elapsed(),
    );
    let telemetry_result = telemetry
        .shutdown()
        .context("could not flush migration telemetry");
    finish(result, &telemetry_result)
}

fn finish(migration: Result<()>, telemetry: &Result<()>) -> Result<()> {
    migration?;
    if telemetry.is_err() {
        // A pre-install hook intentionally runs before the in-chart Collector
        // exists. Its JSON stdout remains release evidence; exporter
        // unavailability must never turn an already-successful schema change
        // into a failed/retried migration job.
        warn!(
            error.kind = "telemetry_flush",
            "migration telemetry could not be flushed"
        );
    }
    Ok(())
}

async fn run(config: &Config) -> Result<()> {
    let mut connection = PgConnection::connect(&config.database_url)
        .await
        .context("could not connect with the migration database role")?;
    bind_public_schema(&mut connection).await?;
    sqlx::query(MIGRATION_LOCK_SQL)
        .execute(&mut connection)
        .await
        .context("could not acquire the global migration lock")?;

    let result = run_locked(&mut connection, config).await;
    let unlock_result = sqlx::query(MIGRATION_UNLOCK_SQL)
        .execute(&mut connection)
        .await
        .context("could not release the global migration lock");
    result?;
    unlock_result?;
    println!(
        "migration verified: environment={} backup_id={} schema_version={}",
        config.environment, config.backup_id, config.expected_version
    );
    Ok(())
}

async fn bind_public_schema(connection: &mut PgConnection) -> Result<()> {
    sqlx::query(MIGRATION_SEARCH_PATH_SQL)
        .execute(&mut *connection)
        .await
        .context("could not bind the migration session to the public schema")?;
    let configured_search_path: String =
        sqlx::query_scalar("SELECT pg_catalog.current_setting('search_path')")
            .fetch_one(&mut *connection)
            .await
            .context("could not verify the migration session search path")?;
    let current_schema: Option<String> =
        sqlx::query_scalar("SELECT pg_catalog.current_schema()::text")
            .fetch_one(&mut *connection)
            .await
            .context("could not verify the migration session current schema")?;
    if configured_search_path != "public, pg_catalog" || current_schema.as_deref() != Some("public")
    {
        anyhow::bail!("migration session is not bound to public, pg_catalog");
    }
    Ok(())
}

async fn run_locked(connection: &mut PgConnection, config: &Config) -> Result<()> {
    MIGRATOR
        .run(&mut *connection)
        .await
        .context("embedded database migration failed")?;

    let applied_version: Option<i64> =
        sqlx::query_scalar("SELECT max(version) FROM public._sqlx_migrations WHERE success = TRUE")
            .fetch_one(&mut *connection)
            .await
            .context("could not verify the applied migration version")?;
    if applied_version != Some(config.expected_version) {
        anyhow::bail!(
            "database migration version mismatch: expected {}, found {:?}",
            config.expected_version,
            applied_version
        );
    }
    let failed_migrations: i64 =
        sqlx::query_scalar("SELECT count(*) FROM public._sqlx_migrations WHERE success = FALSE")
            .fetch_one(&mut *connection)
            .await
            .context("could not verify migration success records")?;
    if failed_migrations != 0 {
        anyhow::bail!("database contains failed migration records");
    }
    let required_extensions: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM pg_catalog.pg_extension AS extensions
        JOIN pg_catalog.pg_namespace AS namespaces
          ON namespaces.oid = extensions.extnamespace
        WHERE extensions.extname IN ('vector', 'pg_trgm', 'pgcrypto')
          AND namespaces.nspname = 'public'
        ",
    )
    .fetch_one(&mut *connection)
    .await
    .context("could not verify required PostgreSQL extensions")?;
    if required_extensions != 3 {
        anyhow::bail!("required PostgreSQL extensions are missing from public after migration");
    }
    let required_tables: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name IN (
            'papers',
            'users',
            'paper_comments',
            'user_reports',
            'paper_import_operations',
            'paper_interactions',
            'reading_briefs',
            'notifications',
            'notification_work_items',
            'recommendation_generation_jobs',
            'recommendation_generation_candidates',
            'account_deletion_jobs',
            'account_deletion_ledger'
          )
        ",
    )
    .fetch_one(&mut *connection)
    .await
    .context("could not verify required application tables")?;
    if required_tables != 13 {
        anyhow::bail!("required application tables are missing after migration");
    }
    Ok(())
}

fn required(name: &str) -> Result<String> {
    let value = std::env::var(name).with_context(|| format!("{name} is required"))?;
    if value.is_empty() || value.trim() != value {
        anyhow::bail!("{name} must be non-empty and contain no surrounding whitespace");
    }
    Ok(value)
}

fn validate_backup_id(value: &str) -> Result<()> {
    if !(8..=128).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        anyhow::bail!(
            "PAKPERK_MIGRATION_BACKUP_ID must be 8..128 safe ASCII identifier characters"
        );
    }
    let normalized = value.to_ascii_lowercase();
    if [
        "placeholder",
        "example",
        "changeme",
        "replace",
        "unknown",
        "todo",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
    {
        anyhow::bail!("PAKPERK_MIGRATION_BACKUP_ID must identify a verified real backup");
    }
    Ok(())
}

const fn usage() -> &'static str {
    "pakperk-migrate\n\nRequires APP_ENV=staging|production, DATABASE_URL, PAKPERK_MIGRATION_BACKUP_ID, and PAKPERK_MIGRATION_EXPECTED_VERSION. Forces the public schema, acquires a global advisory lock, applies embedded forward migrations, and verifies the resulting schema."
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use sqlx::{Connection as _, PgConnection, migrate::Migrate as _};
    use url::Url;

    use super::{Config, finish, run, validate_backup_id};

    #[test]
    fn backup_identifiers_are_bounded_and_non_placeholder() {
        assert!(validate_backup_id("pitr-20260801T020000Z-a7f9").is_ok());
        assert!(validate_backup_id("placeholder-backup-123").is_err());
        assert!(validate_backup_id("prod backup 1").is_err());
        assert!(validate_backup_id("short").is_err());
    }

    #[test]
    fn telemetry_failure_cannot_override_a_successful_migration() {
        assert!(finish(Ok(()), &Err(anyhow::anyhow!("collector unavailable"))).is_ok());
        assert!(finish(Err(anyhow::anyhow!("migration failed")), &Ok(())).is_err());
    }

    async fn create_test_database(
        admin: &mut PgConnection,
        base_url: &str,
        scenario: &str,
    ) -> anyhow::Result<(String, Url)> {
        anyhow::ensure!(
            scenario
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        );
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("the system clock is before the Unix epoch")
            .as_nanos();
        let database = format!(
            "pakperk_migrate_{scenario}_{}_{}",
            std::process::id(),
            suffix
        );
        let mut scoped_url = Url::parse(base_url)?;
        scoped_url.set_path(&format!("/{database}"));
        scoped_url.set_query(None);
        scoped_url.set_fragment(None);
        sqlx::query(&format!("CREATE DATABASE {database} TEMPLATE template0"))
            .execute(&mut *admin)
            .await?;
        Ok((database, scoped_url))
    }

    fn test_config(scoped_url: &Url, backup_id: &str) -> Config {
        Config {
            database_url: scoped_url.to_string(),
            environment: "staging".to_owned(),
            backup_id: backup_id.to_owned(),
            expected_version: super::MIGRATOR.iter().last().unwrap().version,
        }
    }

    async fn drop_test_database(admin: &mut PgConnection, database: &str) -> anyhow::Result<()> {
        sqlx::query(&format!("DROP DATABASE {database} WITH (FORCE)"))
            .execute(admin)
            .await?;
        Ok(())
    }

    async fn exercise_empty_latest_and_hostile_path(
        admin: &mut PgConnection,
        base_url: &str,
    ) -> anyhow::Result<()> {
        let (database, scoped_url) = create_test_database(admin, base_url, "empty_hostile").await?;
        let outcome = async {
            let hostile_schema = "hostile_migration_path";
            let mut preparation = PgConnection::connect(scoped_url.as_str()).await?;
            sqlx::query(&format!("CREATE SCHEMA {hostile_schema}"))
                .execute(&mut preparation)
                .await?;
            drop(preparation);

            let mut hostile_url = scoped_url.clone();
            hostile_url
                .query_pairs_mut()
                .append_pair("options", &format!("-csearch_path={hostile_schema},public"));
            let config = test_config(&hostile_url, "integration-backup-empty-20260801");
            // Both initial bootstrap and latest-schema verification traverse
            // the production bind, lock, migrator, and postcheck path.
            run(&config).await?;
            run(&config).await?;

            let mut verification = PgConnection::connect(scoped_url.as_str()).await?;
            let applied_version: Option<i64> = sqlx::query_scalar(
                "SELECT max(version) FROM public._sqlx_migrations WHERE success = TRUE",
            )
            .fetch_one(&mut verification)
            .await?;
            anyhow::ensure!(
                applied_version == Some(super::MIGRATOR.iter().last().unwrap().version)
            );
            let hostile_objects: i64 = sqlx::query_scalar(
                r"
                SELECT count(*)
                FROM information_schema.tables
                WHERE table_schema = $1
                  AND table_name IN (
                    '_sqlx_migrations',
                    'papers',
                    'users',
                    'account_deletion_jobs',
                    'account_deletion_ledger'
                  )
                ",
            )
            .bind(hostile_schema)
            .fetch_one(&mut verification)
            .await?;
            anyhow::ensure!(hostile_objects == 0);

            // A current schema with correctly named extensions in the wrong
            // namespace must fail its real standalone postcheck.
            sqlx::query("CREATE SCHEMA wrong_extension_namespace")
                .execute(&mut verification)
                .await?;
            sqlx::query("ALTER EXTENSION pgcrypto SET SCHEMA wrong_extension_namespace")
                .execute(&mut verification)
                .await?;
            drop(verification);
            let error = run(&config).await.expect_err("wrong extension namespace");
            anyhow::ensure!(
                format!("{error:#}")
                    .contains("required PostgreSQL extensions are missing from public")
            );
            Ok::<_, anyhow::Error>(())
        }
        .await;
        let cleanup = drop_test_database(admin, &database).await;
        outcome?;
        cleanup
    }

    async fn exercise_version_one_upgrade(
        admin: &mut PgConnection,
        base_url: &str,
    ) -> anyhow::Result<()> {
        let (database, scoped_url) = create_test_database(admin, base_url, "v1").await?;
        let outcome = async {
            let mut version_one = PgConnection::connect(scoped_url.as_str()).await?;
            sqlx::query(super::MIGRATION_SEARCH_PATH_SQL)
                .execute(&mut version_one)
                .await?;
            version_one.ensure_migrations_table().await?;
            version_one
                .apply(super::MIGRATOR.iter().next().unwrap())
                .await?;
            seed_version_one_fixture(&mut version_one).await?;
            let applied_version: Option<i64> = sqlx::query_scalar(
                "SELECT max(version) FROM _sqlx_migrations WHERE success = TRUE",
            )
            .fetch_one(&mut version_one)
            .await?;
            anyhow::ensure!(applied_version == Some(1));
            drop(version_one);

            let config = test_config(&scoped_url, "integration-backup-v1-20260801");
            run(&config).await?;
            let mut upgraded = PgConnection::connect(scoped_url.as_str()).await?;
            assert_version_one_fixture(&mut upgraded).await?;
            drop(upgraded);
            // The upgraded schema is also a supported input. Re-running must
            // be a no-op verification and must preserve version-one data.
            run(&config).await?;
            let mut upgraded = PgConnection::connect(scoped_url.as_str()).await?;
            assert_version_one_fixture(&mut upgraded).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;
        let cleanup = drop_test_database(admin, &database).await;
        outcome?;
        cleanup
    }

    async fn exercise_version_eleven_library_upgrade(
        admin: &mut PgConnection,
        base_url: &str,
    ) -> anyhow::Result<()> {
        let (database, scoped_url) = create_test_database(admin, base_url, "v11_library").await?;
        let outcome = async {
            let mut version_eleven = PgConnection::connect(scoped_url.as_str()).await?;
            sqlx::query(super::MIGRATION_SEARCH_PATH_SQL)
                .execute(&mut version_eleven)
                .await?;
            version_eleven.ensure_migrations_table().await?;
            for migration in super::MIGRATOR.iter().take(11) {
                version_eleven.apply(migration).await?;
            }
            let applied_version: Option<i64> = sqlx::query_scalar(
                "SELECT max(version) FROM _sqlx_migrations WHERE success = TRUE",
            )
            .fetch_one(&mut version_eleven)
            .await?;
            anyhow::ensure!(applied_version == Some(11));
            seed_version_eleven_library_fixture(&mut version_eleven).await?;
            drop(version_eleven);

            let config = test_config(&scoped_url, "integration-backup-v11-library-20260828");
            run(&config).await?;
            let mut upgraded = PgConnection::connect(scoped_url.as_str()).await?;
            assert_version_eleven_library_fixture(&mut upgraded, 1, 3).await?;
            exercise_v0_library_sql_after_upgrade(&mut upgraded).await?;
            assert_version_eleven_library_fixture(&mut upgraded, 2, 4).await?;
            drop(upgraded);

            // Re-forwarding the expand-compatible image is a no-op and must
            // retain writes accepted by a temporarily rolled-back v0 binary.
            run(&config).await?;
            let mut reforwarded = PgConnection::connect(scoped_url.as_str()).await?;
            assert_version_eleven_library_fixture(&mut reforwarded, 2, 4).await?;
            Ok::<_, anyhow::Error>(())
        }
        .await;
        let cleanup = drop_test_database(admin, &database).await;
        outcome?;
        cleanup
    }

    #[allow(clippy::too_many_lines)]
    async fn seed_version_eleven_library_fixture(
        connection: &mut PgConnection,
    ) -> anyhow::Result<()> {
        sqlx::query(
            r"
            INSERT INTO users (id, oidc_issuer, oidc_subject)
            VALUES (
                '51000000-0000-4000-8000-000000000001'::uuid,
                'https://migration-v11.test',
                'library-owner'
            )
            ",
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r#"
            INSERT INTO papers (
                id, arxiv_base_id, arxiv_version, title, abstract, authors,
                primary_category, categories, published_at, updated_at,
                abs_url, pdf_url, metadata_fetched_at
            ) VALUES
                (
                    '52000000-0000-4000-8000-000000000001'::uuid,
                    '2608.51001', 1, 'Active v11 library fixture', 'Active.',
                    '["Migration Test"]'::jsonb, 'cs.AI', ARRAY['cs.AI'],
                    '2024-01-01T00:00:00Z'::timestamptz,
                    '2024-01-01T00:00:00Z'::timestamptz,
                    'https://arxiv.org/abs/2608.51001',
                    'https://arxiv.org/pdf/2608.51001',
                    '2024-01-01T00:00:00Z'::timestamptz
                ),
                (
                    '52000000-0000-4000-8000-000000000002'::uuid,
                    '2608.51002', 1, 'Removed v11 library fixture', 'Removed.',
                    '["Migration Test"]'::jsonb, 'cs.LG', ARRAY['cs.LG'],
                    '2024-01-02T00:00:00Z'::timestamptz,
                    '2024-01-02T00:00:00Z'::timestamptz,
                    'https://arxiv.org/abs/2608.51002',
                    'https://arxiv.org/pdf/2608.51002',
                    '2024-01-02T00:00:00Z'::timestamptz
                ),
                (
                    '52000000-0000-4000-8000-000000000003'::uuid,
                    '2608.51003', 1, 'Rollback write fixture', 'Rollback.',
                    '["Migration Test"]'::jsonb, 'cs.IR', ARRAY['cs.IR'],
                    '2024-01-03T00:00:00Z'::timestamptz,
                    '2024-01-03T00:00:00Z'::timestamptz,
                    'https://arxiv.org/abs/2608.51003',
                    'https://arxiv.org/pdf/2608.51003',
                    '2024-01-03T00:00:00Z'::timestamptz
                )
            "#,
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            INSERT INTO library_sync_metadata (
                user_id, current_revision, purged_through_revision
            ) VALUES ('51000000-0000-4000-8000-000000000001'::uuid, 3, 0)
            ",
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            INSERT INTO library_operations (
                user_id, operation_id, paper_id, intent, state, intent_fingerprint,
                accepted_revision, accepted_saved_at, accepted_updated_at,
                accepted_removed_at
            ) VALUES
                (
                    '51000000-0000-4000-8000-000000000001'::uuid,
                    '53000000-0000-4000-8000-000000000001'::uuid,
                    '52000000-0000-4000-8000-000000000001'::uuid,
                    'save', 'to_read',
                    digest('52000000-0000-4000-8000-000000000001:save:to_read', 'sha256'),
                    1, '2024-02-01T01:00:00Z'::timestamptz,
                    '2024-02-01T01:00:00Z'::timestamptz, NULL
                ),
                (
                    '51000000-0000-4000-8000-000000000001'::uuid,
                    '53000000-0000-4000-8000-000000000002'::uuid,
                    '52000000-0000-4000-8000-000000000002'::uuid,
                    'save', 'to_read',
                    digest('52000000-0000-4000-8000-000000000002:save:to_read', 'sha256'),
                    2, '2024-02-02T01:00:00Z'::timestamptz,
                    '2024-02-02T01:00:00Z'::timestamptz, NULL
                ),
                (
                    '51000000-0000-4000-8000-000000000001'::uuid,
                    '53000000-0000-4000-8000-000000000003'::uuid,
                    '52000000-0000-4000-8000-000000000002'::uuid,
                    'remove', 'to_read',
                    digest('52000000-0000-4000-8000-000000000002:remove:to_read', 'sha256'),
                    3, '2024-02-02T01:00:00Z'::timestamptz,
                    '2024-02-03T01:00:00Z'::timestamptz,
                    '2024-02-03T01:00:00Z'::timestamptz
                )
            ",
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            INSERT INTO user_paper_library (
                user_id, paper_id, state, saved_at, updated_at, removed_at,
                revision, last_operation_id
            ) VALUES
                (
                    '51000000-0000-4000-8000-000000000001'::uuid,
                    '52000000-0000-4000-8000-000000000001'::uuid,
                    'to_read', '2024-02-01T01:00:00Z'::timestamptz,
                    '2024-02-01T01:00:00Z'::timestamptz, NULL, 1,
                    '53000000-0000-4000-8000-000000000001'::uuid
                ),
                (
                    '51000000-0000-4000-8000-000000000001'::uuid,
                    '52000000-0000-4000-8000-000000000002'::uuid,
                    'to_read', '2024-02-02T01:00:00Z'::timestamptz,
                    '2024-02-03T01:00:00Z'::timestamptz,
                    '2024-02-03T01:00:00Z'::timestamptz, 3,
                    '53000000-0000-4000-8000-000000000003'::uuid
                )
            ",
        )
        .execute(&mut *connection)
        .await?;
        Ok(())
    }

    async fn exercise_v0_library_sql_after_upgrade(
        connection: &mut PgConnection,
    ) -> anyhow::Result<()> {
        let replay: (String, String, bool) = sqlx::query_as(
            r"
            SELECT intent, state,
                   intent_fingerprint = digest(
                       paper_id::text || ':' || intent || ':' || state,
                       'sha256'
                   )
            FROM library_operations
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
              AND operation_id = '53000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(replay == ("save".to_owned(), "to_read".to_owned(), true));

        sqlx::query(
            r"
            INSERT INTO user_paper_library (
                user_id, paper_id, state, saved_at, updated_at, removed_at,
                revision, last_operation_id
            ) VALUES (
                '51000000-0000-4000-8000-000000000001'::uuid,
                '52000000-0000-4000-8000-000000000003'::uuid,
                'to_read', '2024-02-04T01:00:00Z'::timestamptz,
                '2024-02-04T01:00:00Z'::timestamptz, NULL, 4,
                '53000000-0000-4000-8000-000000000004'::uuid
            )
            ",
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            INSERT INTO library_operations (
                user_id, operation_id, paper_id, intent, state, intent_fingerprint,
                accepted_revision, accepted_saved_at, accepted_updated_at,
                accepted_removed_at
            ) VALUES (
                '51000000-0000-4000-8000-000000000001'::uuid,
                '53000000-0000-4000-8000-000000000004'::uuid,
                '52000000-0000-4000-8000-000000000003'::uuid,
                'save', 'to_read',
                digest('52000000-0000-4000-8000-000000000003:save:to_read', 'sha256'),
                4, '2024-02-04T01:00:00Z'::timestamptz,
                '2024-02-04T01:00:00Z'::timestamptz, NULL
            )
            ",
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            UPDATE library_sync_metadata
            SET current_revision = 4
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .execute(&mut *connection)
        .await?;
        Ok(())
    }

    async fn assert_version_eleven_library_fixture(
        connection: &mut PgConnection,
        expected_active: i64,
        expected_revision: i64,
    ) -> anyhow::Result<()> {
        let states: (i64, i64, i64) = sqlx::query_as(
            r"
            SELECT
                count(*) FILTER (WHERE state = 'to_read' AND removed_at IS NULL),
                count(*) FILTER (WHERE state = 'to_read' AND removed_at IS NOT NULL),
                count(*) FILTER (WHERE state = 'inbox')
            FROM user_paper_library
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(states == (expected_active, 1, 0));
        let metadata_revision: i64 = sqlx::query_scalar(
            r"
            SELECT current_revision FROM library_sync_metadata
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(metadata_revision == expected_revision);
        let operation_shape: (i64, i64, i64) = sqlx::query_as(
            r"
            SELECT
                count(*),
                count(*) FILTER (
                    WHERE intent_fingerprint = digest(
                        paper_id::text || ':' || intent || ':' || state,
                        'sha256'
                    )
                ),
                count(*) FILTER (WHERE v2_intent_fingerprint IS NULL)
            FROM library_operations
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        let expected_operations = expected_revision;
        anyhow::ensure!(
            operation_shape
                == (
                    expected_operations,
                    expected_operations,
                    expected_operations
                )
        );
        let removed: (bool, bool, i64, String) = sqlx::query_as(
            r"
            SELECT
                saved_at = '2024-02-02T01:00:00Z'::timestamptz,
                removed_at = '2024-02-03T01:00:00Z'::timestamptz,
                revision,
                last_operation_id::text
            FROM user_paper_library
            WHERE user_id = '51000000-0000-4000-8000-000000000001'::uuid
              AND paper_id = '52000000-0000-4000-8000-000000000002'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            removed
                == (
                    true,
                    true,
                    3,
                    "53000000-0000-4000-8000-000000000003".to_owned(),
                )
        );
        Ok(())
    }

    async fn seed_version_one_fixture(connection: &mut PgConnection) -> anyhow::Result<()> {
        seed_version_one_paper(connection).await?;
        seed_version_one_thread(connection).await?;
        seed_version_one_messages(connection).await?;
        seed_version_one_rate_limit(connection).await
    }

    async fn seed_version_one_paper(connection: &mut PgConnection) -> anyhow::Result<()> {
        sqlx::query(
            r#"
            INSERT INTO papers (
                id,
                arxiv_base_id,
                arxiv_version,
                title,
                abstract,
                authors,
                primary_category,
                categories,
                published_at,
                updated_at,
                abs_url,
                pdf_url,
                metadata_fetched_at
            ) VALUES (
                '10000000-0000-4000-8000-000000000001'::uuid,
                'phase6-migration-fixture',
                1,
                'Phase 6 migration fixture',
                'A representative row created by schema version one.',
                '["Pakperk CI"]'::jsonb,
                'cs.AI',
                ARRAY['cs.AI'],
                '2024-01-01T00:00:00Z'::timestamptz,
                '2024-01-01T00:00:00Z'::timestamptz,
                'https://arxiv.org/abs/2401.00001',
                'https://arxiv.org/pdf/2401.00001',
                '2024-01-01T00:00:00Z'::timestamptz
            )
            "#,
        )
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r"
            UPDATE paper_processing
            SET generation = 3,
                stage = 'introduction_ready',
                introduction_ready = TRUE,
                parser_version = 'phase6-parser-v1'
            WHERE paper_id = '10000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .execute(&mut *connection)
        .await?;
        Ok(())
    }

    async fn seed_version_one_thread(connection: &mut PgConnection) -> anyhow::Result<()> {
        sqlx::query(
            r"
            INSERT INTO chat_threads (
                id,
                anonymous_session_id,
                paper_id,
                generation,
                created_at,
                updated_at
            ) VALUES (
                '20000000-0000-4000-8000-000000000001'::uuid,
                '30000000-0000-4000-8000-000000000001'::uuid,
                '10000000-0000-4000-8000-000000000001'::uuid,
                3,
                '2024-01-02T03:04:05Z'::timestamptz,
                '2024-01-02T03:05:06Z'::timestamptz
            )
            ",
        )
        .execute(connection)
        .await?;
        Ok(())
    }

    async fn seed_version_one_messages(connection: &mut PgConnection) -> anyhow::Result<()> {
        sqlx::query(
            r#"
            INSERT INTO chat_messages (
                id,
                thread_id,
                role,
                content,
                source_metadata,
                provider_request_id,
                model_id,
                created_at
            ) VALUES
                (
                    '40000000-0000-4000-8000-000000000001'::uuid,
                    '20000000-0000-4000-8000-000000000001'::uuid,
                    'user',
                    'What is the representative result?',
                    '[]'::jsonb,
                    NULL,
                    NULL,
                    '2024-01-02T03:06:07Z'::timestamptz
                ),
                (
                    '40000000-0000-4000-8000-000000000002'::uuid,
                    '20000000-0000-4000-8000-000000000001'::uuid,
                    'assistant',
                    'The representative result survives the upgrade.',
                    '[{"section":"introduction"}]'::jsonb,
                    'phase6-provider-request-v1',
                    'phase6-model-v1',
                    '2024-01-02T03:07:08Z'::timestamptz
                )
            "#,
        )
        .execute(connection)
        .await?;
        Ok(())
    }

    async fn seed_version_one_rate_limit(connection: &mut PgConnection) -> anyhow::Result<()> {
        sqlx::query(
            r"
            UPDATE external_rate_limits
            SET last_started_at = '2024-01-02T03:08:09Z'::timestamptz
            WHERE service = 'arxiv'
            ",
        )
        .execute(connection)
        .await?;
        Ok(())
    }

    async fn assert_version_one_fixture(connection: &mut PgConnection) -> anyhow::Result<()> {
        assert_version_one_paper(connection).await?;
        assert_version_one_thread(connection).await?;
        assert_version_one_user_message(connection).await?;
        assert_version_one_assistant_message(connection).await?;
        assert_version_one_rate_limit(connection).await
    }

    async fn assert_version_one_paper(connection: &mut PgConnection) -> anyhow::Result<()> {
        let paper: (String, i32, String, String) = sqlx::query_as(
            r"
            SELECT id::text, arxiv_version, title, abstract
            FROM public.papers
            WHERE arxiv_base_id = 'phase6-migration-fixture'
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            paper
                == (
                    "10000000-0000-4000-8000-000000000001".to_owned(),
                    1,
                    "Phase 6 migration fixture".to_owned(),
                    "A representative row created by schema version one.".to_owned(),
                )
        );

        let processing: (String, i32, String, bool, bool, Option<String>) = sqlx::query_as(
            r"
            SELECT
                paper_id::text,
                generation,
                stage,
                metadata_ready,
                introduction_ready,
                parser_version
            FROM public.paper_processing
            WHERE paper_id = '10000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            processing
                == (
                    "10000000-0000-4000-8000-000000000001".to_owned(),
                    3,
                    "introduction_ready".to_owned(),
                    true,
                    true,
                    Some("phase6-parser-v1".to_owned()),
                )
        );
        Ok(())
    }

    async fn assert_version_one_thread(connection: &mut PgConnection) -> anyhow::Result<()> {
        let thread: (String, String, String, i32, bool, bool) = sqlx::query_as(
            r"
            SELECT
                id::text,
                anonymous_session_id::text,
                paper_id::text,
                generation,
                created_at = '2024-01-02T03:04:05Z'::timestamptz,
                updated_at = '2024-01-02T03:05:06Z'::timestamptz
            FROM public.chat_threads
            WHERE id = '20000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            thread
                == (
                    "20000000-0000-4000-8000-000000000001".to_owned(),
                    "30000000-0000-4000-8000-000000000001".to_owned(),
                    "10000000-0000-4000-8000-000000000001".to_owned(),
                    3,
                    true,
                    true,
                )
        );
        Ok(())
    }

    async fn assert_version_one_user_message(connection: &mut PgConnection) -> anyhow::Result<()> {
        let user_message: (
            String,
            String,
            String,
            bool,
            Option<String>,
            Option<String>,
            Option<String>,
        ) = sqlx::query_as(
            r"
            SELECT
                id::text,
                role,
                content,
                source_metadata = '[]'::jsonb,
                provider_request_id,
                model_id,
                prompt_version
            FROM public.chat_messages
            WHERE id = '40000000-0000-4000-8000-000000000001'::uuid
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            user_message
                == (
                    "40000000-0000-4000-8000-000000000001".to_owned(),
                    "user".to_owned(),
                    "What is the representative result?".to_owned(),
                    true,
                    None,
                    None,
                    None,
                )
        );
        Ok(())
    }

    async fn assert_version_one_assistant_message(
        connection: &mut PgConnection,
    ) -> anyhow::Result<()> {
        let assistant_message: (
            String,
            String,
            String,
            bool,
            Option<String>,
            Option<String>,
            Option<String>,
        ) = sqlx::query_as(
            r#"
            SELECT
                id::text,
                role,
                content,
                source_metadata = '[{"section":"introduction"}]'::jsonb,
                provider_request_id,
                model_id,
                prompt_version
            FROM public.chat_messages
            WHERE id = '40000000-0000-4000-8000-000000000002'::uuid
            "#,
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(
            assistant_message
                == (
                    "40000000-0000-4000-8000-000000000002".to_owned(),
                    "assistant".to_owned(),
                    "The representative result survives the upgrade.".to_owned(),
                    true,
                    Some("phase6-provider-request-v1".to_owned()),
                    Some("phase6-model-v1".to_owned()),
                    None,
                )
        );
        Ok(())
    }

    async fn assert_version_one_rate_limit(connection: &mut PgConnection) -> anyhow::Result<()> {
        let arxiv_rate_limit: (String, bool, bool) = sqlx::query_as(
            r"
            SELECT
                service,
                last_started_at = '2024-01-02T03:08:09Z'::timestamptz,
                blocked_until = '1970-01-01T00:00:00Z'::timestamptz
            FROM public.external_rate_limits
            WHERE service = 'arxiv'
            ",
        )
        .fetch_one(&mut *connection)
        .await?;
        anyhow::ensure!(arxiv_rate_limit == ("arxiv".to_owned(), true, true));

        Ok(())
    }

    #[tokio::test]
    async fn standalone_run_bootstraps_upgrades_and_rejects_wrong_extension_namespace() {
        let Ok(base_url) = std::env::var("TEST_DATABASE_URL") else {
            return;
        };
        let mut admin = PgConnection::connect(&base_url).await.unwrap();
        exercise_empty_latest_and_hostile_path(&mut admin, &base_url)
            .await
            .unwrap();
        exercise_version_one_upgrade(&mut admin, &base_url)
            .await
            .unwrap();
        exercise_version_eleven_library_upgrade(&mut admin, &base_url)
            .await
            .unwrap();
    }
}
