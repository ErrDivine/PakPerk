# Comment moderation runbook

**Owner:** the designated Pakperk Trust & Safety on-call operator.
**Backup:** the production incident commander.
**Public-enablement state:** blocked until the support route, account deletion,
retention policy, store review, monitoring, and this runbook are exercised in
the Phase 6 environment.

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

1. Review open-report count and oldest age without printing comment bodies.
2. Select one report ID and explicitly inspect the associated record.
3. Classify using stable reason/action codes; do not copy content into chat,
   logs, shell history, or an incident title.
4. Hide immediately when continued display creates credible harm. Restore only
   after a second look for high/critical reversals.
5. Resolve/dismiss the report and record the action. Suspend repeat or severe
   offenders; reinstate only with a recorded reason.
6. Escalate legal requests, child-safety material, credible threats, or urgent
   privacy exposure to the configured qualified operator. Do not download or
   redistribute illegal material.
7. Verify the audit event, queue age, and public result.

Admin actor identity is explicit and actions are audited. List commands never
print full bodies. Only an explicit inspect command may display one body, and
operators must use an ephemeral terminal with production credentials supplied
outside shell history.

## Emergency controls

- Set `COMMENT_CREATION_ENABLED=false` to stop new posts while preserving
  reading, report/block, author removal, and moderation.
- Set `COMMENTS_ENABLED=false` only when the entire comments surface must be
  withdrawn; guest paper reading must remain healthy.
- Suspected credential exposure follows the incident runbook and secret
  rotation; never paste the credential into a report.

`COMMENT_ORIGIN_HASH_SECRET_FILE` is a rotation-sensitive abuse-control secret,
not an IP archive. It must remain an owner-only, non-symlink regular file with
32–4,096 non-placeholder bytes. A replacement changes every origin digest and
therefore starts fresh origin buckets (account buckets are unaffected). Rotate
deliberately while the queue and abuse-rate dashboards are staffed; roll every
replica, retain the old deployment secret only until the previous replicas and
rate windows expire, then destroy it. Never log either secret or a raw peer
address during validation.

Before re-enabling creation, clear the incident cause, drain the open queue,
test a published and held staging comment, confirm alerts/age metrics, and
record the approving operator and timestamp.
