# Pakperk user guide

Pakperk is a mobile arXiv reader. You can browse and read as a guest; an account
is needed only for features that belong to you, such as your synchronized
Library and its To Read queue, posting public comments, blocking, and account
deletion.

The release targets Android 7.0 / API 24 or newer and iOS 15 or newer.

## Availability note

Pakperk Production v0.0 is currently a release candidate. The checked-in
production configuration keeps accounts, Library, and comments off until the
service completes its operational, safety, legal, device, signing, and store
reviews. A released build may therefore show only guest reading. The app should
never advertise a disabled capability as available.

Install or update Pakperk only through an official App Store or Google Play
listing published by the service operator. If the operator has not linked an
official listing, Production v0.0 is not yet publicly available; do not trust
an arbitrary download or sideload as a released build.

## Read papers

The app has three main destinations:

- **Read** contains the paper feed and reader.
- **Library** contains your synchronized papers and To Read queue when those
  features are enabled. Otherwise it explains that Library is unavailable or
  asks you to sign in.
- **You** contains guest information or, when accounts are enabled, sign-in,
  profile, a Library shortcut, **My comments**, Blocked users, Settings,
  Sign out, and Delete account controls.

Library's canonical in-app location is `/library`. After an upgrade, an older
restored route that still points to `/you/library` redirects to the standalone
Library destination automatically.

In Read:

1. Move vertically for the next or previous paper.
2. Move horizontally—or use the labeled stage controls—between **Abstract**,
   **Introduction**, and **Connections**. Chat opens separately from the
   Introduction stage.
3. Use the arXiv action to open the original record. Pakperk does not replace
   the source paper and is not affiliated with arXiv.

The first committed move into Introduction may start normal paper preparation
when that paper has not been processed. Prefetching or merely viewing a feed
card does not start preparation. Preparation can take time and may expose a
retry if a dependency is temporarily unavailable.

Chat is scoped to the selected paper and should cite the evidence supplied with
its answer. It may decline to answer when the paper does not support the
question. Connections explains selected references; use the source links to
inspect the original work.

In a strict release, Introduction, Chat, or Connections can also be unavailable
while online when the paper's license or prepared capabilities do not permit
that derived content. Metadata and the original arXiv link remain available.

## Offline and cached reading

Pakperk opens cached or bundled metadata before waiting for the network, then
refreshes in place when connectivity returns. The app remembers the current
paper, reader stage, scroll position, and other bounded navigation state.

In a strict release, offline metadata and original arXiv links remain
available, but cached Introduction, Connections, chat answers, and derived
capabilities may be hidden when the app cannot revalidate their content policy.
That is an intentional rights-protection boundary.

## Settings and data on this device

Open **You → Settings** to choose system/light/dark appearance, inspect reading
cache usage, view licenses, or clear local data.

- **Clear reading cache** removes rebuildable feeds, generated reading views,
  cached discussions, and anonymous chat cache. It preserves your account,
  saved papers, drafts, pending synchronization, settings, and current reading
  position.
- **Clear all data** signs out and removes every local paper, local save, draft,
  pending change, setting, reading position, and anonymous device identity from
  that device. Data already synchronized to your Pakperk account remains on
  the server.
- **Delete account** is a separate server-side action. Use it when you want to
  remove the account and associated server data; clearing local data alone does
  not do that.

## Accounts and sign-in

When accounts are enabled, sign-in opens the system browser and uses the
service's identity provider. Pakperk does not ask you to type a provider
password into the app. Complete email verification or recovery with that
provider.

Your Pakperk profile contains a public handle and optional display name. A
handle is normalized to lowercase, must contain 3–30 lowercase ASCII letters,
digits, or underscores, and can be set only once. Some actions require
acceptance of the current Terms and Community Guidelines. If
the provider or network is temporarily unavailable, the app may retain a
limited offline account state while disabling remote mutations until your
identity can be verified again.

Signing out removes account-owned local data and secure session material from
the device. Public cached papers and reader restoration can remain so guest
reading still works.

## Library and To Read

When Library is enabled, use the paper save control to add or remove a paper
from **To Read**. Saved papers appear in the standalone **Library** destination;
baseline To Read entries appear in **Inbox**. Changes appear optimistically on
the device and sync when the network and verified account are available.

In the baseline To Read flow, removing a paper offers **Undo** as a new
synchronized action. You can refresh Library by pulling down; offline and
pending states remain visible instead of pretending a remote change has
completed.

