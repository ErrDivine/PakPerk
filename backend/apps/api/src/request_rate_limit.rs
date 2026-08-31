use std::{net::SocketAddr, time::Duration};

use axum::http::HeaderMap;
use db::{DbError, RateLimitRepository, RateLimitRequest};
use uuid::Uuid;

use crate::config::RequestOriginConfig;

const RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);

#[derive(Clone, Copy)]
struct Policy {
    bucket: &'static str,
    limit: u32,
}

#[derive(Clone, Copy)]
pub(crate) enum PublicRequestAction {
    Prepare,
    Chat,
    PaperSearch,
}

#[derive(Debug)]
pub(crate) enum PublicRequestRateLimitError {
    RateLimited { retry_after_seconds: u64 },
    Storage(DbError),
    InvalidConfiguration,
}

#[derive(Clone)]
pub(crate) struct PublicRequestRateLimiter {
    repository: RateLimitRepository,
    origin: RequestOriginConfig,
    prepare: Policy,
    chat: Policy,
    paper_search: Policy,
}

impl PublicRequestRateLimiter {
    pub(crate) fn new(
        repository: RateLimitRepository,
        origin: RequestOriginConfig,
        prepare_limit: u32,
        chat_limit: u32,
        paper_search_limit: u32,
    ) -> anyhow::Result<Self> {
        let limiter = Self {
            repository,
            origin,
            prepare: Policy {
                bucket: "paper_prepare",
                limit: prepare_limit,
            },
            chat: Policy {
                bucket: "paper_chat",
                limit: chat_limit,
            },
            paper_search: Policy {
                bucket: "paper_search_origin",
                limit: paper_search_limit,
            },
        };
        for (policy, scope) in [
            (limiter.prepare, format!("origin:{}", "0".repeat(64))),
            (limiter.chat, format!("session:{}", Uuid::nil())),
            (limiter.paper_search, format!("origin:{}", "0".repeat(64))),
        ] {
            RateLimitRequest::new(policy.bucket, scope, policy.limit, RATE_LIMIT_WINDOW)
                .map_err(|_| anyhow::anyhow!("public request rate-limit policy is invalid"))?;
        }
        Ok(limiter)
    }

    pub(crate) fn origin_scope(&self, headers: &HeaderMap, peer: SocketAddr) -> String {
        self.origin.scope(headers, peer)
    }

    pub(crate) async fn check(
        &self,
        action: PublicRequestAction,
        headers: &HeaderMap,
        peer: SocketAddr,
        session_id: Option<Uuid>,
    ) -> Result<(), PublicRequestRateLimitError> {
        let policy = match action {
            PublicRequestAction::Prepare => self.prepare,
            PublicRequestAction::Chat => self.chat,
            PublicRequestAction::PaperSearch => self.paper_search,
        };
        self.consume(
            policy,
            format!("origin:{}", self.origin_scope(headers, peer)),
        )
        .await?;
        if let Some(session_id) = session_id {
            self.consume(policy, format!("session:{session_id}"))
                .await?;
        }
        Ok(())
    }

    async fn consume(
        &self,
        policy: Policy,
        scope: String,
    ) -> Result<(), PublicRequestRateLimitError> {
        let request = RateLimitRequest::new(policy.bucket, scope, policy.limit, RATE_LIMIT_WINDOW)
            .map_err(|_| PublicRequestRateLimitError::InvalidConfiguration)?;
        let decision = self
            .repository
            .check(&request)
            .await
            .map_err(PublicRequestRateLimitError::Storage)?;
        if decision.allowed {
            Ok(())
        } else {
            Err(PublicRequestRateLimitError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            })
        }
    }
}
