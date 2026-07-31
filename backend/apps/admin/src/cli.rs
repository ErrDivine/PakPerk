use std::fmt;

use uuid::Uuid;

const MAX_ACTOR_BYTES: usize = 128;
const MAX_REASON_BYTES: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Cli {
    pub(crate) actor: AdminActor,
    pub(crate) command: Command,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct AdminActor(String);

impl AdminActor {
    fn parse(value: &str) -> Result<Self, CliError> {
        if value.is_empty()
            || value.len() > MAX_ACTOR_BYTES
            || value.trim() != value
            || !value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'@' | b'.' | b'_' | b':' | b'-')
            })
        {
            return Err(CliError::InvalidActor);
        }
        Ok(Self(value.to_owned()))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AdminActor {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("AdminActor").field(&"[set]").finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    CommentsList {
        status: String,
        cursor: Option<String>,
        limit: u32,
    },
    CommentsInspect {
        comment_id: Uuid,
    },
    CommentsHide {
        comment_id: Uuid,
        reason: String,
    },
    CommentsDelete {
        comment_id: Uuid,
        reason: String,
    },
    CommentsRestore {
        comment_id: Uuid,
    },
    ReportsResolve {
        report_id: Uuid,
        action: String,
    },
    UsersSuspend {
        user_id: Uuid,
        reason: String,
    },
    UsersReinstate {
        user_id: Uuid,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CliError {
    Help,
    MissingActor,
    InvalidActor,
    InvalidArguments,
    InvalidIdentifier,
    InvalidReason,
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Help => usage(),
            Self::MissingActor => "PAKPERK_ADMIN_ACTOR is required",
            Self::InvalidActor => "PAKPERK_ADMIN_ACTOR is invalid",
            Self::InvalidArguments => "invalid command arguments; use --help",
            Self::InvalidIdentifier => "identifier must be a canonical non-nil UUID",
            Self::InvalidReason => "reason/action must be a short stable code",
        })
    }
}

impl std::error::Error for CliError {}

pub(crate) fn parse(
    args: impl IntoIterator<Item = String>,
    actor: Option<&str>,
) -> Result<Cli, CliError> {
    let mut args = args.into_iter();
    let _program = args.next();
    let args = args.collect::<Vec<_>>();
    if args.iter().any(|value| value == "--help" || value == "-h") {
        return Err(CliError::Help);
    }
    let actor = AdminActor::parse(actor.ok_or(CliError::MissingActor)?)?;
    let command = parse_command(&args)?;
    Ok(Cli { actor, command })
}

fn parse_command(args: &[String]) -> Result<Command, CliError> {
    match args {
        [group, action, rest @ ..] if group == "comments" && action == "list" => {
            let options = list_options(rest)?;
            Ok(Command::CommentsList {
                status: options.status,
                cursor: options.cursor,
                limit: options.limit,
            })
        }
        [group, action, id] if group == "comments" && action == "inspect" => {
            Ok(Command::CommentsInspect {
                comment_id: identifier(id)?,
            })
        }
        [group, action, id, rest @ ..] if group == "comments" && action == "hide" => {
            Ok(Command::CommentsHide {
                comment_id: identifier(id)?,
                reason: reason_code(required_option(rest, "--reason")?)?,
            })
        }
        [group, action, id, rest @ ..] if group == "comments" && action == "delete" => {
            Ok(Command::CommentsDelete {
                comment_id: identifier(id)?,
                reason: reason_code(required_option(rest, "--reason")?)?,
            })
        }
        [group, action, id] if group == "comments" && action == "restore" => {
            Ok(Command::CommentsRestore {
                comment_id: identifier(id)?,
            })
        }
        [group, action, id, rest @ ..] if group == "reports" && action == "resolve" => {
            let action = required_option(rest, "--action")?;
            if !matches!(action, "reviewed" | "actioned" | "dismissed") {
                return Err(CliError::InvalidArguments);
            }
            Ok(Command::ReportsResolve {
                report_id: identifier(id)?,
                action: action.to_owned(),
            })
        }
        [group, action, id, rest @ ..] if group == "users" && action == "suspend" => {
            Ok(Command::UsersSuspend {
                user_id: identifier(id)?,
                reason: reason_code(required_option(rest, "--reason")?)?,
            })
        }
        [group, action, id] if group == "users" && action == "reinstate" => {
            Ok(Command::UsersReinstate {
                user_id: identifier(id)?,
            })
        }
        _ => Err(CliError::InvalidArguments),
    }
}

fn required_option<'a>(args: &'a [String], name: &str) -> Result<&'a str, CliError> {
    match args {
        [option, value] if option == name => Ok(value),
        _ => Err(CliError::InvalidArguments),
    }
}

struct ListOptions {
    status: String,
    cursor: Option<String>,
    limit: u32,
}

