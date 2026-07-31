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
   Android application ID and every production signing-certificate SHA-256
   fingerprint.
2. Serve `https://pakperk.app/.well-known/apple-app-site-association` with the
   final Apple team ID, bundle ID, and the narrowly supported `/p/*` and
   `/arxiv/*` paths.
3. Serve both files directly over HTTPS with the correct JSON content type and
   no redirect.
4. Validate the files against signed release candidates, then exercise cold,
   warm, and already-running app links on physical Android and iOS devices.
5. Confirm malformed and hostile-origin URLs stay in the browser or fail closed
   to Read, and that a valid public link opens Abstract.

The checked-in host configuration uses `pakperk.app` as the production link
origin. Changing that origin requires an atomic update to the router allow-list,
both native hosts, both external association files, tests, and published links.
