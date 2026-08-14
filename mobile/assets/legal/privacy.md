# Privacy

Pakperk supports public reading without an account. When you create an
account, Pakperk stores a minimal public profile, your To Read library,
comment and safety activity, and identity-provider coordinates needed to
operate the account. The identity provider retains a verified email address
for optional registration, login, and recovery; the Pakperk application
profile database does not copy that email.

Comments are public. Drafts and comments held for moderation are private to
you and authorized operators. Pakperk telemetry excludes tokens, email,
identity-provider subjects, handles, search text, paper full text, chat text,
and comment bodies.

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
and account-scoped data, including comment drafts. The deletion worker removes
the provider identity, including its verified email, Pakperk profile, library,
authored comments, blocks, reports, and pending account-owned operations.
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

Publication version: 2026-07-31. Open the published page for the complete,
current policy and the deployment-configured controller/support contact.