fn list_options(args: &[String]) -> Result<ListOptions, CliError> {
    let mut status = None;
    let mut cursor = None;
    let mut limit = 100_u32;
    let mut limit_seen = false;
    let mut chunks = args.chunks_exact(2);
    for chunk in &mut chunks {
        match chunk[0].as_str() {
            "--status" if status.is_none() => {
                if !matches!(
                    chunk[1].as_str(),
                    "pending_review" | "open" | "reviewed" | "actioned" | "dismissed"
                ) {
                    return Err(CliError::InvalidArguments);
                }
                status = Some(chunk[1].clone());
            }
            "--cursor" if cursor.is_none() && !chunk[1].is_empty() && chunk[1].len() <= 512 => {
                cursor = Some(chunk[1].clone());
            }
            "--limit" if !limit_seen => {
                limit_seen = true;
                limit = chunk[1]
                    .parse::<u32>()
                    .ok()
                    .filter(|value| (1..=100).contains(value))
                    .ok_or(CliError::InvalidArguments)?;
            }
            _ => return Err(CliError::InvalidArguments),
        }
    }
    if !chunks.remainder().is_empty() {
        return Err(CliError::InvalidArguments);
    }
    Ok(ListOptions {
        status: status.ok_or(CliError::InvalidArguments)?,
        cursor,
        limit,
    })
}

fn identifier(value: &str) -> Result<Uuid, CliError> {
    let id = Uuid::parse_str(value).map_err(|_| CliError::InvalidIdentifier)?;
    if id.is_nil() || id.hyphenated().to_string() != value {
        return Err(CliError::InvalidIdentifier);
    }
    Ok(id)
}

fn reason_code(value: &str) -> Result<String, CliError> {
    if value.is_empty()
        || value.len() > MAX_REASON_BYTES
        || value.trim() != value
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
    {
        return Err(CliError::InvalidReason);
    }
    Ok(value.to_owned())
}

pub(crate) const fn usage() -> &'static str {
    "pakperk-admin\n\
     Requires DATABASE_URL and PAKPERK_ADMIN_ACTOR in the environment.\n\
     Commands:\n\
       comments list --status <pending_review|open|reviewed|actioned|dismissed> [--cursor <cursor>] [--limit <1..100>]\n\
         (`pending_review` lists held comments; report statuses list report metadata.)\n\
       comments inspect <comment-id>\n\
       comments hide <comment-id> --reason <code>\n\
       comments delete <comment-id> --reason <code>\n\
       comments restore <comment-id>\n\
       reports resolve <report-id> --action <reviewed|actioned|dismissed>\n\
       users suspend <user-id> --reason <code>\n\
       users reinstate <user-id>"
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0198f4d7-a4ce-7b40-8ee8-4f350350810c";

    fn parse_args(args: &[&str]) -> Result<Cli, CliError> {
        parse(
            std::iter::once("pakperk-admin")
                .chain(args.iter().copied())
                .map(str::to_owned),
            Some("moderator@example.org"),
        )
    }

    #[test]
    fn parses_every_supported_command_without_accepting_credentials() {
        assert!(matches!(
            parse_args(&["comments", "list", "--status", "open"])
                .unwrap()
                .command,
            Command::CommentsList { status, cursor: None, limit: 100 } if status == "open"
        ));
        assert!(matches!(
            parse_args(&[
                "comments",
                "list",
                "--limit",
                "25",
                "--status",
                "pending_review",
                "--cursor",
                "opaque"
            ])
            .unwrap()
            .command,
            Command::CommentsList { status, cursor: Some(cursor), limit: 25 }
                if status == "pending_review" && cursor == "opaque"
        ));
        assert!(matches!(
            parse_args(&["comments", "inspect", ID]).unwrap().command,
            Command::CommentsInspect { .. }
        ));
        assert!(matches!(
            parse_args(&["comments", "hide", ID, "--reason", "harassment"])
                .unwrap()
                .command,
            Command::CommentsHide { .. }
        ));
        assert!(matches!(
            parse_args(&["comments", "delete", ID, "--reason", "legal_removal"])
                .unwrap()
                .command,
            Command::CommentsDelete { .. }
        ));
        assert!(matches!(
            parse_args(&["comments", "restore", ID]).unwrap().command,
            Command::CommentsRestore { .. }
        ));
        assert!(matches!(
            parse_args(&["reports", "resolve", ID, "--action", "dismissed"])
                .unwrap()
                .command,
            Command::ReportsResolve { .. }
        ));
        assert!(matches!(
            parse_args(&["users", "suspend", ID, "--reason", "repeat_abuse"])
                .unwrap()
                .command,
            Command::UsersSuspend { .. }
        ));
        assert!(matches!(
            parse_args(&["users", "reinstate", ID]).unwrap().command,
            Command::UsersReinstate { .. }
        ));
        assert_eq!(
            parse_args(&["--database-url", "postgres://secret"]).unwrap_err(),
            CliError::InvalidArguments
        );
    }

    #[test]
    fn actor_and_values_are_explicit_and_strict() {
        assert_eq!(
            parse(
                ["pakperk-admin", "comments", "inspect", ID].map(str::to_owned),
                None,
            )
            .unwrap_err(),
            CliError::MissingActor
        );
        assert_eq!(
            parse(
                ["pakperk-admin", "comments", "inspect", ID].map(str::to_owned),
                Some(" moderator "),
            )
            .unwrap_err(),
            CliError::InvalidActor
        );
        assert_eq!(
            parse_args(&[
                "comments",
                "inspect",
                "00000000-0000-0000-0000-000000000000"
            ])
            .unwrap_err(),
            CliError::InvalidIdentifier
        );
        assert_eq!(
            parse_args(&["comments", "hide", ID, "--reason", "raw body here"]).unwrap_err(),
            CliError::InvalidReason
        );
    }
}
