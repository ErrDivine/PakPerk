# Privacy

Pakperk supports public reading without an account. When you create an
account, Pakperk stores a minimal public profile, your Library and To Read
state, optional private research artifacts, comment and safety activity, and
identity-provider coordinates needed to operate the account. Private research
artifacts can include annotations and notes, retained edit conflicts, evidence
cards, reading checkpoints, memory prompts/answers and review state, and
assistant conversations/provenance. The identity provider retains a verified email address
for optional registration, login, and recovery; the Pakperk application
profile database does not copy that email.

Comments are public. Drafts and comments held for moderation are private to
you and authorized operators. Pakperk telemetry excludes tokens, email,
identity-provider subjects, handles, search text, paper full text, assistant
questions/answers, source quotes, annotation/conflict/evidence/memory bodies,
and comment bodies.

Production traffic uses TLS. Private research bodies in the Drift database are
ordinary SQLite text; Pakperk does not currently encrypt that database at the
application layer. Local protection depends on the OS app sandbox, device
access control, platform file protection, and backup disablement/exclusion.
SQLCipher is deferred pending a reviewed key, migration, and recovery design.
Authentication refresh/session material remains separate in platform secure
storage.

Pakperk sends its telemetry provider only a sanitized error category, never a
raw exception or stack. Uncaught fatal errors are not swallowed and may create
an OS-managed Apple or Google crash diagnostic under platform settings and
policy; that path is separate from Pakperk's custom telemetry.

For abuse prevention, the service accepts a forwarded request-origin chain only
from configured ingress proxies, evaluates it right-to-left, and otherwise
falls back to the direct peer. It immediately keys the selected address without
logging or persisting the raw value, then retains only that pseudonym through
the configured rate-limit window, at most 30 days. Production edge
security/access logs may separately retain a source network address for up to
30 days. These identifiers are not used for advertising or tracking and are
separate from identifier-free mobile telemetry.

Account deletion disables access immediately. The app clears local credentials
and account-scoped data, including comment drafts, research caches/conflicts,
version caches, and pending research operations. The deletion worker removes
the provider identity, including its verified email, Pakperk profile, Library,
annotations/conflicts/re-anchor history, evidence cards, checkpoints, memory,
owner-bound assistant history/provenance, Passport feedback, authored comments,
blocks, reports, and pending account-owned operations. Shared paper metadata,
normalized documents, and shared derived artifacts may remain.
Narrow security and moderation records are retained in anonymized form for 90
days. Recoverable database/identity backups and PITR history expire within 35
days. Content-free operational telemetry and application/platform logs expire
after 30 days.

A separately backed-up signed deletion-authority record is kept for at least
400 days, and longer only until evidence proves no recoverable backup can
recreate the account. It contains a keyed fingerprint and encrypted provider
recovery coordinates, not profile or comment content. After restore safety is
verified, an operator-controlled final purge removes the record and encrypted
coordinates.

Assistant threads start with a 30-day expiry, can refresh only within 90 days
of creation, and retain at most 50 messages. Other live private research items
remain until individual deletion where supported or account deletion; an item
tombstone clears its private body. The signed-device cleanup and legal/privacy
review remain release blockers while these features are off.

Bundled candidate revision: 2026-08-31. This is not the Terms/Community
Guidelines consent-version marker. Open the published page for the complete,
current policy, deployment-configured document-set version, and monitored
controller/support contact.
