//! Application service for flat paper comments, reports, and user blocks.
//!
//! HTTP feature switches stay in the API app. This crate owns normalized UGC,
//! moderation orchestration, durable idempotency, and shared write limits.

mod service;

pub use service::{
    BlockUserResult, CommentService, CommentServiceConfig, CommentServiceConfigError,
    CommentServiceError, CreateCommentRequest, CreateCommentResult, DeleteCommentResult,
    EditCommentRequest, ReportCommentRequest, ReportCommentResult, ReportUserRequest,
    ReportUserResult, UnblockUserResult,
};
