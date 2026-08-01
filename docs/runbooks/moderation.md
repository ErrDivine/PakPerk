# Comment moderation runbook

**Owner:** the designated Pakperk Trust & Safety on-call operator.
**Backup:** the production incident commander.
**Public-enablement state:** the controls are implemented but blocked until the
support route, account deletion, retention, store review, monitoring, staffing,
and this runbook are exercised in the target environment.

## Response targets

| Class | Examples | Triage target | Initial action |
|---|---|---:|---|
| Critical | credible threat, child sexual exploitation, imminent self-harm, exposed credentials/private location | 1 hour | preserve minimal evidence, hide, escalate immediately |
| High | doxxing, targeted harassment, hate, non-consensual intimate content, malicious link | 4 hours | hide or hold, inspect account history, escalate as needed |
| Standard | spam, impersonation, copyright, ordinary abuse | 2 business days | review report and apply documented action |

Targets begin only when the production alert/ticket integration is live. The
operator records every decision through `pakperk-admin`; direct SQL is not an
ordinary moderation workflow.

## Queue workflow

1. Review comment-report and user-report queues and their combined oldest-age
   metric without printing comment bodies or report detail. Use
   `comments list --status open` for comment reports and
   `user-reports list --status open` for user reports.
2. Select one report ID. Use `comments inspect <comment-id>` for the associated
   comment or `user-reports inspect <report-id>` for one user report.
3. Classify using stable reason/action codes; do not copy content into chat,
   logs, shell history, or an incident title.
4. Hide immediately when continued display creates credible harm. Restore only
   after a second look for high/critical reversals.
5. Resolve/dismiss the report with `reports resolve` or
   `user-reports resolve` and record the action. Suspend repeat or severe
   offenders; reinstate only with a recorded reason.
6. Escalate legal requests, child-safety material, credible threats, or urgent
   privacy exposure to the configured qualified operator. Do not download or
   redistribute illegal material.
7. Verify the audit event, queue age, and public result.

`pakperk-admin` derives the audit actor from a provider-authenticated operator;
the caller cannot supply an actor label. Before invoking it, complete a recent
OIDC authentication and place the short-lived access token in an absolute,
owner-only (`0600`), non-symlink regular file. Configure
`ADMIN_OIDC_ISSUER_URL`, `ADMIN_OIDC_AUDIENCE`, and
`PAKPERK_ADMIN_ACCESS_TOKEN_FILE`. Set `ADMIN_AUTHORIZED_USER_IDS` to a
comma-separated, change-controlled allowlist of canonical local Pakperk user
UUIDs for current Trust & Safety operators; an authenticated account outside
that allowlist has no admin permission. Keep `ADMIN_OIDC_ALLOWED_ALGORITHMS` at
its `RS256` default unless the identity owner has approved another bounded
allow list. `ADMIN_AUTH_MAX_AGE_SECONDS` defaults to 15 minutes and may be
60–3,600 seconds. Plain HTTP discovery is forbidden except for an explicitly
enabled loopback-only development issuer using
`ADMIN_OIDC_ALLOW_INSECURE_HTTP=true`; never enable it in staging or
production.

At startup the CLI verifies discovery/JWKS transport, signature, issuer,
audience, expiry, and the OIDC `auth_time` claim. Token `iat` is never accepted
as proof of a recent interactive login. It then maps the verified
`(issuer, subject)` to an existing active Pakperk account without provisioning
or updating one and checks the local UUID against the operator allowlist; that
UUID is the audited actor. Missing `auth_time`, stale, unknown, unauthorized,
suspended, deletion-pending, unsafe-file, or otherwise invalid identity fails
closed before any command runs. Remove the token file after the operator
session and follow the incident runbook if it may have been exposed. Revoke an
operator by removing the UUID from the deployment secret/configuration and
rolling the admin job before disabling the identity-provider account.

List commands never print full bodies. Only an explicit inspect command may
display one body, and operators must use an ephemeral terminal with database
and identity credentials supplied outside shell history. Never pass the token,
an email address, or a self-selected actor value as a command argument or
environment value.

## Emergency controls

- Set `COMMENT_CREATION_ENABLED=false` to stop new posts while preserving
reading, comment/user reporting, blocking, author removal, and moderation.
- Set `COMMENTS_ENABLED=false` only when the entire comments surface must be
  withdrawn; guest paper reading must remain healthy.
- Suspected credential exposure follows the incident runbook and secret
  rotation; never paste the credential into a report.

`API_ORIGIN_HASH_SECRET_FILE` is a rotation-sensitive abuse-control secret,
not an IP archive. It must remain an owner-only, non-symlink regular file with
32–4,096 non-placeholder bytes. A replacement changes every origin digest and
therefore starts fresh origin buckets (account buckets are unaffected). Rotate
deliberately while the queue and abuse-rate dashboards are staffed; roll every
replica, retain the old deployment secret only until the previous replicas and
rate windows expire, then destroy it. Never log either secret or a raw peer
address during validation.

`API_TRUSTED_PROXY_CIDRS` must contain only the source ranges actually
observed from the ingress-controller chain. The API accepts
`X-Forwarded-For` only when the direct peer is in those ranges and walks the
chain right-to-left; malformed or missing metadata falls back to the direct
peer. Before changing the list, confirm the NetworkPolicy still admits only the
reviewed ingress-controller namespace/pods, verify the controller appends the
connection address, and test both a normal client and a spoofed leftmost entry
in staging. Never add an internet-wide range.

Before re-enabling creation, clear the incident cause, drain the open queue,
test a published and held staging comment, confirm alerts/age metrics, and
record the approving operator and timestamp.
