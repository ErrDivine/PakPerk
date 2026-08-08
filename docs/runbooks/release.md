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
- Protected target evidence for release-issuer key rotation/removal, exact
  library and comment operation replays, cross-replica shared limiting, and each
  independently controlled feature/kill switch, as specified below.
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
| `restoreDrillId` | Isolated PostgreSQL/Keycloak restore, exact current-ledger count, external inventory digest, local ledger/job-binding digest continuity, exact `public, pg_catalog` mutation-session binding, attested change marker used as the reapply audit actor, schema-2/v2 reapply/finalize packages with the actual prior package reverified for ID/attestation/chronology/core-count continuity, RPO/RTO, and recovery/privacy approvals | database and privacy owners |

These bindings cover server deployment obligations whose applicability follows
the production feature map. They deliberately do **not** turn Helm into the
release ledger for image publication/security scans, public-edge checks,
staging load, migration/rollback exercise, live telemetry retention/alert
routing, the protected auth/write/switch exercise, signed mobile candidates,
physical-device performance/crash windows, or store submission/review. Those
gates bind to an exact candidate in the protected release record and in their
named workflow/store evidence. A dark Helm rollout does not satisfy them, and
their absence still blocks public/store release even when `helm template`
succeeds.

## Release-image publication trust boundary

`publish-release-images` uses three fresh GitHub-hosted runners. The `build`
job has `contents: read` only, has no protected environment, and is the only job
that checks out or executes candidate source or resolved build dependencies. It
builds the exact `sha-<source_revision>` backend and site tags and freezes each
image with `docker save`. Its archive IDs, hashes, and metadata are deliberately
classified as an **untrusted build handoff**: a surviving candidate process can
change any same-runner output, so no scan or publication decision trusts that
job's observations. The raw handoff is uploaded with compression disabled and
passed onward only by the upload service's immutable artifact ID and digest.

The `scan` job is a separate, uncredentialed runner with `permissions: {}`, no
checkout, and no candidate-authored program or container execution. It
downloads the raw build artifact by ID with digest mismatch failure, rejects a
non-canonical/duplicate-key manifest and any extra, symlinked, linked,
non-runner-owned, mutable, empty, or oversized member, rehashes both archives,
loads but never runs them, and derives the exact expected tag-to-image-ID
mapping again. It makes the input tree read-only before four pinned Trivy
operations consume the downloaded archive bytes: two blocking vulnerability
scans and two CycloneDX image SBOM generations. Because candidate processes
cannot cross the job boundary, they cannot race the scan reports, SBOMs,
post-scan archive hashes, trusted manifest, or upload.

After rehashing both archives again, the fresh scan job creates canonical
`release-image-handoff.json`. Its closed schema binds the target environment,
source revision, exact repositories and tags, derived image IDs, Docker archive
names and SHA-256 digests, every scan/SBOM/toolchain/dependency/notices digest,
and the untrusted build artifact ID, artifact digest, and manifest digest. The
closed handoff surface is made read-only and uploaded with compression disabled
under a second immutable artifact ID/digest. Both intermediate artifacts are
retained for one day and are not deployment approval.

The protected `publish` job starts on a third fresh runner, depends only on the
completed scan job, and alone has `packages: write` plus the selected protected
environment. It has no checkout and executes no candidate-authored program or
container. With `PATH` fixed and `BASH_ENV`/`ENV` pinned to `/dev/null`, it
downloads the scanned handoff by artifact ID, checks both scan-artifact and
upstream build-artifact provenance plus source/environment bindings, rejects
non-canonical or duplicate-key manifests and any extra/symlink/mutable file,
and rehashes every archive and evidence member. It then loads the two Docker
archives without running them and requires the loaded tag-to-image-ID mapping
to equal the scanned manifest before registry authentication.

