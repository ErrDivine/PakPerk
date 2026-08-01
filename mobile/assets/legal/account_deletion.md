# Account deletion

You can request deletion in the app from You > Settings > Delete account (also
available directly from You), or through the published web deletion page.

The in-app action requires a fresh system-browser sign-in. Pakperk verifies
that the freshly authenticated identity is the same account already open in
the app. It never replaces your normal session with the one-use credential.

After acceptance, access is disabled and local credentials and account-scoped
data, including comment drafts, are removed from the device. Server cleanup
asynchronously revokes sessions, deletes the identity, library, blocks, and
authored comments, and retains only narrowly necessary anonymized security/
moderation records for 90 days. Recoverable backups expire within 35 days.
Signed deletion authority with encrypted provider recovery coordinates remains
for at least 400 days—and until no recoverable backup can recreate the
account—then an operator-controlled final purge removes it.
