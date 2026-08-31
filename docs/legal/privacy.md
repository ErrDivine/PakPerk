# Pakperk Privacy Notice

**Draft revision:** `2026-08-31`
**Publication status:** release-candidate text. The public site still displays
the deployment-bound document-set version shared with Terms and Community
Guidelines; this draft does not silently change that consent/version binding.
A production release must
configure the monitored controller/support contact shown on the public policy
site and complete the jurisdiction-specific review recorded in the release
evidence.

Pakperk is the service controller unless the published support page identifies
a different operating entity. The production-configured monitored address on
that page is the contact for privacy, access, correction, deletion, objection,
and legal requests. A placeholder or unreachable contact blocks release.

Pakperk works for guest readers without an account. The service stores only the
data needed for features a reader chooses:

- accounts: the identity provider retains verified email for optional
  registration, login, and recovery; Pakperk stores OIDC issuer/subject, local
  user ID, public handle/display name, status, policy acceptances, and
  operational timestamps in its application database;
- Library and To Read: account-to-paper relationships, Inbox/Read next/Reading/
  Reviewed/Archived state, private save notes, lists, tags, an optional
  user-selected UTC reminder timestamp, revisions, tombstones, and idempotency
  records;
- discovery profile: an optional future-discovery mode, explicit category,
  topic, and author follows, separately labelled feedback-derived or inferred
  interests, profile revisions, and the personalization setting;
- discovery activity: short-lived recommendation batches and reason features,
  explicit relevant/not-relevant/dismissed feedback, and bounded content-free
  interaction events such as a qualified impression or explicit paper open;
- search and alerts: an unsaved Lookup, suggestion, or Explore query is not
  stored as query history; a query is retained only when the account explicitly
  saves it.
  Saved query definitions, subscriptions, bounded reading briefs, in-app
  notifications, and notification preferences are account-owned;
- Deep Reader and research memory: normalized paper content and shared
  source-linked Passport/facet/visual/version artifacts are paper data;
  annotations and note bodies, retained edit conflicts, re-anchor history,
  evidence cards, position/mode checkpoints, memory prompts/answers and review
  settings, assistant conversations, and their owner-bound provenance are
  private account data;
- comments: public normalized text, author, paper, status, versions, and
  timestamps;
- safety: reports, blocks, rate-limit records, moderation decisions, and a
  redacted audit trail; and
- operation: request IDs and content-free reliability/security telemetry.

The Pakperk application profile database does not copy the identity-provider
email. Pakperk does not collect address-book contacts, precise location, an
advertising ID, or an avatar. Personalization is off until the account opts in;
it can be disabled or reset without disabling Search, Library, or queue
reading. Explicit follows never silently become inferred follows. Private note
bodies, comment sentiment, exact dwell time, and identity-provider attributes
are not ranking inputs. Access and refresh tokens are excluded from general
preferences, SQLite, and Pakperk-managed telemetry. Comment bodies, report
details, paper full text, model prompts, assistant questions/answers, source
quotes, annotation/conflict/evidence/memory bodies, raw search/import text,
recommendation explanations, handles, email, and identity-provider subjects
are excluded from operational telemetry. Deep Reader metrics use only closed
outcomes, coarse duration buckets, bounded aggregate counts, and feature/source
classes; they contain no account, paper, block, artifact, or operation ID.

Pakperk uses TLS for production network traffic. Server-side data-at-rest
protection depends on the reviewed production database, backup, and object-store
controls and remains a release evidence requirement. On the device, Pakperk's
Drift database is not application-layer encrypted: private research bodies are
stored as ordinary SQLite text. The local protection boundary is the operating
system app sandbox, device access controls, platform file protection, and
backup exclusion/disablement where configured. SQLCipher is deferred pending a
reviewed threat model and a tested key, migration, restore, and account-cleanup
design. Authentication refresh/session material remains separate in platform
secure storage.

