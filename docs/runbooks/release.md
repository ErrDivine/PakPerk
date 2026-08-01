# Release, migration, rollback, and store-candidate runbook

**Owner:** release manager. **Approvers:** service owner, database owner,
privacy/safety owner, and mobile signing owner for store candidates.

Repository automation builds candidates and fails closed on missing evidence.
It does not establish live backups, approve production, sign with unavailable
keys, publish legal pages, upload store builds, or manufacture performance and
crash evidence.

## Candidate inputs

- A clean reviewed revision with `./scripts/check.sh` passing and every explicit
  skip resolved for the target environment.
- A successful protected `publish-release-images` workflow for that exact full
  revision. Promotion must consume `promotion-handoff.json`; copying a mutable
  tag or manually substituting an unscanned digest is not release evidence.
- Matching `0.2.0` Rust workspace, Helm `appVersion`, and mobile version name;
  the mobile build number must exceed both stores' highest uploaded value.
- Immutable backend/site/GROBID/Collector image digests and successful
  vulnerability/license/secret scans, generated CycloneDX SBOMs, notices, and
  checksums. Mobile evidence must include the production-runtime Maven SBOM,
  both matching SwiftPM locks, and the checksum-complete Gradle policy.
- Exact HTTPS origins, OIDC realm/clients/redirects, support contact, legal
  version, Play app-signing fingerprint, Apple team/bundle ID, reviewed egress
  CIDRs, ingress proxy source CIDRs, database roles, deletion-ledger claim,
  secret rotation version, OTLP endpoint, and verified backup ID.
