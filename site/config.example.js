// This file is documentation only. The Helm chart mounts a validated
// environment-specific /config.js. Never add a client secret: this is a
// browser public client using Authorization Code + S256 PKCE.
window.__PAKPERK_PUBLIC_CONFIG__ = Object.freeze({
  environment: "staging",
  publicOrigin: "https://staging.example.invalid",
  apiBaseUrl: "https://api.staging.example.invalid",
  oidcIssuer: "https://identity.staging.example.invalid/realms/pakperk",
  oidcClientId: "pakperk-web-deletion-staging",
  supportEmail: "support@example.invalid",
  documentVersion: "2026-07-31",
});