Pakperk sends its telemetry provider only a sanitized error category, never a
raw exception or stack. An uncaught fatal error is not swallowed: before the
failure reaches delegated or OS-managed diagnostics, Pakperk replaces the
application exception and Dart stack with a bounded category and empty stack.
Apple or Google may still create a native process crash record under platform
settings and policy. This platform path is separate from Pakperk's custom
telemetry and is reviewed with the signed release and configured processors.

For shared abuse limits on comments and expensive public paper actions such as
preparation and chat, the application resolves a request-origin address from a
forwarded chain only when the direct peer belongs to a configured ingress-proxy
CIDR. It evaluates that chain right-to-left; missing, malformed, or untrusted
chains fall back to the direct peer. The application immediately derives an
HMAC-SHA-256 scope from the selected address, does not log or persist the raw
address, and persists only the keyed pseudonym through the configured
rate-limit window, which cannot exceed 30 days. Production edge security/access
logs may separately retain a source network address for up to 30 days. These
network/security identifiers are not used for advertising or tracking and are
separate from identifier-free mobile telemetry.

Comments are public. A block is private to the blocking account. Reports and
moderation records are restricted to authorized operators. Contracted
providers process data only for configured identity, database, delivery,
security, backup, or telemetry functions.

## Retention schedule

The production release is configured to the following maximum/default
schedule. Increasing a period requires a reviewed policy update before the
configuration change is deployed.

- Live profile, library, comments, blocks, reports, and provider identity,
  including its verified email, are kept while the account is active, then
  removed by the deletion workflow.
- A Library reminder remains with its active item until the reader clears or
  replaces it, moves the item out of To Read, removes the item, or deletes the
  account. Only reminders due within the prior 24 hours can create an in-app
  notification, so a disabled notification rollout cannot later surface a
  months-old promise. The timestamp is account-private and is excluded from
  logs and telemetry; the notification payload contains only its epoch value.
  Notification dismissal does not alter the Library item.
- Explicit research-profile interests, saved queries, subscriptions, and
  preferences remain until the account deletes or resets them, or the account
  is deleted. A saved query can be deleted individually in Search; the server
  removes its normalized definition and save-retry bindings, retires and
  scrubs any linked saved-query alert subscription, and invalidates pending
  notifications. This does not clear the separate, opt-in search history kept
  only on that device or alter the Library/reading queue. Disabling
  personalization removes feedback-derived and inferred profile interests
  while preserving explicit follows. A positive relevance
  action may create a separately labelled feedback-category affinity only
  while personalization is enabled.
- Recommendation batches, candidates, and immutable reason evidence use a
  server-assigned expiry (currently 24 hours). Content-free recommendation
  interactions are accepted for an account only while its stored
  personalization preference is enabled and expire after **90 days**. The
  v0.1 app sends no guest events, and the server rejects every anonymous event
  batch, because no verifiable guest analytics-consent authority or guest
  Library exists. Raw explicit recommendation feedback
  expires after **180 days**; its monotonic revision fence is retained so an
  older batch cannot become current again. Any separately labelled derived
  affinity remains profile data until reset, personalization is disabled, or
  account deletion. Terminal recommendation-generation jobs, dormant queued
  jobs, and expired-lease running jobs older than **30 days** are removed by
  bounded maintenance.
- Unsaved Lookup/suggestion/Explore text and submitted import text are not
  retained as server query history. Resolution caching uses a keyed query
  fingerprint and bounded metadata result; canonical arXiv identity is retained
  when a paper is explicitly imported. An explicitly saved normalized query
  remains until the user deletes that saved query or deletes the account.
  Saved-query deletion is repeat-safe and account-scoped; an absent or
  foreign-owned identifier receives the same empty success response and does
  not reveal ownership. Content-free research-profile retry bindings
  expire after **30 days**, and saved-search retry bindings expire after their bounded
  server-assigned window.
