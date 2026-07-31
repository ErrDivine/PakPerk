//! Account policy and orchestration for Pakperk.
//!
//! OIDC token verification stays in the `auth` crate and HTTP details stay in
//! the API app. This crate accepts only a previously verified issuer/subject
//! pair, maps it to a server-owned user ID, and applies profile policy around
//! the `PostgreSQL` repositories.

mod service;

pub use service::{
    AccountPolicy, AccountPolicyError, AccountService, AccountServiceError, AccountStore,
    PatchValue, ProfileUpdateCommand, RateLimitStore, VerifiedIdentity,
};