- An approved strict-content review and the external evidence listed under
  [mobile release blockers](../mobile-release.md#external-release-blockers).

## Release-evidence binding scope

The chart's six `releaseEvidence` values are content IDs for protected,
canonical evidence manifests, not change numbers, workflow run IDs, ticket
URLs, or hashes of an operator's assertion. Each manifest must identify its
owner and approver, UTC verification window, target environment, exact source
revision and deployed/candidate build identities, evidence-artifact digests,
outcome, and approval timestamp. A digest has no evidentiary value unless the
protected release system can retrieve and verify those bytes.

| Chart value | Required scope | Owner |
| --- | --- | --- |
| `legalReviewId` | Exact published legal/support versions, actual enabled data/processors and retention, public URL checks, and approval | privacy/legal owner |
| `reviewerFlowId` | Disposable reviewer-account lifecycle and sanitized exact-candidate reviewer steps for guest, account, safety, and deletion paths | store release owner |
| `strictContentReviewId` | Exact strict backend/mobile policy, displayed and retained introduction behavior, metadata-only behavior, and qualified content-rights approval | legal/content owner |
| `moderationReadinessId` | Protected live comment/user-report/comment-report/block/admin and kill-switch flow; dedicated operator audience/allowlist rejection matrix; moderation fallback; sanitized output; staffed response targets; support/deletion/retention dependencies; and alert/ticket canary | Trust & Safety owner |
| `accountDeletionE2eId` | Protected staging recent-auth request through provider/session/app-data completion using the real secret manager, independent ledger, and alert route | privacy/on-call owner |
| `restoreDrillId` | Isolated PostgreSQL/Keycloak restore, exact current-ledger count, reapply/finalize results, RPO/RTO, and recovery/privacy approvals | database and privacy owners |

These bindings cover server deployment obligations whose applicability follows
the production feature map. They deliberately do **not** turn Helm into the
release ledger for image publication/security scans, public-edge checks,
staging load, migration/rollback exercise, live telemetry retention/alert
routing, signed mobile candidates, physical-device performance/crash windows,
or store submission/review. Those gates bind to an exact candidate in the
protected release record and in their named workflow/store evidence. A dark
Helm rollout does not satisfy them, and their absence still blocks public/store
release even when `helm template` succeeds.

The manual `live comments acceptance` workflow is a disposable reference-stack
regression lane, not protected staging. Its evidence has a closed safety schema
and the non-assertive environment classification
`manual_ci_disposable_reference`; it does not attest GitHub environment
protection. Its domain-separated `reference-sha256:` ID is intentionally
invalid for production `moderationReadinessId`; do not copy its artifact
checksum or Actions run ID into that field. The target-environment record must
satisfy the complete
[moderation readiness matrix](moderation.md#acceptance-and-production-readiness-evidence)
for the exact deployed candidate before comment creation can be enabled.

## Pre-deploy gates

1. Freeze the revision and attach CI/security results. Verify every GitHub
   Action is pinned to a real reviewed commit, not only a mutable tag comment.
   Run `publish-release-images` from `main` with the reviewed full commit SHA
   and target protected environment. Require both vulnerability scans, both
   image SBOMs, and the digest-only Helm handoff artifact before deployment.
2. Verify the backup using [backup-restore.md](backup-restore.md). Put its
   evidence ID in `migration.confirmBackupId`.
3. Render the exact protected values with `helm lint` and `helm template`; run
   `scripts/validate_helm_release.sh`. Compare rendered hosts, identities,
   grants, images, NetworkPolicies, retention, feature flags, and commands to
   the change record. Confirm no worker poll interval reaches its lease, the
   deletion retry base is below its maximum, ledger retention covers security
   retention, each termination grace budget covers its maximum request/lease,
   and the trusted-proxy list contains at most 64 canonical ranges. Verify the
   four tag-free, at-most-255-character OCI repositories, distinct lowercase
   external FQDNs, Kubernetes names/labels/selectors, resources whose requests
   do not exceed limits, and PDB values came from the protected release
   manifest. The repository staging fixture is never deployable.
4. Confirm the migration role alone can perform DDL; application roles cannot.
   Confirm worker, API, and synchronization roles use distinct Secret keys.
5. Confirm the deletion worker's `manage-users`-only service account readiness,
   current independent ledger, and alert coverage before enabling deletion.
6. Verify live legal/support/association documents return direct HTTPS 200 with
   expected content types. Verify Nginx real-IP trust and API-observed ingress
   source ranges before relying on comment origin limits.
7. Apply the reviewed `deploy/helm/ingress-nginx-production-values.yaml` to the
   pinned TLS controller release and run
   `scripts/verify_public_edge.sh SITE_ORIGIN API_ORIGIN TELEMETRY_ORIGIN`.
   Exact HTTP redirects and one
   `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
   header on every public origin are release-blocking.

## Expand/contract deployment

1. Use additive/nullable tables, columns, indexes, and dual-compatible code for
   the expand release. Never combine destructive contraction with the first
   code rollout that stops using a field.
2. Run the chart migration Job once, with the reviewed image digest, distinct
   migration database role, `RUN_MIGRATIONS=false` everywhere else, expected
   embedded migration version `10`, and a bounded non-placeholder backup
   evidence ID. The scheduled metadata manifest must be valid JSON containing
   1 to 2,000 canonical arXiv IDs within the chart's 1,048,000-byte ConfigMap
   boundary, and its bounded five-field Cron expression must render
   successfully. Save Job logs/status without secrets. A failed or timed-out
   migration blocks rollout.
3. Roll out the deletion worker and verify readiness, then paper worker,
   metadata sync, telemetry gateway/Collector, API, and site. Keep the
   account-backed surface (including deletion), library writes, and comment
   creation dark until their dependencies and smoke checks pass. Production
   account enablement requires deletion to be enabled at the same time.
4. Exercise guest cached reading first, then authenticated profile/library,
   comments/report/block/moderation, deletion request/status/web callback, paper
   preparation, telemetry redaction/export, and association links. Capture
   aggregate status/latency only.
5. Exercise the independent kill switches. `LIBRARY_WRITES_ENABLED=false`
   preserves reads; `COMMENT_CREATION_ENABLED=false` preserves comment/safety
   reads/actions; disabling accounts does not make guest reading depend on
   OIDC. Account deletion remains enabled whenever production accounts are
   enabled, including a comments-disabled library release.
6. Observe error rate, readiness, database saturation, queue/backlog age,
   moderation SLA, deletion failures, OTLP drops, and ingress errors through the
   release observation window. Record the exact window and approver.

Contraction is a separate release only after every serving/worker version is
compatible, the compatibility window and rollback retention have elapsed, and
another verified backup exists. Exercise the migration and rollback sequence in
staging; a rendered command is not evidence of execution.

## Rollback

Prefer a forward code rollback to the last schema-compatible image plus feature
kill switches. Do not run destructive down migrations. If the new schema is
backward compatible, roll back API/site/workers and preserve the expanded
schema. If data corruption or an incompatible migration requires restore,
declare an incident, isolate writes, follow [backup-restore.md](backup-restore.md),
mount the current deletion ledger, and reapply deletions before traffic.

Never restore only PostgreSQL while leaving deletion obligations behind. Never
roll a mobile store build backward: increment the build and ship a corrected
candidate.

## Signed mobile/store handoff

Run the manual environment-gated `signed-mobile-release` workflow. It validates
flavor configuration, signing/profile identity, AAB/APK/IPA metadata,
entitlements/links, strict bundled assets, symbols, notices, SBOM, and evidence
hashes. The workflow is fixed to the macOS 26 runner contract, Xcode 26.6 build
17F113, Flutter 3.44.8 framework revision
`058e0af2c2b57e369d905a03ac9748b0ebf543c6` with Dart 3.12.2, Temurin
17.0.19+10 from `JAVA_HOME_17_arm64`, MRI Ruby 3.4.10, RubyGems 4.0.17, and a
frozen Bundler 2.6.9/Fastlane 2.235.0 graph with RubyGems checksums. The Ruby
engine and exact runtime are verified and recorded before any gem installation
or Bundler execution. Bundler itself is downloaded by exact version, SHA-256
verified, and installed locally; absence of any exact toolchain fails the
candidate. Dispatch from `main` with the reviewed full commit SHA;
the workflow rejects an exact-checkout or `origin/main` ancestry mismatch. The
Android upload-key digest proves candidate custody; association
files use the distinct protected Play App Signing digest. See
[mobile-release.md](../mobile-release.md).

Store owners must supply a disposable reviewer account with verified email,
accepted current terms, no real-user data, no privileged role, and a rotation/
expiry owner. Review notes describe guest reading, sign-in, report/block,
account deletion, web deletion URL, strict metadata/full-text behavior, and any
staging-only coordinates. Credentials stay in store portals, never Git/issues.
Start from the sanitized
[store reviewer-notes template](../store/reviewer-notes-template.md) and keep
every bracketed evidence field release-blocking until the exact candidate is
verified.

TestFlight/closed Play upload, physical-device deep links/callbacks/deletion,
current Data Safety/App Privacy/age-rating forms, review status, measured
startup/cache targets, and a representative crash-free observation window are
external gates. Mark each with evidence or leave the release blocked.