- Reading briefs expire after **35 days**. In-app notifications expire after
  **30 days**. Reading-brief progress, subscription, and notification-preference
  retry/idempotency rows expire after **30 days**, as do completed or failed
  notification-work rows. Hourly maintenance deletes at most 1,000 rows per
  table in each pass. Push and email delivery are unavailable in this release
  even if a client submits those preference fields.
- Owner-bound and anonymous assistant threads start with a **30-day** expiry.
  Use can refresh the deadline by no more than 30 days at a time and never past
  **90 days from thread creation**; each thread keeps at most 50 messages.
  Hourly maintenance removes at most 1,000 expired threads and their private
  answer provenance per pass.
- Live annotations, retained edit conflicts and re-anchor history, evidence
  cards, reading checkpoints, and research-memory items remain until the user
  deletes the item where supported or deletes the account. An annotation,
  evidence-card, or memory-item deletion leaves a synchronization tombstone
  with its private body cleared. No shorter routine server purge for those
  tombstones/conflict records is claimed in this release. Account-scoped mobile
  research rows, conflicts, cached versions, and pending research outbox work
  are removed on sign-out/account switch and account deletion; signed-device
  verification remains a release blocker.
- Keyed request-origin abuse-limit scopes are kept until the configured rate
  window expires (at most **30 days**) and are then removed by bounded
  maintenance. Recoverable copies remain subject to the backup horizon below.
- Recoverable PostgreSQL/identity backups and PITR history expire within
  **35 days**. A restore is never returned to service until current deletion
  authority has been reapplied and verified.
- Anonymized security and moderation audit records expire after **90 days**.
- Content-free operational telemetry and application/platform logs expire
  after **30 days** at the upstream telemetry and logging systems.
- A separately backed-up, signed deletion-authority record is kept for at
  least **400 days** and, if longer, until evidence proves no recoverable
  backup can resurrect the deleted account. It contains a keyed identity
  fingerprint and encrypted provider issuer/subject recovery coordinates, not
  profile or comment content. Those coordinates are decryptable only by the
  restricted account-deletion API and worker components while the record
  remains authorized.

After the backup-safety condition is met, an operator-controlled final purge
removes the deletion-authority record and its encrypted provider coordinates.
Historical verification/decryption keys are retained only while a retained
record or recoverable backup needs them. A specific preservation obligation
may pause deletion only through a documented, access-controlled case with a
recorded basis, scope, owner, and expiry; it is not an open-ended default.

## Account deletion and requests

Deleting an account disables access immediately. The worker revokes provider
sessions, deletes the provider identity, and removes the profile, Library/To
Read rows, lists, tags, saved queries, subscriptions, briefs, notifications,
recommendation batches/feedback/events, annotations and retained conflicts,
re-anchor attempts, evidence cards, reading sessions/checkpoints, memory items,
owner-bound assistant conversations/provenance, Passport feedback, comments,
blocks, reports, and pending account-owned operations. Public paper/topic
metadata, normalized source documents, and shared derived artifacts that are
not account-owned remain. The signed deletion authority makes retries
idempotent and prevents a restored backup from silently recreating the account.

`GET /v1/annotations/export` provides an account-authenticated research export
as JSON or Markdown, plus a per-paper manifest. `paged=true` returns a sequence
of fixed-memory parts for either a paper or the complete account; opaque next
cursors are account/scope bound, and each part contains one complete artifact
with its necessary citation or parent context. It includes private research artifacts,
owner-bound assistant history/provenance, Library metadata/private save notes,
and citation/original-source metadata. It excludes principal identifiers and
does not export reconstructed full papers. This repository contract does not
constitute the required legal, live deletion, restore, or signed-device
approval; those Plan 03 gates remain `not_ready` while the features are off.

Use the public account-deletion route or the in-app action for removal. Use the
[support route](support.md) for access, correction, privacy, copyright, or
legal questions. Include an operation ID when available; never send a
password, authorization code, or token.