`GITHUB_TOKEN` is bound only to the exact push step. That step pushes only the
two reconstructed commit tags and requires exactly one registry-reported digest
per push. The final canonical `promotion-handoff.json` contains those registry
digests plus the scanned-artifact ID, scanned-artifact container digest, and
scanned-manifest digest. `SHA256SUMS` covers the promotion handoff, scanned and
untrusted-build manifests, scans, SBOMs, toolchain record, dependency inventory,
and notices in the 90-day publication artifact. Promotion must verify those
bytes and use the digest-only Helm values; it must never rebuild, retag, or
substitute a local daemon digest.

Environment reviewers must treat fresh-job isolation as part of the approval
boundary. Do not merge `build` and `scan`, convert `scan` or `publish` to a
self-hosted runner that can retain a candidate process or Docker daemon, add a
checkout or candidate hook to either fresh job, grant a token permission or
protected environment to `scan`, grant `packages: write` to `build`, download
either handoff by mutable artifact name, or expose the registry token before
the archive and loaded image-ID checks.

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

## Public-edge technical evidence

Run the manual `public edge verification` workflow against the dark-deployed
staging or production candidate before enabling features or submitting a store
build. Dispatch it from `main` with all four required inputs:

- `source_revision`: the reviewed full lowercase commit SHA, which must equal
  the selected workflow revision, checked-out `HEAD`, and fetched
  `origin/main` tip;
- `target_environment`: exactly `staging` or `production`;
- `candidate_id`: `sha256:` followed by the exact digest of
  `promotion-handoff.json` recorded in the protected image-publication
  artifact's verified `SHA256SUMS`; and
- `confirmation`: exactly `RUN_PUBLIC_EDGE_VERIFICATION`.

Configure these non-secret variables on each named GitHub environment. They
are protected release coordinates, not dispatch-controlled hosts:

```text
PAKPERK_SITE_ORIGIN
PAKPERK_API_ORIGIN
PAKPERK_TELEMETRY_ORIGIN
PAKPERK_OIDC_ISSUER
PAKPERK_WEB_OIDC_CLIENT_ID
PAKPERK_SUPPORT_EMAIL
PAKPERK_PUBLIC_DOCUMENT_VERSION
PAKPERK_ANDROID_PACKAGE
PAKPERK_ANDROID_SHA256
PAKPERK_APPLE_TEAM_ID
PAKPERK_APPLE_BUNDLE_ID
```

The verifier makes proxy-free, credential-free, redirect-disabled requests to
publicly resolved 80/443 addresses with bounded DNS, connect, total-request,
header, and body limits. It checks exact HTTP-to-HTTPS redirects; TLS and HSTS;
the runtime configuration; distinct stable HTML routes and their security/cache
headers; the notices source-revision marker; Android and Apple association
identities; the API readiness response contract; and telemetry-gateway process
readiness. A failed observation still produces a closed, owner-only sanitized
failure statement, then the workflow fails after retaining the exact-source
artifact. Raw bodies, headers, transport errors, cookies, credentials, support
address, and operator identity are not retained.

The artifact's `public-edge-sha256:` content ID is deliberately not a Helm
`releaseEvidence` approval ID. The requested candidate ID is release-record
context and is not observed at the edge. The public notices marker observes the
site source revision only; it does not prove the API image, Pod image IDs, Helm
release, or whole deployment provenance. Before promotion, a platform owner
must separately compare actual Pod `imageID` values and the immutable rendered
release-binding ConfigMap/digest with the protected promotion handoff and
release record.

This technical lane also does not approve legal text or disclosures, attest
GitHub environment reviewer/branch settings, prove signed-candidate custody,
exercise physical-device universal links, complete authenticated account
deletion, or prove Collector/export/sink delivery. Retain those approvals and
protected live canaries separately; reference the retrievable public-edge
artifact digest, workflow run/time, target, and outcome from the release
ledger.

## Pre-deploy and pre-enable gates

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
   Each runtime role must have only `USAGE` on `public` plus column-level
   `SELECT (version, success, checksum)` on `public._sqlx_migrations` for the
   shared readiness check; it must have no migration-history write privilege.
   Exercise readiness through every exact role after the migration: a missing,
   failed, old, gapped, or checksum-divergent embedded history must fail closed.
5. Confirm the deletion worker's `manage-users`-only service account readiness,
   current independent ledger, and alert coverage before enabling deletion.
