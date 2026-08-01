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
- Feature state: `accounts=[on/off], library=[on/off], comments=[on/off]`

Reviewer credentials are stored only in the portal's protected review fields.
The disposable account must have a verified email, a current Terms acceptance,
no real-user data, and no staff/moderator privileges. Record its expiry and
rotation owner in the protected release evidence.

## Exact review walkthrough

1. Launch the app without signing in. The **Read** tab opens a metadata-first
   paper feed. Swipe vertically to change papers and horizontally to move among
   Abstract, Introduction, and Connections when those capabilities are ready.
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
5. Open a paper's **Comments** action. Post the exact harmless text
   `Store review test comment`; then edit it to `Store review test comment
   edited` and delete it. Draft text remains local until Send is selected.
6. On the seeded review-only comment from `[review fixture handle]`, open the
   context menu and select **Report**. Choose a listed reason and submit. Repeat
   with **Block user**. The author's comments disappear immediately, and the
   user is visible under **You > Blocked users**, where they can be unblocked.
   Do not report or block real users.
7. Open **You > Settings > Clear reading cache**. The confirmation explains
   that rebuildable public data is removed while saves, drafts, pending sync,
   account data, and reading position remain.
8. Open **You > Delete account**. Complete the exact confirmation phrase and
   recent-authentication browser step, then submit. The app enters a deletion
   status state, removes account-owned local data, revokes the local session,
   and keeps public reading available. Use `[fresh disposable account / reset
   procedure]` if the store review needs another pass.
9. The same deletion request is available without the app at the web account
   deletion URL above. Support escalation is available at the published
   Support URL.

## Content and safety behavior

- Comments are public plain text. Posting requires sign-in, a handle, current
  Terms acceptance, and Community Guidelines acceptance.
- Every eligible third-party comment exposes Report and Block. Moderation can
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
- Physical-device acceptance evidence: `[controlled evidence reference]`
- Deletion completion/reference: `[controlled evidence reference; no token,
  email, comment body, or provider subject]`

Leaving a field blank or writing “pending” is release-blocking. This template
does not prove that a candidate, account, endpoint, or store submission exists.
