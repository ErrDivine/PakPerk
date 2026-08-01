import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  EXPECTED_API_ORIGIN,
  EXPECTED_OIDC_ORIGIN,
  EXPECTED_SITE_ORIGIN,
  TEST_CSP,
} from "./rendered-config.js";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const SITE_ROOT = path.resolve(TEST_DIRECTORY, "..");
const PUBLIC_ORIGIN = EXPECTED_SITE_ORIGIN;
const API_ORIGIN = EXPECTED_API_ORIGIN;
const OIDC_ORIGIN = EXPECTED_OIDC_ORIGIN;
const CALLBACK = `${PUBLIC_ORIGIN}/account-deletion/`;
const TOKEN_URL = `${OIDC_ORIGIN}/realms/pakperk/protocol/openid-connect/token`;
const DELETE_URL = `${API_ORIGIN}/v1/me`;
const TEST_STATE = "state-that-was-generated-for-this-browser-attempt";
const TEST_VERIFIER = "verifier-that-is-long-enough-for-the-pkce-browser-contract-1234567890";
const TEST_CODE = "authorization-code-sentinel";
const TEST_TOKEN = "access-token-sentinel-value";
const LEAK_ORIGIN = "https://credential-sink.invalid";
const OPERATION_ID = "0198f4da-383f-77f0-9404-e6d6614d26e1";
const REQUEST_ID = "0198f4da-383f-77f0-9404-e6d6614d26e2";

test.beforeEach(async ({ page }) => {
  await mountStaticSite(page);
});

test("starts a fresh S256 authorization without persisting credentials", async ({ page }) => {
  let authorizationRequest;
  await page.route(`${OIDC_ORIGIN}/**`, async (route) => {
    authorizationRequest = route.request();
    await route.fulfill({ status: 200, contentType: "text/html", body: "signed in" });
  });

  await page.goto(CALLBACK);
  await page.getByLabel(/permanent/i).check();
  await Promise.all([
    page.waitForRequest((request) => request.url().includes("/protocol/openid-connect/auth")),
    page.getByRole("button", { name: /request deletion/i }).click(),
  ]);

  expect(authorizationRequest).toBeTruthy();
  const authorization = new URL(authorizationRequest.url());
  expect(authorization.searchParams.get("client_id")).toBe("pakperk-web-deletion-staging");
  expect(authorization.searchParams.get("redirect_uri")).toBe(CALLBACK);
  expect(authorization.searchParams.get("response_type")).toBe("code");
  expect(authorization.searchParams.get("scope")).toBe("openid");
  expect(authorization.searchParams.get("code_challenge_method")).toBe("S256");
  expect(authorization.searchParams.get("code_challenge")).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(authorization.searchParams.get("state")).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(authorization.searchParams.get("prompt")).toBe("login");
  expect(authorization.searchParams.get("max_age")).toBe("0");

  await page.goto(CALLBACK);
  const storage = await page.evaluate(() => ({
    local: Object.fromEntries(Object.entries(localStorage)),
    session: Object.fromEntries(Object.entries(sessionStorage)),
  }));
  expect(storage.local).toEqual({});
  expect(Object.keys(storage.session).sort()).toEqual([
    "pakperk-delete-v1:confirmed",
    "pakperk-delete-v1:state",
    "pakperk-delete-v1:verifier",
  ]);
  expect(JSON.stringify(storage)).not.toContain("token");
});