6. Apply the reviewed `deploy/helm/ingress-nginx-production-values.yaml` to the
   pinned TLS controller release. Verify Nginx real-IP trust and API-observed
   ingress source ranges before relying on comment origin limits. Do not infer
   a public-edge pass from Helm rendering or the configured hosts.

## Protected auth, write, and switch exercise

Run this gate against the exact dark-deployed candidate and its release-shaped
topology in protected staging. Use only approved synthetic papers, disposable
accounts, and bounded non-production quotas. Identity, service, database,
platform, and release owners approve the run; privacy/safety also approves any
authenticated UGC. Keep credentials, bearer tokens, raw network addresses, raw
comment bodies, and provider key material out of evidence.

The closed evidence package must bind the source revision, deployed image IDs,
rendered release values, database identity, serving-replica topology, release
issuer/discovery/JWKS identities, UTC window, assertion counts, cleanup result,
and approvers. It must prove all of these behaviors:

1. Perform an identity-owner-approved signing-key rotation on the configured
   release issuer. Record only the old and replacement `kid` values and the
   configured `OIDC_JWKS_CACHE_TTL_SECONDS`. Accept an unexpired access token
   signed by the replacement key. Remove the old key from JWKS, wait beyond the
   configured cache bound, and prove an otherwise unexpired old-key token is
   rejected with HTTP 401 `UNAUTHENTICATED`. Separately prove an expired token
   returns HTTP 401 `TOKEN_EXPIRED` and that the protected mobile expiry path
   performs one successful refresh. Restoring or retiring provider keys is an
   identity-owner action and must be recorded without retaining token/key bytes.
2. Send one library mutation twice with byte-equivalent intent, the same
   `Idempotency-Key`, and the same body `operation_id`; then send one comment
   creation twice with the same paper, normalized body, and
   `client_request_id`. Require HTTP 200 for both library responses with the
   same canonical paper/state/revision, then HTTP 201 followed by replay HTTP
   200 for the same canonical comment ID/status/body digest. Require exactly one
   durable library operation/side effect and one durable comment. Record only
   IDs or digests approved for evidence, aggregate row counts, statuses, and
   assertion results; never raw UGC.
3. Identify at least two simultaneously serving API replicas through protected
   platform attribution. Within one configured shared quota/window, route
   accepted requests through both replicas, exhaust the chosen safe action
   bucket through one replica, and route the next request through the other.
   Require HTTP 429, the exact `RATE_LIMITED` error code, a valid delta-seconds
   `Retry-After`, and success after the attested reset. Record the action,
   configured quota/window, per-replica aggregate counts, shared database
   identity, and reset result; do not retain a raw IP or account identifier.
4. Starting from the approved baseline, change only one switch at a time and
   retain the rendered before/after value plus observed allowed and disabled
   paths for `ACCOUNTS_ENABLED`, `LIBRARY_ENABLED`,
   `LIBRARY_WRITES_ENABLED`, `COMMENTS_ENABLED`,
   `COMMENT_CREATION_ENABLED`, and `ACCOUNT_DELETION_ENABLED`. Exercise only
   valid dependency combinations, restore and verify the baseline between
   cases, and retain fail-closed validation for invalid combinations. In
   particular, library-write disablement preserves library reads, disabling
   comment creation preserves comment/safety reads and actions, disabling
   accounts preserves guest reading, and production accounts cannot be
   accepted with account deletion disabled.

A repository test, one process with two repository objects, a load-balancer
request that cannot identify the serving replica, a fresh UUID on every write,
or a rendered flag without an observed request result does not satisfy this
protected gate.

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
4. Dispatch `public edge verification` for this exact dark-deployed target and
   attach its passing artifact to the release ledger. A missing/failed artifact,
   a source marker mismatch, or any redirect/header/config/document/association/
   readiness mismatch blocks feature enablement and store submission.