If the expanded Library capability is enabled for your build, Library can also
offer **Read next**, **Reading**, **Reviewed**, and **Archived** states, private
save notes, **Lists & tags**, reminders, and private on-device **History**.
Those controls appear only when their matching capabilities are enabled. Opening
a paper never changes its Library state automatically.

If library writes are temporarily paused, existing saved papers remain
readable but save/remove actions wait or fail with an explanation. Saving a
paper never starts its preparation.

## Public comments and safety

When comments are enabled, guests can read published discussion. Posting
requires an active verified account, a public handle, and acceptance of the
current Terms and Community Guidelines.

- Comments are public plain text, not private notes or rendered Markdown.
- A normalized comment may contain at most 2,000 Unicode characters, 8,000
  UTF-8 bytes, and three links.
- The app rejects unsafe control characters and pathological pastes before
  saving or sending them.
- Drafts belong to one account and paper, remain local until sent, and never
  auto-send.
- A new or edited comment may be held for review.
- You can edit or delete your own comment while your account is eligible.

Open **You → My comments** to revisit your posts. A comment labeled **Under
review** is visible only to you and authorized moderators until it is published
or resolved.

Use the three distinct safety actions deliberately:

- **Report comment** sends a private content report. It does not hide or block
  the author automatically.
- **Report user** sends a private account-level report. It does not create a
  block.
- **Block user** immediately removes that author's comments from your view and
  synchronizes the block to your account. It does not create a report.

You can manage blocked users from You. Serious or urgent safety, privacy,
copyright, accessibility, or legal concerns belong on the published support
page. Do not paste passwords, tokens, private keys, or an entire harmful
comment into a support request; include the relevant operation or comment ID
when available.

The complete rules are in the
[Community Guidelines](legal/community-guidelines.md).

## Delete your account

When deletion is enabled, open You and choose the account-deletion action. The
service requires a recent sign-in so a stolen old session cannot delete the
account. A public web deletion route is also provided for the released service.

Deletion disables access immediately and queues removal of the provider
identity, profile, Library data including To Read, comments, blocks, reports,
and pending account-owned work. The operation is retry-safe. A restricted
signed deletion record is retained long enough to prevent a restored backup
from silently recreating the account; it is not a copy of your profile or
comments.

Use the built-in support action if deletion is stalled; it includes a validated
request identifier when one is available. If the app or web page explicitly
shows an operation ID, retain it and send no credentials. See the
[Privacy Notice](legal/privacy.md) for retention details.

## Privacy in plain language

- Guest reading does not require an account.
- Access tokens stay in memory; refresh/session material uses the platform
  secure store rather than general preferences or the content database.
- Pakperk operational telemetry excludes comment/report text, paper full text,
  prompts, chat messages, handles, email, provider subjects, and tokens.
- Pakperk does not collect contacts, precise location, an advertising ID, an
  avatar, or a personalized ranking profile for v0.0.
- Apple or Google may separately collect native crash information according to
  device settings and their policies.

The authoritative release-candidate policy text is the
[Privacy Notice](legal/privacy.md); its jurisdiction/contact approval remains a
release gate until publication.

## Accessibility and navigation

Pakperk supports labeled alternatives to swipe gestures, light and dark
themes, reduced motion, large text, screen-reader semantics, keyboard focus,
and system back navigation. Phones use bottom navigation; larger layouts use a
labeled navigation rail. If motion is reduced at the OS level, opening and
reader transitions should remain bounded and understandable without relying
on animation.

## Troubleshooting

- **The app opens older papers:** you are seeing the cached-first experience;
  reconnect and retry the feed refresh.
- **Introduction or Connections is unavailable:** strict content policy may be
  masking derived material because it cannot be revalidated or the paper's
  rights/capabilities do not permit it. This can happen online or offline. The
  original arXiv link remains available.
- **You shows guest information:** the installed build may have accounts
  disabled, or you may need to sign in again after an invalid session.
- **Library is unavailable or comments are missing:** those capabilities may be
  disabled for the release or environment; guest reading should still work.
- **Comment sending is paused:** correct any visible length/character error,
  reconnect, verify the account, or wait for the publication switch to reopen.
  Existing discussion and safety actions should remain available when only new
  publication is paused.
- **A Library or comment change has not appeared on another device:** keep the
  app online long enough to verify the account and complete synchronization,
  then refresh the destination view.
- **Account deletion asks for sign-in:** complete the recent-authentication
  step in the system browser and retry.

For a released service, use `https://pakperk.app/support`. The corresponding
repository policy is [Support and Safety](legal/support.md). A placeholder or
unmonitored support route blocks release.
