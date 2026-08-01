#!/usr/bin/env bash
set -euo pipefail

realm_file="${1:-deploy/keycloak/pakperk-realm.json}"

jq -e '
  .realm == "pakperk" and
  ([.clients[].clientId] | length == (unique | length)) and
  (all(.clients[]; has("secret") | not)) and
  ([.clients[] | select(.clientId == "pakperk-mobile-dev")] | length == 1) and
  ([.clients[] | select(
    .clientId == "pakperk-mobile-dev" and
    .publicClient == true and .standardFlowEnabled == true and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == false and
    .redirectUris == ["pakperk-auth-dev://oauth/callback"] and
    .attributes["post.logout.redirect.uris"] == "pakperk-auth-dev://oauth/logout" and
    .attributes["pkce.code.challenge.method"] == "S256"
  )] | length == 1) and
  ([.clients[] | select(
    .clientId == "pakperk-web-deletion-dev" and
    .publicClient == true and .standardFlowEnabled == true and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == false and
    .redirectUris == ["http://localhost:8082/account-deletion/"] and
    .webOrigins == ["http://localhost:8082"] and
    .attributes["pkce.code.challenge.method"] == "S256" and
    .attributes["use.refresh.tokens"] == "false"
  )] | length == 1) and
  ([.clients[] | select(
    .clientId == "pakperk-deletion-worker-dev" and
    .publicClient == false and .standardFlowEnabled == false and
    .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and
    .serviceAccountsEnabled == true and .fullScopeAllowed == false and
    .redirectUris == [] and .webOrigins == []
  )] | length == 1) and
  ([.users[] | select(
    .serviceAccountClientId == "pakperk-deletion-worker-dev" and
    .clientRoles["realm-management"] == ["manage-users"]
  )] | length == 1)
' "$realm_file" >/dev/null

printf '%s\n' "Keycloak realm client boundaries validated"