5. Exercise guest cached reading first, then authenticated profile/library,
   comments/report/block/moderation, deletion request/status/web callback, paper
   preparation, telemetry redaction/export, and association links. Complete the
   [protected auth, write, and switch exercise](#protected-auth-write-and-switch-exercise)
   for the same candidate. Capture only the bounded, sanitized results defined
   by each evidence contract.
6. Reconcile all six switch results with the final rendered feature
   map. Do not infer a switch pass from a healthy baseline smoke, and do not
   reuse evidence after any relevant image, issuer, quota, topology, or feature
   map change. Account deletion remains enabled whenever production accounts are
   enabled, including a comments-disabled library release.
7. Observe error rate, readiness, database saturation, queue/backlog age,
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

Never restore only PostgreSQL while leaving deletion obligations behind. A
store action never downgrades an already installed mobile binary: increment the
build and ship a corrected candidate. The separately approved Android-only
full-release halt described below is a distribution fallback for new/eligible
users, not an installed-binary rollback.

## Signed mobile/store handoff

Run the manual `signed-mobile-release` workflow. Its signing and upload jobs are
environment-gated, while preparation, assembly, bootstrap, and finalization
remain credential-free. It validates flavor configuration, signing/profile
identity, AAB/APK/IPA metadata,
entitlements/links, strict bundled assets, symbols, notices, SBOM, and evidence
hashes. Credential-free preparation publishes the immutable configuration
binding before candidate execution; independent fresh Android and iOS signers
rederive it and receive only their own signing family. A credential-free
assembler creates the combined candidate/provenance, an uncredentialed
bootstrap packages the frozen store client and literal-hashed controls, fresh
no-checkout platform upload jobs receive only their own store credential, and
an always-run credential-free finalizer retains both requested outcomes. The
workflow is fixed to the macOS 26 runner contract, Xcode 26.6 build
17F113, Flutter 3.44.8 framework revision
`058e0af2c2b57e369d905a03ac9748b0ebf543c6` with Dart 3.12.2, Temurin
17.0.19+10 from `JAVA_HOME_17_arm64`, MRI Ruby 3.4.10, RubyGems 4.0.17, and a
frozen Bundler 2.6.9/Fastlane 2.235.0 graph with RubyGems checksums. The Ruby
engine and exact runtime are verified and recorded before any gem installation
or Bundler execution. Bundler itself is downloaded by exact version, SHA-256
verified, and installed locally; absence of any exact toolchain fails the
candidate. Dispatch from `main` with the reviewed full commit SHA;
the workflow rejects an exact-checkout or `origin/main` ancestry mismatch, and
the retained signed-release source must equal its recorded workflow revision.
The Android upload-key digest proves candidate custody; association
files use the distinct protected Play App Signing digest. See
[mobile-release.md](../mobile-release.md).

Public promotion is a second protected handoff. An uncredentialed bootstrap
checks out and binds trusted tooling to the reviewed `github.workflow_sha`,
separately from the data-only immutable candidate source, and packages an
immutable store-client/control closure. Fresh platform mutation jobs perform no
checkout and verify every executable against workflow-literal SHA-256 values
before they materialize only that platform's credential; candidate-authored
tooling never receives store credentials. Before candidate artifacts or
credentials, the bootstrap must authenticate the supplied run through the
GitHub Actions API as the exact successful, completed `workflow_dispatch` of
`.github/workflows/mobile-release.yml` from `main`, with matching source SHA,
run attempt and repository, plus the exact all-success eight-job surface:
credential-free preparation, isolated Android and iOS signers, `production
signed candidate`, uncredentialed store-client bootstrap, isolated Android and
iOS uploads, and the credential-free signed-release finalizer. It
accepts only the unique non-expired attempt-bound candidate, handoff, and final
signed-release-outcome artifacts, records their distinct server IDs/digests,
and downloads by immutable artifact ID.
Dispatch `protected-mobile-store-rollout` only after its reviewers retrieve the
exact production signed-release artifact and reconcile its canonical candidate
and provenance IDs, run ID/attempt, version/build, signed-release workflow
revision, and portal records. A staged Play update also
requires an exact eligible prior completed production fallback. An iOS `start`
requires the exact prior public version in current `appVersionState`
`READY_FOR_DISTRIBUTION`, the exact target in a reviewed pre-submit state, and
an exact `INACTIVE` phased resource after submission; absence of that prior
record refuses first publication. Retain reviewed store pre/post state and an
unconditional outcome for every selected platform,
including failed or not-run operations, before the job reports a final failure;
partial success must be reconciled before retry.

Do not use staged/phased evidence for a first public store version. Follow the
separate mobile procedures for a 100% first Play publication and an App Store
first-version submission with the selected manual-release setting, exact
`Pending Developer Release`/release-or-withheld pre/post state, UTC action time,
portal audit, and store-owner approval. If only one platform is an update, scope
the protected staged workflow to that platform and retain the other platform's
first-publication record separately.

For updates, start Play at one percent; Apple's phased percentage schedule
advances automatically. Gate every advance on the exact-build crash/performance
window and release approval, then reconcile each content-addressed outcome with
the stores' independent audit records. A pre-completion halt is terminal for
that candidate in Pakperk automation. An Apple pause affects automatic updates
only and does not stop a manual App Store download, so disable harmful server
writes where applicable, disclose that residual exposure, retain the incident/
change record, increment the build, and fix forward. After Play reaches 100%, a
separate protected Android-only full-release halt may restore the exact prior
eligible release for new/eligible users; it does not downgrade installed users,
has no Apple equivalent, and is unavailable for the first Play production
release. See
[the protected staged-rollout procedure](../mobile-release.md#protected-staged-store-rollout).

Store owners must supply a disposable reviewer account with verified email,
accepted current terms, no real-user data, no privileged role, and a rotation/
expiry owner. Review notes describe guest reading, sign-in, report/block,
account deletion, web deletion URL, strict metadata/full-text behavior, and any
staging-only coordinates. Credentials stay in store portals, never Git/issues.
Start from the sanitized
[store reviewer-notes template](../store/reviewer-notes-template.md) and keep
every bracketed evidence field release-blocking until the exact candidate is
verified.

The production signed-release upload writes an owner-only, fsynced attempt
journal before each Play/TestFlight binary send and retains an unconditional
`mobile-store-upload-attempt-<run-id>-<attempt>` artifact. Play readback must
bind the exact server-side bundle SHA-256 to the candidate AAB; Apple readback
must bind the exact app, build and pre-release-version resource IDs, iOS
platform, and completed BuildUpload relationship. Its singular IPA asset must
be a completed `ASSET`/`com.apple.ipa` file whose SHA-256 and byte size equal
the candidate and the pre-send journal; retain the BuildUpload ID and asset
BuildUploadFile ID in the immutable handoff. If a journal exists without that
authoritative readback, treat the upload as `unknown_reconcile_required` and
reconcile the portal before retry.

TestFlight/closed Play upload, protected update rollout or separately approved
first-publication execution and store-side audit reconciliation, physical-device
deep links/callbacks/deletion, current Data Safety/App Privacy/age-rating forms,
review status, measured startup/cache targets, and a representative crash-free
observation window are external gates. Mark each with evidence or leave the
release blocked.

For `protected-mobile-store-rollout`, record the immutable
`store-handoff-v1:sha256:<digest>` emitted by the successful production signed
release. Do not dispatch from a run that omitted store uploads or lacks the
separate verified handoff artifact. A retained attempt journal marked
`unknown_reconcile_required` means the request may have reached the store;
inspect the exact Play/App Store resource and resolve the release ledger before
retrying. In a `both` transition, do not permit the Apple request unless the
Android result and journal gate is already `succeeded_verified`. The workflow
implements this as an uncredentialed bootstrap, isolated Android and iOS jobs
with only their respective secret families, and a credential-free `always()`
finalizer. The iOS job must download and validate the immutable Android outcome
for `both`; each selected platform uploads its own outcome ID and server digest
after unconditional secret cleanup, including on failure. Retain the final
schema-v4 aggregate that binds the signed run, candidate/provenance/handoff,
source, version/build, transition, and exact success/unselected/dependency-skip
semantics. Normalize the upload action's raw 64-hex artifact digest to
`sha256:<hex>` before comparing or recording it.
