#!/usr/bin/env bash
set -euo pipefail

realm_file="${1:-deploy/keycloak/pakperk-realm.json}"

jq -e '
  def exact_keys($expected): (keys | sort) == ($expected | sort);
  def public_client_keys: [
    "attributes", "bearerOnly", "clientAuthenticatorType", "clientId",
    "consentRequired", "defaultClientScopes", "description",
    "directAccessGrantsEnabled", "enabled", "frontchannelLogout",
    "implicitFlowEnabled", "name", "optionalClientScopes", "protocol",
    "protocolMappers", "publicClient", "redirectUris",
    "serviceAccountsEnabled", "standardFlowEnabled", "webOrigins"
  ];
  def worker_client_keys: [
    "attributes", "authorizationServicesEnabled", "bearerOnly",
    "clientAuthenticatorType", "clientId", "consentRequired",
    "defaultClientScopes", "description", "directAccessGrantsEnabled",
    "enabled", "frontchannelLogout", "fullScopeAllowed",
    "implicitFlowEnabled", "name", "optionalClientScopes", "protocol",
    "publicClient", "redirectUris", "serviceAccountsEnabled",
    "standardFlowEnabled", "webOrigins"
  ];
  def audience_mapper_keys: [
    "config", "consentRequired", "name", "protocol", "protocolMapper"
  ];
  exact_keys([
    "accessTokenLifespan", "accessTokenLifespanForImplicitFlow",
    "bruteForceProtected", "clientScopeMappings", "clients",
    "defaultSignatureAlgorithm", "displayName", "duplicateEmailsAllowed",
    "editUsernameAllowed", "enabled", "failureFactor",
    "loginWithEmailAllowed", "maxDeltaTimeSeconds", "maxFailureWaitSeconds",
    "minimumQuickLoginWaitSeconds", "offlineSessionIdleTimeout",
    "passwordPolicy", "permanentLockout", "quickLoginCheckMilliSeconds",
    "realm", "refreshTokenMaxReuse", "registrationAllowed",
    "registrationEmailAsUsername", "rememberMe", "resetPasswordAllowed",
    "revokeRefreshToken", "smtpServer", "sslRequired",
    "ssoSessionIdleTimeout", "ssoSessionMaxLifespan", "users",
    "verifyEmail", "waitIncrementSeconds"
  ]) and
  .realm == "pakperk" and
  .displayName == "Pakperk development" and
  .enabled == true and
  .sslRequired == "external" and
  .registrationAllowed == true and
  .registrationEmailAsUsername == false and
  .rememberMe == true and
  .verifyEmail == true and
  .loginWithEmailAllowed == true and
  .duplicateEmailsAllowed == false and
  .resetPasswordAllowed == true and
  .editUsernameAllowed == false and
  .bruteForceProtected == true and
  .permanentLockout == false and
  .failureFactor == 5 and
  .waitIncrementSeconds == 60 and
  .quickLoginCheckMilliSeconds == 1000 and
  .minimumQuickLoginWaitSeconds == 60 and
  .maxFailureWaitSeconds == 900 and
  .maxDeltaTimeSeconds == 43200 and
  ((.accessTokenLifespan | type) == "number") and
  (.accessTokenLifespan == (.accessTokenLifespan | floor)) and
  .accessTokenLifespan == 300 and
  .accessTokenLifespanForImplicitFlow == 0 and
  .ssoSessionIdleTimeout == 1800 and
  .ssoSessionMaxLifespan == 28800 and
  .offlineSessionIdleTimeout == 0 and
  .revokeRefreshToken == true and
  .refreshTokenMaxReuse == 0 and
  .passwordPolicy == "length(12) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername(undefined)" and
  .defaultSignatureAlgorithm == "RS256" and
  .smtpServer == {
    "host": "mailpit",
    "port": "1025",
    "from": "no-reply@pakperk.local",
    "fromDisplayName": "Pakperk development",
    "auth": "false",
    "starttls": "false",
    "ssl": "false"
  } and
  ((.clients | type) == "array") and
  ((.users | type) == "array") and
  ((.clientScopeMappings | type) == "object") and
  ([.clients[].clientId] | sort) == ([
    "pakperk-admin-dev",
    "pakperk-deletion-worker-dev",
    "pakperk-mobile-dev",
    "pakperk-web-deletion-dev"
  ] | sort) and
  ([.clients[].clientId] | length == (unique | length)) and
  (all(.clients[]; has("secret") | not)) and
  ([.clients[] | select(.clientId == "pakperk-mobile-dev")] | length == 1) and
  ([.clients[] | select(
    exact_keys(public_client_keys) and
    .clientId == "pakperk-mobile-dev" and
    .name == "Pakperk native development client" and
    .description == "Public AppAuth client; no client secret is permitted." and
    .enabled == true and
    .clientAuthenticatorType == "client-secret" and
    .publicClient == true and .standardFlowEnabled == true and
    .bearerOnly == false and .consentRequired == false and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == false and
    .frontchannelLogout == false and .protocol == "openid-connect" and
    .redirectUris == ["pakperk-auth-dev://oauth/callback"] and
    .webOrigins == [] and
    .attributes == {
      "pkce.code.challenge.method": "S256",
      "post.logout.redirect.uris": "pakperk-auth-dev://oauth/logout",
      "oauth2.device.authorization.grant.enabled": "false",
      "oidc.ciba.grant.enabled": "false",
      "backchannel.logout.session.required": "true",
      "backchannel.logout.revoke.offline.tokens": "true",
      "use.refresh.tokens": "true"
    } and
    .defaultClientScopes == ["web-origins", "acr", "profile", "roles", "basic"] and
    .optionalClientScopes == [] and
    ((.protocolMappers | type) == "array") and
    ([.protocolMappers[] | select(
      exact_keys(audience_mapper_keys) and
      .name == "Pakperk API audience" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-audience-mapper" and
      .consentRequired == false and
      .config == {
        "included.custom.audience": "pakperk-api",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "userinfo.token.claim": "false",
        "introspection.token.claim": "true"
      }
    )] | length == 1) and
    (.protocolMappers | length == 1)
  )] | length == 1) and
  ([.clients[] | select(
    exact_keys(public_client_keys) and
    .clientId == "pakperk-admin-dev" and
    .name == "Pakperk moderation operator development client" and
    .description == "Dedicated public operator client; exact app callback, PKCE S256, and admin-only audience." and
    .enabled == true and
    .clientAuthenticatorType == "client-secret" and
    .publicClient == true and .standardFlowEnabled == true and
    .bearerOnly == false and .consentRequired == false and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == false and
    .frontchannelLogout == false and .protocol == "openid-connect" and
    .redirectUris == ["pakperk-admin-dev://oauth/callback"] and
    .webOrigins == [] and
    .attributes == {
      "pkce.code.challenge.method": "S256",
      "post.logout.redirect.uris": "pakperk-admin-dev://oauth/logout",
      "oauth2.device.authorization.grant.enabled": "false",
      "oidc.ciba.grant.enabled": "false",
      "backchannel.logout.session.required": "true",
      "backchannel.logout.revoke.offline.tokens": "true",
      "use.refresh.tokens": "false"
    } and
    .defaultClientScopes == ["web-origins", "acr", "profile", "roles", "basic"] and
    .optionalClientScopes == [] and
    ((.protocolMappers | type) == "array") and
    ([.protocolMappers[] | select(
      exact_keys(audience_mapper_keys) and
      .name == "Pakperk admin audience" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-audience-mapper" and
      .consentRequired == false and
      .config == {
        "included.custom.audience": "pakperk-admin-dev",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "userinfo.token.claim": "false",
        "introspection.token.claim": "true"
      }
    )] | length == 1) and
    (.protocolMappers | length == 1)
  )] | length == 1) and
  ([.clients[] | select(
    exact_keys(public_client_keys) and
    .clientId == "pakperk-web-deletion-dev" and
    .name == "Pakperk browser deletion development client" and
    .description == "Dedicated public browser client; exact loopback callback and PKCE S256 only." and
    .enabled == true and
    .clientAuthenticatorType == "client-secret" and
    .publicClient == true and .standardFlowEnabled == true and
    .bearerOnly == false and .consentRequired == false and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == false and
    .frontchannelLogout == false and .protocol == "openid-connect" and
    .redirectUris == ["http://localhost:8082/account-deletion/"] and
    .webOrigins == ["http://localhost:8082"] and
    .attributes == {
      "pkce.code.challenge.method": "S256",
      "oauth2.device.authorization.grant.enabled": "false",
      "oidc.ciba.grant.enabled": "false",
      "backchannel.logout.session.required": "true",
      "backchannel.logout.revoke.offline.tokens": "true",
      "use.refresh.tokens": "false"
    } and
    .defaultClientScopes == ["web-origins", "acr", "basic"] and
    .optionalClientScopes == [] and
    ((.protocolMappers | type) == "array") and
    ([.protocolMappers[] | select(
      exact_keys(audience_mapper_keys) and
      .name == "Pakperk API audience" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-audience-mapper" and
      .consentRequired == false and
      .config == {
        "included.custom.audience": "pakperk-api",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "userinfo.token.claim": "false",
        "introspection.token.claim": "true"
      }
    )] | length == 1) and
    (.protocolMappers | length == 1)
  )] | length == 1) and
  ([.clients[] | select(
    exact_keys(worker_client_keys) and
    .clientId == "pakperk-deletion-worker-dev" and
    .name == "Pakperk deletion worker development client" and
    .description == "Confidential service account; generated secret is retrieved at runtime and never committed." and
    .enabled == true and
    .clientAuthenticatorType == "client-secret" and
    .publicClient == false and .standardFlowEnabled == false and
    .bearerOnly == false and .consentRequired == false and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == true and .fullScopeAllowed == false and
    .authorizationServicesEnabled == false and
    .frontchannelLogout == false and .protocol == "openid-connect" and
    .redirectUris == [] and .webOrigins == [] and
    .attributes == {
      "oauth2.device.authorization.grant.enabled": "false",
      "oidc.ciba.grant.enabled": "false",
      "use.refresh.tokens": "false"
    } and
    .defaultClientScopes == [] and .optionalClientScopes == [] and
    (((.protocolMappers // []) | type) == "array") and
    ((.protocolMappers // []) | length == 0)
  )] | length == 1) and
  ([.users[].username] | length == (unique | length)) and
  .users == [{
    "username": "service-account-pakperk-deletion-worker-dev",
    "enabled": true,
    "serviceAccountClientId": "pakperk-deletion-worker-dev",
    "clientRoles": {
      "realm-management": ["manage-users"]
    }
  }] and
  .clientScopeMappings == {
    "realm-management": [{
      "client": "pakperk-deletion-worker-dev",
      "roles": ["manage-users"]
    }]
  }
' "$realm_file" >/dev/null

printf '%s\n' "Keycloak realm policy and client boundaries validated"
