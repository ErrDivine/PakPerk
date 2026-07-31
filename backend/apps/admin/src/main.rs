mod cli;

use std::io::{self, Write as _};

use anyhow::{Context as _, Result};
use cli::{CliError, Command};
use db::{AdminReportResolution, Database};
use domain::AuthenticatedUserId;
use moderation::{AdminActor, ModerationActionResult, ModerationService};
use serde::Serialize;
use serde_json::json;

#[tokio::main]
async fn main() -> Result<()> {
    let actor = std::env::var("PAKPERK_ADMIN_ACTOR").ok();
    let parsed = match cli::parse(std::env::args(), actor.as_deref()) {
        Ok(parsed) => parsed,
        Err(CliError::Help) => {
            println!("{}", cli::usage());
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let database_url = std::env::var("DATABASE_URL")
        .context("DATABASE_URL must be provided through the environment")?;
    let pool_size = std::env::var("ADMIN_DATABASE_POOL_SIZE")
        .ok()
        .map(|value| value.parse::<u32>())
        .transpose()
        .context("ADMIN_DATABASE_POOL_SIZE must be an integer")?
        .unwrap_or(2);
    if !(1..=10).contains(&pool_size) {
        anyhow::bail!("ADMIN_DATABASE_POOL_SIZE must be between 1 and 10");
    }
    let database = Database::connect(&database_url, pool_size)
        .await
        .context("could not connect to the moderation database")?;
    database
        .ready()
        .await
        .context("moderation database is not ready")?;
    let actor =
        AdminActor::label(parsed.actor.as_str()).context("PAKPERK_ADMIN_ACTOR is invalid")?;
    execute(
        &ModerationService::new(database.moderation()),
        &actor,
        parsed.command,
    )
    .await
}

async fn execute(service: &ModerationService, actor: &AdminActor, command: Command) -> Result<()> {
    match command {
        Command::CommentsList {
            status,
            cursor,
            limit,
        } if status == "pending_review" => {
            write_json(&service.list_pending(cursor.as_deref(), limit).await?)
        }
        Command::CommentsList {
            status,
            cursor,
            limit,
        } => write_json(
            &service
                .list_reports(&status, cursor.as_deref(), limit)
                .await?,
        ),
        Command::CommentsInspect { comment_id } => {
            // This is the sole command permitted to serialize full UGC and
            // reporter detail. The command name makes that disclosure
            // explicit at the operator boundary.
            write_json(&service.inspect(comment_id).await?)
        }
        Command::CommentsHide { comment_id, reason } => {
            let result = service.hide(actor, comment_id, &reason).await?;
            write_json(&comment_action_output(&result))
        }
        Command::CommentsDelete { comment_id, reason } => {
            let result = service.delete(actor, comment_id, &reason).await?;
            write_json(&comment_action_output(&result))
        }
        Command::CommentsRestore { comment_id } => {
            let result = service.restore(actor, comment_id, "manual_restore").await?;
            write_json(&comment_action_output(&result))
        }
        Command::ReportsResolve { report_id, action } => {
            let resolution = match action.as_str() {
                "reviewed" => AdminReportResolution::Reviewed,
                "actioned" => AdminReportResolution::Actioned,
                "dismissed" => AdminReportResolution::Dismissed,
                _ => anyhow::bail!("report action must be reviewed, actioned, or dismissed"),
            };
            let reason = format!("admin_{action}");
            write_json(
                &service
                    .resolve_report(actor, report_id, resolution, &reason)
                    .await?,
            )
        }
        Command::UsersSuspend { user_id, reason } => write_json(
            &service
                .suspend_user(actor, AuthenticatedUserId::new(user_id), &reason)
                .await?,
        ),
        Command::UsersReinstate { user_id } => write_json(
            &service
                .reinstate_user(actor, AuthenticatedUserId::new(user_id), "manual_reinstate")
                .await?,
        ),
    }
}

fn comment_action_output(result: &ModerationActionResult) -> serde_json::Value {
    json!({
        "comment_id": result.inspection.comment_id,
        "status": result.inspection.status,
        "version": result.inspection.version,
        "replayed": result.replayed,
    })
}

fn write_json(value: &impl Serialize) -> Result<()> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    serde_json::to_writer_pretty(&mut output, value).context("could not write command output")?;
    output.write_all(b"\n")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use domain::{AuthenticatedUserId, CommentBody, CommentStatus};
    use moderation::{ModerationActionResult, ModerationInspection};
    use uuid::Uuid;

    use super::comment_action_output;

    #[test]
    fn action_output_never_serializes_body_outside_explicit_inspect() {
        let now = Utc::now();
        let result = ModerationActionResult {
            inspection: ModerationInspection {
                comment_id: Uuid::now_v7(),
                paper_id: Uuid::now_v7(),
                author_user_id: AuthenticatedUserId::new(Uuid::now_v7()),
                body: CommentBody::parse("sentinel-moderated-body").unwrap(),
                status: CommentStatus::Hidden,
                moderation_reason: Some("policy".to_owned()),
                version: 2,
                created_at: now,
                updated_at: now,
                reports: Vec::new(),
            },
            replayed: false,
        };
        let output = comment_action_output(&result).to_string();
        assert!(!output.contains("sentinel-moderated-body"));
        assert!(!output.contains("body"));
        assert!(!output.contains("moderation_reason"));
        assert!(output.contains("comment_id"));
    }
}