test("an unsolicited code callback cannot clear a pending authorization attempt", async ({ page }) => {
  await seedAttempt(page);
  let tokenRequests = 0;
  await page.route(TOKEN_URL, async (route) => {
    tokenRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=wrong-state`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(tokenRequests).toBe(0);
  await expect.poll(() => page.url()).toBe(CALLBACK);
  const storage = await page.evaluate(() => Object.fromEntries(Object.entries(sessionStorage)));
  expect(storage).toEqual({
    "pakperk-delete-v1:confirmed": "true",
    "pakperk-delete-v1:state": TEST_STATE,
    "pakperk-delete-v1:verifier": TEST_VERIFIER,
  });
});

test("handles authorization cancellation without calling either backend", async ({ page }) => {
  await seedAttempt(page);
  let outboundRequests = 0;
  await page.route(`${OIDC_ORIGIN}/**`, async (route) => {
    outboundRequests += 1;
    await route.abort();
  });
  await page.route(`${API_ORIGIN}/**`, async (route) => {
    outboundRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?error=access_denied&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("cancelled or rejected");
  expect(outboundRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("an unsolicited OAuth error cannot clear a pending authorization attempt", async ({ page }) => {
  await seedAttempt(page);

  await page.goto(`${CALLBACK}?error=access_denied&state=attacker-state`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  await expect.poll(() => page.url()).toBe(CALLBACK);
  const storage = await page.evaluate(() => Object.fromEntries(Object.entries(sessionStorage)));
  expect(storage).toEqual({
    "pakperk-delete-v1:confirmed": "true",
    "pakperk-delete-v1:state": TEST_STATE,
    "pakperk-delete-v1:verifier": TEST_VERIFIER,
  });
});

test("fails closed when the token exchange fails", async ({ page }) => {
  await seedAttempt(page);
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 400,
      contentType: "application/json",
      headers: { "Cache-Control": "no-store" },
      body: JSON.stringify({ error: "invalid_grant" }),
    });
  });
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("does not forward the authorization code or PKCE verifier across a token redirect", async ({
  page,
}) => {
  await seedAttempt(page);
  const leakedRequests = [];
  await page.route(`${LEAK_ORIGIN}/**`, async (route) => {
    leakedRequests.push({
      body: route.request().postData(),
      headers: route.request().headers(),
      url: route.request().url(),
    });
    await route.abort();
  });
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 307,
      headers: {
        "Access-Control-Allow-Origin": PUBLIC_ORIGIN,
        Location: `${LEAK_ORIGIN}/oauth-code`,
      },
    });
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(leakedRequests).toEqual([]);
  await expectCallbackSecretsCleared(page);
});

test("does not forward a bearer credential across a deletion redirect", async ({ page }) => {
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);
  const leakedRequests = [];
  await page.route(`${LEAK_ORIGIN}/**`, async (route) => {
    leakedRequests.push({
      headers: route.request().headers(),
      url: route.request().url(),
    });
    await route.abort();
  });
  await page.route(DELETE_URL, async (route) => {
    await route.fulfill({
      status: 307,
      headers: {
        "Access-Control-Allow-Origin": PUBLIC_ORIGIN,
        Location: `${LEAK_ORIGIN}/bearer`,
      },
    });
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("final response was unavailable");
  expect(leakedRequests).toEqual([]);
  await expectCallbackSecretsCleared(page);
});

test("rejects a misleading token response cache directive", async ({ page }) => {
  await seedAttempt(page);
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "Cache-Control": "x-no-store" },
      body: JSON.stringify({ access_token: TEST_TOKEN, token_type: "Bearer" }),
    });
  });
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("rejects a token response with a conflicting public cache directive", async ({ page }) => {
  await seedAttempt(page);
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "Cache-Control": "public, no-store" },
      body: JSON.stringify({ access_token: TEST_TOKEN, token_type: "Bearer" }),
    });
  });
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("rejects a misleading token response media type", async ({ page }) => {
  await seedAttempt(page);
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/jsonp",
      headers: { "Cache-Control": "no-store" },
      body: JSON.stringify({ access_token: TEST_TOKEN, token_type: "Bearer" }),
    });
  });
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("rejects access tokens containing whitespace or control characters", async ({ page }) => {
  await seedAttempt(page);
  await page.route(TOKEN_URL, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json; charset=utf-8",
      headers: { "Cache-Control": "no-store" },
      body: JSON.stringify({ access_token: `${TEST_TOKEN}\nsmuggled`, token_type: "Bearer" }),
    });
  });
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("accepts the exact 202 deletion operation contract and clears the token", async ({ page }) => {
  const observations = observeSecrets(page);
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);
  let authorizationHeader;
  await page.route(DELETE_URL, async (route) => {
    authorizationHeader = route.request().headers().authorization;
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      headers: { "Cache-Control": "private, no-store" },
      body: JSON.stringify({
        deletion: {
          operation_id: OPERATION_ID,
          state: "requested",
          requested_at: "2026-08-01T12:34:56.789Z",
          updated_at: "2026-08-01T12:34:56.789Z",
        },
      }),
    });
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("accepted");
  expect(authorizationHeader).toBe(`Bearer ${TEST_TOKEN}`);
  await expectNoRetainedOrLoggedSecrets(page, observations);
});

test("reports a replayed terminal deletion as requiring support intervention", async ({ page }) => {
  const observations = observeSecrets(page);
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);
  await page.route(DELETE_URL, async (route) => {
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      headers: { "Cache-Control": "private, no-store" },
      body: JSON.stringify({
        deletion: {
          operation_id: OPERATION_ID,
          state: "failed_terminal",
          requested_at: "2026-08-01T12:34:56.789Z",
          updated_at: "2026-08-01T13:34:56.789Z",
        },
      }),
    });
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("needs support intervention");
  await expect(page.getByRole("status")).toContainText(OPERATION_ID);
  await expect(page.getByRole("status")).not.toContainText("continue in the background");
  await expectNoRetainedOrLoggedSecrets(page, observations);
});

for (const unsafeCacheControl of [
  "private, no-store, public",
  "private, no-store, max-age=0",
  "private, private, no-store",
  "private, no-store, no-store",
  "private=1, no-store",
  "private",
  "no-store",
]) {
  test(`rejects deletion cache policy ${unsafeCacheControl}`, async ({ page }) => {
    await seedAttempt(page);
    await mockSuccessfulTokenExchange(page);
    await page.route(DELETE_URL, async (route) => {
      await route.fulfill({
        status: 202,
        contentType: "application/json",
        headers: { "Cache-Control": unsafeCacheControl },
        body: JSON.stringify({
          deletion: {
            operation_id: OPERATION_ID,
            state: "requested",
            requested_at: "2026-08-01T12:34:56.789Z",
            updated_at: "2026-08-01T12:34:56.789Z",
          },
        }),
      });
    });

    await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

    await expect(page.getByRole("status")).toContainText("not safe to process");
    await expectCallbackSecretsCleared(page);
  });
}

test("treats post-commit ledger 503 as accepted and pending", async ({ page }) => {
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);
  await page.route(DELETE_URL, async (route) => {
    await route.fulfill({
      status: 503,
      contentType: "application/json",
      headers: {
        "Cache-Control": "private, no-store",
        "Retry-After": "30",
        "Access-Control-Allow-Origin": PUBLIC_ORIGIN,
        "Access-Control-Expose-Headers": "Retry-After",
      },
      body: JSON.stringify({
        error: {
          code: "ACCOUNT_DELETION_UNAVAILABLE",
          message:
            "Your account is disabled, but durable deletion processing is temporarily unavailable. Cleanup will continue automatically.",
          retryable: true,
          request_id: REQUEST_ID,
        },
      }),
    });
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("accepted locally");
  await expect(page.getByRole("status")).toContainText(REQUEST_ID);
  await expectCallbackSecretsCleared(page);
});

test("reports a browser timeout after dispatch as ambiguous and clears credentials", async ({ page }) => {
  await page.addInitScript(() => {
    const nativeSetTimeout = window.setTimeout.bind(window);
    window.setTimeout = (callback, delay, ...arguments_) =>
      nativeSetTimeout(callback, delay === 15000 ? 25 : delay, ...arguments_);
  });
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);
  await page.route(DELETE_URL, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 500));
    await route.abort().catch(() => {});
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("final response was unavailable");
  await expect(page.getByRole("status")).toContainText("may already be pending");
  await expectCallbackSecretsCleared(page);
});

test("the token deadline covers a body that never finishes", async ({ page }) => {
  await shortenDeadline(page);
  await installNeverEndingJsonResponse(page, TOKEN_URL, {
    status: 200,
    cacheControl: "no-store",
    prefix: `{"access_token":"${TEST_TOKEN}`,
  });
  await seedAttempt(page);
  let deletionRequests = 0;
  await page.route(DELETE_URL, async (route) => {
    deletionRequests += 1;
    await route.abort();
  });

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("could not complete");
  expect(deletionRequests).toBe(0);
  await expectCallbackSecretsCleared(page);
});

test("the deletion deadline covers a body that never finishes", async ({ page }) => {
  await shortenDeadline(page);
  await installNeverEndingJsonResponse(page, DELETE_URL, {
    status: 202,
    cacheControl: "private, no-store",
    prefix: `{"deletion":{"operation_id":"${OPERATION_ID}"`,
  });
  await seedAttempt(page);
  await mockSuccessfulTokenExchange(page);

  await page.goto(`${CALLBACK}?code=${TEST_CODE}&state=${TEST_STATE}`);

  await expect(page.getByRole("status")).toContainText("response could not be verified");
  await expect(page.getByRole("status")).toContainText("may already be pending");
  await expectCallbackSecretsCleared(page);
});

async function mountStaticSite(page) {
  await page.route(`${PUBLIC_ORIGIN}/**`, async (route) => {
    const url = new URL(route.request().url());
    const pathname = url.pathname;
    if (pathname === "/config.js") {
      await route.fulfill({
        status: 200,
        contentType: "application/javascript",
        headers: { "Cache-Control": "no-store" },
        body: `window.__PAKPERK_PUBLIC_CONFIG__ = Object.freeze({
          environment: "staging",
          publicOrigin: "${PUBLIC_ORIGIN}",
          apiBaseUrl: "${API_ORIGIN}",
          oidcIssuer: "${OIDC_ORIGIN}/realms/pakperk",
          oidcClientId: "pakperk-web-deletion-staging",
          supportEmail: "support@pakperk.test",
          documentVersion: "2026-08-01"
        });`,
      });
      return;
    }
    const relativePath = pathname === "/account-deletion/"
      ? "account-deletion/index.html"
      : pathname.replace(/^\//, "");
    const absolutePath = safeStaticPath(relativePath);
    let body;
    try {
      body = await readFile(absolutePath);
    } catch (_) {
      await route.fulfill({ status: 404, body: "not found" });
      return;
    }
    await route.fulfill({
      status: 200,
      contentType: contentTypeFor(absolutePath),
      headers: {
        "Cache-Control": pathname === "/account-deletion/" ? "private, no-store" : "no-cache",
        "Content-Security-Policy": TEST_CSP,
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
      },
      body,
    });
  });
}

function safeStaticPath(relativePath) {
  const absolutePath = path.resolve(SITE_ROOT, relativePath);
  if (!absolutePath.startsWith(`${SITE_ROOT}${path.sep}`)) throw new Error("unsafe fixture path");
  return absolutePath;
}

function contentTypeFor(filename) {
  if (filename.endsWith(".html")) return "text/html; charset=utf-8";
  if (filename.endsWith(".js")) return "application/javascript; charset=utf-8";
  if (filename.endsWith(".css")) return "text/css; charset=utf-8";
  return "application/octet-stream";
}

async function seedAttempt(page) {
  await page.addInitScript(
    ({ state, verifier }) => {
      sessionStorage.setItem("pakperk-delete-v1:state", state);
      sessionStorage.setItem("pakperk-delete-v1:verifier", verifier);
      sessionStorage.setItem("pakperk-delete-v1:confirmed", "true");
    },
    { state: TEST_STATE, verifier: TEST_VERIFIER },
  );
}

async function mockSuccessfulTokenExchange(page) {
  await page.route(TOKEN_URL, async (route) => {
    expect(route.request().postData()).toContain(`code=${TEST_CODE}`);
    expect(route.request().postData()).toContain(`code_verifier=${TEST_VERIFIER}`);
    expect(route.request().headers().authorization).toBeUndefined();
    expect(route.request().headers().referer).toBeUndefined();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "Cache-Control": "no-store" },
      body: JSON.stringify({ access_token: TEST_TOKEN, token_type: "Bearer" }),
    });
  });
}

async function shortenDeadline(page) {
  await page.addInitScript(() => {
    const nativeSetTimeout = window.setTimeout.bind(window);
    window.setTimeout = (callback, delay, ...arguments_) =>
      nativeSetTimeout(callback, delay === 15000 ? 25 : delay, ...arguments_);
  });
}

async function installNeverEndingJsonResponse(page, targetUrl, options) {
  await page.addInitScript(
    ({ targetUrl: expected, options: responseOptions }) => {
      const nativeFetch = window.fetch.bind(window);
      window.fetch = (input, init = {}) => {
        const requested = typeof input === "string" ? input : input.url;
        if (requested !== expected) return nativeFetch(input, init);
        const stream = new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(responseOptions.prefix));
            init.signal?.addEventListener(
              "abort",
              () => controller.error(new DOMException("deadline", "AbortError")),
              { once: true },
            );
          },
        });
        return Promise.resolve(
          new Response(stream, {
            status: responseOptions.status,
            headers: {
              "Cache-Control": responseOptions.cacheControl,
              "Content-Type": "application/json",
            },
          }),
        );
      };
    },
    { targetUrl, options },
  );
}

function observeSecrets(page) {
  const consoleMessages = [];
  const outboundUrls = [];
  page.on("console", (message) => consoleMessages.push(message.text()));
  page.on("request", (request) => outboundUrls.push(request.url()));
  return { consoleMessages, outboundUrls };
}

async function expectCallbackSecretsCleared(page) {
  await expect.poll(() => page.url()).toBe(CALLBACK);
  const storage = await page.evaluate(() => ({
    local: Object.fromEntries(Object.entries(localStorage)),
    session: Object.fromEntries(Object.entries(sessionStorage)),
  }));
  expect(storage.local).toEqual({});
  expect(storage.session).toEqual({});
  expect(JSON.stringify(storage)).not.toContain(TEST_CODE);
  expect(JSON.stringify(storage)).not.toContain(TEST_TOKEN);
}

async function expectNoRetainedOrLoggedSecrets(page, observations) {
  await expectCallbackSecretsCleared(page);
  expect(observations.consoleMessages.join("\n")).not.toContain(TEST_CODE);
  expect(observations.consoleMessages.join("\n")).not.toContain(TEST_TOKEN);
  const nonCallbackUrls = observations.outboundUrls.filter(
    (value) => !value.startsWith(`${CALLBACK}?code=`),
  );
  expect(nonCallbackUrls.join("\n")).not.toContain(TEST_CODE);
  expect(nonCallbackUrls.join("\n")).not.toContain(TEST_TOKEN);
}
