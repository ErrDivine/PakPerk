# Pakperk public policy and deletion site

This static, JavaScript-free-by-default document set exposes the stable routes
required by the release plan. Only `/account-deletion/` needs JavaScript. Its
small local module implements browser Authorization Code + S256 PKCE without a
client secret, keeps access/refresh tokens out of persistent storage, scrubs
the callback query before the request is submitted, and calls `DELETE /v1/me`.

`config.js` intentionally fails closed. The Helm chart mounts a validated
environment-specific replacement containing public values only. A real
deployment uses a separate Keycloak public browser client with exact web origin
and redirect URI; it never reuses or broadens the native mobile client.

The checked-in Nginx configuration denies network connections from scripts.
The chart replaces only that policy with exact API and OIDC HTTPS sources. Its
access log format omits query strings, referrers, user agents, cookies, and
addresses so an authorization code never enters ordinary logs.

No analytics, third-party scripts, remote fonts, inline scripts, or tracking
pixels are present. The release pipeline replaces the placeholder license
notice with the locked dependency inventory before an artifact may ship.
