import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  EXPECTED_API_ORIGIN,
  EXPECTED_OIDC_ORIGIN,
  RENDERED_MANIFEST_PATH,
  TEST_CSP,
  renderedNginx,
  renderedPublicConfig,
} from "./rendered-config.js";

const SITE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("the Nginx access log cannot record callback queries or credentials", async () => {
  const nginx = await readFile(path.join(SITE_ROOT, "nginx.conf"), "utf8");
  const logFormat = nginx.match(/log_format pakperk_safe ([^;]+);/)?.[1] || "";

  expect(logFormat).toContain("$uri");
  for (const forbidden of [
    "$request_uri",
    "$args",
    "$query_string",
    "$http_authorization",
    "$http_cookie",
    "$http_referer",
  ]) {
    expect(logFormat).not.toContain(forbidden);
  }
});

test("the fallback Nginx config inherits one complete security-header set", async () => {
  const nginx = await readFile(path.join(SITE_ROOT, "nginx.conf"), "utf8");
  for (const header of [
    "Cache-Control",
    "Content-Security-Policy",
    "Cross-Origin-Opener-Policy",
    "Cross-Origin-Resource-Policy",
    "Permissions-Policy",
    "Referrer-Policy",
    "Strict-Transport-Security",
    "X-Content-Type-Options",
    "X-Frame-Options",
  ]) {
    expect(nginx.match(new RegExp(`add_header ${header} `, "g")) ?? []).toHaveLength(1);
  }
  const locations = nginx.match(/^[ \t]*location[^\{]*\{[^\}]*\}/gms) ?? [];
  for (const location of locations) {
    expect(location).not.toContain("add_header");
  }
  expect(nginx).toContain('/config.js "no-store, max-age=0"');
  expect(nginx).toContain('/account-deletion/ "private, no-store, max-age=0"');
});

test("the checked-in runtime configuration fails closed", async () => {
  const config = await readFile(path.join(SITE_ROOT, "config.js"), "utf8");
  expect(config).toContain("window.__PAKPERK_PUBLIC_CONFIG__ = null");
  expect(config).not.toMatch(/client_secret|access_token|refresh_token/i);
});

test("the production image publishes only the curated public document tree", async () => {
  const dockerfile = await readFile(path.join(SITE_ROOT, "Dockerfile"), "utf8");
  const releaseScript = await readFile(
    path.resolve(SITE_ROOT, "..", "scripts", "prepare_release_site.sh"),
    "utf8",
  );
  const publicCopyLines = dockerfile
    .split("\n")
    .filter((line) => line.startsWith("COPY ") && line.includes("/usr/share/nginx/html/"))
    .map((line) => line.trim());

  expect(publicCopyLines).toEqual([
    "COPY --chown=101:101 release/site/ /usr/share/nginx/html/",
  ]);
  expect(dockerfile).toContain("test ! -e /usr/share/nginx/html/config.js");
  expect(dockerfile).toContain("test ! -e /usr/share/nginx/html/tests");
  expect(dockerfile).not.toMatch(/COPY[^\n]*site\/config\.js/);
  expect(dockerfile).not.toMatch(/COPY[^\n]*site\/\.well-known/);

  for (const publicArtifact of [
    "site/index.html",
    "site/404.html",
    "site/assets/site.css",
    "site/assets/site.js",
    "site/assets/account-deletion.js",
    "site/account-deletion/index.html",
    "site/community-guidelines/index.html",
    "site/open-source-licenses/index.html",
    "site/privacy/index.html",
    "site/support/index.html",
    "site/terms/index.html",
  ]) {
    expect(releaseScript).toContain(publicArtifact);
  }
  expect(releaseScript).not.toMatch(/(?:cp|install)[^\n]*site\/\s/);
  expect(releaseScript).not.toContain("site/config.js");
  expect(releaseScript).not.toContain("site/.well-known");
});

test("published safety documents keep reporting and blocking distinct", async () => {
  for (const page of ["community-guidelines", "support", "terms"]) {
    const source = await readFile(path.join(SITE_ROOT, page, "index.html"), "utf8");
    for (const label of ["Report comment", "Report user", "Block user"]) {
      expect(source).toContain(label);
    }
    expect(source).toMatch(/does not (?:itself )?hide content or create a block/i);
  }
});

test("the published deletion policy keeps authority through both retention safeguards", async () => {
  const source = await readFile(
    path.join(SITE_ROOT, "account-deletion", "index.html"),
    "utf8",
  );
  const text = source.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

  expect(text).toContain(
    "for at least 400 days and until no recoverable backup can recreate the account",
  );
  expect(text).toContain(
    "After both the 400-day minimum has elapsed and no recoverable backup can recreate the account",
  );
});

test("the rendered chart has an exact cross-origin CSP and matching public config", async () => {
  test.skip(!RENDERED_MANIFEST_PATH, "set PAKPERK_RENDERED_SITE_MANIFEST after helm template");

  const connectSource = TEST_CSP.match(/(?:^|; )connect-src ([^;]+)(?:;|$)/)?.[1];
  expect(connectSource?.split(/\s+/)).toEqual([
    "'self'",
    EXPECTED_API_ORIGIN,
    EXPECTED_OIDC_ORIGIN,
  ]);
  expect(TEST_CSP).not.toContain("*");
  expect(renderedNginx).toContain("$uri");
  expect(renderedNginx).not.toContain("$request_uri");
  expect(renderedPublicConfig).toContain(`apiBaseUrl: "${EXPECTED_API_ORIGIN}"`);
  expect(renderedPublicConfig).toContain(
    `oidcIssuer: "${EXPECTED_OIDC_ORIGIN}/realms/pakperk"`,
  );
});
