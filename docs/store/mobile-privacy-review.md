# Mobile App Privacy and Data Safety review

**Reviewed code baseline:** Pakperk mobile `0.2.0+2`
**Questionnaire status:** prepared release-candidate answers; not submitted
**Taxonomy checked:** 2026-07-31

This worksheet maps the shipped mobile code and backend-facing features to
store disclosures. The release owner must compare it with the exact signed
artifact, deployed SDKs/processors, and current store questionnaire before
submission. Apple distinguishes collected data, linkage, purpose, and
tracking; Google requires all off-device collection by the app and bundled
SDKs to be declared. See the official
[Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[Apple privacy-manifest guidance](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests),
and [Google Play Data Safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469).

## Actual mobile behavior

- Guest reading does not require an account.
- Account features send an OIDC-backed user identifier; profiles may store a
  public handle/display name.
- Optional account registration and recovery use a verified email address
  retained by the configured identity provider. The Pakperk application
  database does not copy that email into the Pakperk profile.
- To Read stores account-to-paper relationships. Comments and report details
  are user-generated content; blocks and moderation state are account actions.
- The app has no advertising SDK, ad identifier, contact/location/photo/audio
  permission, payment SDK, or cross-app tracking integration.
- Authentication uses the system browser. Tokens are kept in memory or
  platform secure storage and are not copied to analytics, preferences, or
  Drift.
- The custom OTLP exporter sends only closed-vocabulary product interactions,
  bounded counts/durations, deployment environment, and sanitized error
  categories. It sends no stable account/device/session identifier and no raw
  exception, stack, URL, search text, paper identifier, handle, email, comment,
  abstract, introduction, prompt, answer, token, or authorization header.
- Fatal framework/platform/zone failures are not swallowed to manufacture a
  favorable crash-free rate. Delegated application reporting receives only a
  sanitized error category, while an actually uncaught failure retains normal
  Apple/Google OS crash semantics. Platform diagnostics may therefore contain
  a native crash record or runtime stack under platform policy even though the
  custom exporter never receives it; signed-artifact processor and store-form
  review remains required.
- Comment operations and public paper preparation/chat resolve a request-origin
  address from a forwarded chain only when the direct peer belongs to a
  configured ingress-proxy CIDR.
  It evaluates that chain right-to-left; missing, malformed, or untrusted
  chains fall back to the direct peer. The application immediately derives an
  HMAC-SHA-256 scope from the selected address, does not log or persist the raw
  address, and persists only the keyed pseudonym until its configured rate
  window expires (at most 30 days). This is still a disclosable
  network/security identifier; it is separate from identifier-free mobile
  telemetry.
- The application telemetry span excludes peer addresses, raw URIs, headers,
  and bodies. The production API/telemetry ingress can nevertheless process or
  retain source IP access data under its controller-wide logging policy, so
  signed-deployment and processor evidence remains a release blocker.
- Production and staging use TLS. Android backups are disabled. iOS local data
  is excluded from backup and protected on devices.

## Apple App Privacy answers

Use conservative disclosure for the union of enabled production features:

| Apple data type | Linked | Purpose | Reason |
| --- | --- | --- | --- |
| Name | Yes | App Functionality | optional public handle/display name and profile |
| Email Address | Yes | App Functionality | optional account registration, verification, login, and recovery at the identity provider; not copied into the Pakperk application profile database |
| User ID | Yes | App Functionality | OIDC/local account identity |
| Other Data Types | Yes | App Functionality | keyed trusted request-origin scope retained for shared comment and expensive public-action abuse limits, plus reviewed production-edge network/security processing |
| Other User Content | Yes | App Functionality | comments and report/support free text |
| Product Interaction | Yes | App Functionality; Analytics | account-linked To Read/actions plus identifier-free interaction telemetry; linkage is marked Yes because the category also has a linked use |
| Crash Data | No | Analytics | custom exporter receives only sanitized `timeout`, `format`, `state`, `argument`, or `unexpected`; uncaught faults retain separate OS-managed crash diagnostics under platform policy |
| Performance Data | No | Analytics | bounded startup duration and cache/interaction performance signals |

Apple defines Device ID as an advertising identifier or another device-level
identifier. The retained HMAC scope is instead a short-lived network-origin
pseudonym shared by every device behind that origin, so **Other Data Types** is
the accurate conservative category; Device ID would misleadingly imply a
device-level identifier. Apple's IP guidance requires classification according
to use, and its App Functionality purpose expressly includes fraud prevention
and security. Raw request addresses discarded while servicing the request are
not themselves collected under Apple's retention definition, while the retained
keyed scope and any production-edge security/access retention are covered here.
See [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
and the official
[privacy-manifest data-type values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).

The app-level `PrivacyInfo.xcprivacy` intentionally describes collection by the
app/backend represented in the App Store privacy label, not merely direct SDK
collection. Each bundled third-party SDK remains responsible for its own
manifest; the signed-archive privacy report must be checked for the merged
union before submission.

Select **Data Not Used to Track You** for every type and answer that the app
does not track. Do not select advertising, marketing, or personalization.
`mobile/ios/Runner/PrivacyInfo.xcprivacy` must match this table and the merged
privacy report generated from the signed archive. If a dependency adds a
manifest or collection behavior, reassess the union before submission.

## Google Play Data Safety answers

The proposed production mapping is:

| Google data type | Collection/purpose | Required/optional |
| --- | --- | --- |
| Personal info — Name | collected for app functionality/account management | optional; guest reading works without it |
| Personal info — Email address | collected by the identity provider for account management, verification, login, and recovery | optional; guest reading works without an account, and the Pakperk application profile database does not copy it |
| Personal info — User IDs | collected for app functionality/account management and security | optional; required only when account features are chosen |
| Device or other IDs | keyed request-origin network identifier collected for abuse prevention, security, and shared rate limiting; production edges may also process source IP access data | automatic when requests reach those protected service/edge boundaries; never used for advertising or tracking |
| App activity — Other user-generated content | collected for app functionality/safety (comments and report text) | optional |
| App activity — App interactions / Other actions | collected for account functionality (To Read, block/report actions) and analytics (closed-vocabulary events) | functionality is optional; production analytics is automatic when enabled |
| App info and performance — Crash logs | custom exporter collects a sanitized error category; uncaught faults may separately produce OS-managed crash diagnostics | automatic when production telemetry is enabled or the platform diagnostics policy applies; verify the signed deployment and console settings |
| App info and performance — Diagnostics | bounded startup/cache timing and outcome data collected for analytics | automatic when production telemetry is enabled |

Answer **Yes** to encryption in transit and to providing an account-deletion
mechanism. The app does not sell data or use it for advertising. Answer “not
shared” only after contracts and deployed routing establish that identity,
hosting, database, backup, and telemetry vendors act solely as service
providers under the applicable Google exception; otherwise declare the
transfer. Do not claim an independent security review unless its final report
is attached.

## Retention/deletion statement to reconcile

The public and bundled policies must retain the same schedule:

- active profile/library/comments/blocks/reports/provider identity: for the
  active account, then removed by account deletion; provider identity includes
  the verified email retained for registration and recovery;
- keyed request-origin abuse-limit scopes: until the configured rate window
  expires (maximum 30 days), then removed by bounded maintenance; recoverable
  copies remain subject to the backup horizon below;
- recoverable database/identity backup and PITR history: at most 35 days;
- anonymized security/moderation audit: 90 days;
- content-free telemetry and platform/application logs: 30 days;
- signed deletion authority: at least 400 days and, if longer, until no
  recoverable backup can resurrect the account, followed by controlled purge.

The signed deletion authority contains a keyed fingerprint and encrypted
provider recovery coordinates, not profile or comment content. Restore is
fail-closed until deletion authority is reapplied.

## Submission evidence (must be completed externally)

- Release owner / review date: **pending**
- Signed iOS build and Xcode privacy report: **pending**
- Signed Android build and SDK/permission inventory: **pending**
- Published privacy/support/deletion URLs and monitored contact: **pending**
- Processor/service-provider contract review: **pending**
- Deployed identity-provider email handling and ingress/source-IP log inventory,
  retention, access, and processor-role verification: **pending**
- App Store Connect answers/version and approver: **pending**
- Play Console Data Safety answers/version and approver: **pending**
- UGC/age-rating worksheet and reviewer instructions: **pending**

Pending means release-blocking; it must not be converted to “passed” from this
worksheet alone.
