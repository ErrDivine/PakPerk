# Store reviewer notes template

Copy this template into App Store Connect and Play Console for the exact signed
candidate. Complete every bracketed field in the store portal. Never commit,
email, or paste reviewer credentials into repository evidence, issues, logs, or
chat.

## Candidate and environment

- App/build version: `[version + build number]`
- Store/platform: `[App Store Connect / Play Console]`
- Environment: `[production / approved isolated review environment]`
- API origin: `[public HTTPS origin]`
- Public site: `[published HTTPS URL]`
- Privacy policy: `[published HTTPS URL]`
- Terms: `[published HTTPS URL]`
- Community Guidelines: `[published HTTPS URL]`
- Support: `[published HTTPS URL and monitored contact]`
- Web account deletion: `[published HTTPS URL]`
- Feature state: `accounts=[on/off], library=[on/off], comments=[on/off], Plan
  03 Deep Reader/Passport/facets/visuals/checkpoints/annotations/evidence/memory/
  version diff/Assistant v2=[all off]`
- Candidate feature binding: `[schema-v6 SHA-256 plus exact states for all 24
  To Read First, Plan 02, and Plan 03 mobile flags from the schema-v4
  candidate/provenance manifests]`

The repository contract now binds all ten Plan 03 mobile controls and defines
their protected schema-v6 signed-device/private-research scenarios. Keep every
Plan 03 feature off in a store candidate until a complete exact-candidate run
passes and the remaining product, privacy/legal, human, live-model, staging, and
release-owner gates close. Do not describe the checked validator or an
undispatched workflow as Plan 03 evidence; execution remains `not_ready`.

Reviewer credentials are stored only in the portal's protected review fields.
For the first exact walkthrough, the disposable account must have a verified
email but no public handle or current Terms/Community Guidelines acceptance, so
the candidate's posting onboarding is exercised. It has no real-user data and no
staff/moderator privileges. Record its reset procedure, expiry, and rotation
owner in protected release evidence; do not weaken the flow by reusing an
already-onboarded account without recording that limitation.

### Disposable account lifecycle

Before review, create a new account with a verified email, no handle, no policy
acceptance, no real-user data, and no staff or moderator role. In protected
release records, capture only its keyed account-reference hash, creation and
expiry timestamps, reset procedure hash, and responsible owner; credentials and
provider subject identifiers stay in the store portal or secret manager.

After the walkthrough or expiry, submit and observe the documented deletion
flow, confirm the application account and provider identity are absent, revoke
or rotate every associated credential, and remove review fixtures that are not
part of the reusable sanitized environment. Retain the deletion evidence
reference, lifecycle/result hashes, UTC completion time, and owner approval. A
failed cleanup, an expired account left usable, or an account that bypasses the
onboarding steps blocks `reviewerFlowId` and store submission.

## Exact review walkthrough

1. Launch the app without signing in. The **Read** tab opens a metadata-first
   paper feed. Swipe vertically to change papers and horizontally to move among
   Abstract, Introduction, and Connections when those capabilities are ready.
   Use the arXiv action and verify the exact canonical record opens in the OS
   browser, not an embedded web view.
2. Open **You**. Privacy, Terms, Community Guidelines, Support, Settings,
   version, licenses, appearance, and cache controls are available without an
   account.
3. On a paper, select **Save to To Read**. The app explains why authentication
   is needed and opens the operating system browser. Sign in using the
   protected reviewer credentials. Canceling the browser leaves the paper and
   public reading usable.
4. After sign-in, the pending Save completes. Open **You > To Read**, choose the
   saved paper, and verify it opens in **Read** on Abstract. Back returns to the
   To Read list. Removing and undoing a save update every visible Save control.
   Sign out; account-owned local state detaches while public reading remains, so
   the next comment step begins from a genuine guest intent.
5. Open a paper's **Comments** action. The retained guest intent must resume
   after sign-in, ask this incomplete account to choose its one-time handle, and
   require acceptance of the current Terms and Community Guidelines. Post the
   exact harmless text `Store review test comment`; then edit it to `Store review
   test comment edited` and delete it. Draft text remains local until Send is
   selected, and the deleted comment must disappear from the public list.
6. On the seeded review-only comment from `[review fixture handle]`, open the
   context menu and select **Report comment**. Choose a listed reason and
   submit. Reopen the menu and select **Report user**; verify the confirmation
   says no block was added and the comment remains visible. Then select
   **Block user**. The author's comments disappear immediately, and the
   user is visible under **You > Blocked users**, where they can be unblocked.
   Do not report or block real users.
7. Open **You > Settings > Clear reading cache**. The confirmation explains
   that rebuildable public data is removed while saves, drafts, pending sync,
   account data, and reading position remain.
8. Open **You > Settings > Delete account**. Select the permanent-deletion
   confirmation checkbox and complete the recent-authentication browser step,
   then submit. The app enters a deletion
   status state, removes account-owned local data, revokes the local session,
   and keeps public reading available. Use `[fresh disposable account / reset
   procedure]` if the store review needs another pass.
9. The same deletion request is available without the app at the web account
   deletion URL above. Support escalation is available at the published
   Support URL.

## Content and safety behavior

- Comments are public plain text. Posting requires sign-in, a handle, current
  Terms acceptance, and Community Guidelines acceptance.
- Every eligible third-party comment exposes separate Report comment, Report
  user, and Block user actions. Moderation can
  hide/restore content and suspend/reinstate accounts with an audit trail.
- Comment creation can be disabled independently; existing comments and paper
  reading remain available when the kill switch is off.
- The production full-text policy is **strict**. The app always exposes paper
  metadata and arXiv links, but generated Introduction, Connections, and chat
  are shown only when the server policy permits them. Capability absence is not
  a loading failure.
- The app has no direct messages, followers, public counts, karma, presence,
  advertising, payments, or background location in v0.0.

## Review-only coordinates and evidence

- Seed paper title/arXiv ID: `[non-sensitive public fixture]`
- Seed report/block fixture handle: `[review-only account]`
- Any review-environment limitation: `[none, or exact limitation approved by
  release owner]`
- Reviewer / UTC date: `[name or controlled identifier + timestamp]`
- Signed artifact digest and SBOM digest: `[release evidence references]`
- Physical-device acceptance evidence: `[schema-v6 controlled evidence
  reference covering all 42 ordered scenarios / 317 assertions / 254 metrics,
  the exact source-bound app-link origin, two-device removal, invalid refresh,
  links, protection, cache bounds, light/dark, To Read First authority/rollout,
  Add Paper resolution/retry, Plan 02 Search/Profile/Why/Brief/Alerts, and all ten
  Plan 03 reader/research scenarios; not a statement or repository-only result]`
- Plan 03 signed-device evidence: `[not_ready; do not submit a candidate with a
  Plan 03 mobile control enabled until the exact v6 device run and every
  implementation/privacy/external gate are passed]`
- Deletion completion/reference: `[controlled evidence reference; no token,
  email, comment body, or provider subject]`
- Reviewer-account lifecycle/reference: `[controlled creation, expiry,
  deletion, credential-rotation, and owner-approval reference; no credential,
  email, or provider subject]`

Leaving a field blank or writing “pending” is release-blocking. This template
does not prove that a candidate, account, endpoint, or store submission exists.
