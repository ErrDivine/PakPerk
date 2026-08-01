# Mobile app links

Phase 1 registers and validates these entrypoints:

```text
pakperk://paper/{paper_id}
pakperk://paper/{paper_id}/comments
https://pakperk.app/p/{paper_id}
https://pakperk.app/p/{paper_id}/comments
https://pakperk.app/arxiv/{arxiv_id}
```

Paper IDs must be UUIDs. arXiv IDs may use the modern form or a legacy archive
form whose slash is percent-encoded in the URL. The router accepts only the
exact HTTPS origin, rejects credentials, ports, query strings, fragments,
unexpected segments, traversal, and overlong or malformed identifiers, and
fails closed to Read without issuing a paper request.

Android intent filters and the iOS URL scheme/associated-domain entitlement are
checked into the native hosts. Those declarations alone do not establish
verified production universal links. Before a signed release, operations must:

1. Serve `https://pakperk.app/.well-known/assetlinks.json` with the final
   Android application ID and every active **Play App Signing** certificate
   SHA-256 fingerprint. The upload-key certificate on the locally signed AAB
   is different and must not be used for installed-app association.
2. Serve `https://pakperk.app/.well-known/apple-app-site-association` with the
   final Apple team ID, bundle ID, and the narrowly supported `/p/*` and
   `/arxiv/*` paths.
3. Put the final package/bundle IDs, Apple team ID, and Play app-signing
   certificate fingerprint in the protected Helm values used by the release.
   The chart renders both documents and production rendering fails if the
   application IDs do not match `app.pakperk.pakperk`.
4. Extract the package/version and upload-key certificate from the AAB/APK,
   and the team/bundle identity from the IPA. Require both Android candidates
   to share the upload certificate, but compare `assetlinks.json` to the
   independently protected Play app-signing fingerprint:

   ```bash
   PAKPERK_RELEASE_ENV=production \
   PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
   PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
   PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
   PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
   ./scripts/verify_mobile_associations.sh assetlinks.json apple-app-site-association
   ```

   Fetch the deployed URLs without redirect following and require HTTP 200
   with `Content-Type: application/json` before submitting either store build.
5. Serve both files directly over HTTPS with the correct JSON content type and
   no redirect.
6. Validate the files against signed release candidates, then exercise cold,
   warm, and already-running app links on physical Android and iOS devices.
7. Confirm malformed and hostile-origin URLs stay in the browser or fail closed
   to Read, and that a valid public link opens Abstract.

The checked-in host configuration uses `pakperk.app` as the production link
origin. Changing that origin requires an atomic update to the router allow-list,
both native hosts, both external association files, tests, and published links.
