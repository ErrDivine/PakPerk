(function () {
  "use strict";

  const runtime = window.PakperkPublicConfig;
  const confirm = document.querySelector("#confirm-deletion");
  const start = document.querySelector("#start-deletion");
  const status = document.querySelector("#deletion-status");
  const STORAGE_PREFIX = "pakperk-delete-v1:";
  const MAX_JSON_BYTES = 32768;
  let accessToken = null;

  if (!runtime || runtime.error || !runtime.value) {
    setStatus("Account deletion is unavailable because this deployment is not configured.", "error");
    start.disabled = true;
    return;
  }

  const config = runtime.value;
  const redirectUri = new URL("/account-deletion/", config.publicOrigin).toString();
  const current = new URL(window.location.href);
  if (current.origin !== new URL(config.publicOrigin).origin || current.pathname !== "/account-deletion/") {
    setStatus("Account deletion is unavailable on this origin.", "error");
    start.disabled = true;
    return;
  }

  confirm.addEventListener("change", () => {
    start.disabled = !confirm.checked;
  });
  start.addEventListener("click", beginAuthorization);

  if (current.searchParams.has("code") || current.searchParams.has("error")) {
    completeAuthorization(current).catch(() => {
      accessToken = null;
      setStatus("We could not complete the deletion request. No token was retained. Please try again.", "error");
    });
  }

  async function beginAuthorization() {
    if (!confirm.checked) return;
    start.disabled = true;
    const state = randomUrlSafe(32);
    const verifier = randomUrlSafe(64);
    const challenge = await sha256UrlSafe(verifier);
    sessionStorage.setItem(`${STORAGE_PREFIX}state`, state);
    sessionStorage.setItem(`${STORAGE_PREFIX}verifier`, verifier);
    sessionStorage.setItem(`${STORAGE_PREFIX}confirmed`, "true");

    const authorization = new URL(`${trimSlash(config.oidcIssuer)}/protocol/openid-connect/auth`);
    authorization.searchParams.set("client_id", config.oidcClientId);
    authorization.searchParams.set("redirect_uri", redirectUri);
    authorization.searchParams.set("response_type", "code");
    authorization.searchParams.set("scope", "openid");
    authorization.searchParams.set("state", state);
    authorization.searchParams.set("code_challenge", challenge);
    authorization.searchParams.set("code_challenge_method", "S256");
    authorization.searchParams.set("prompt", "login");
    authorization.searchParams.set("max_age", "0");
    window.location.assign(authorization.toString());
  }

  async function completeAuthorization(url) {
    const state = sessionStorage.getItem(`${STORAGE_PREFIX}state`);
    const verifier = sessionStorage.getItem(`${STORAGE_PREFIX}verifier`);
    const confirmed = sessionStorage.getItem(`${STORAGE_PREFIX}confirmed`) === "true";
    const returnedState = url.searchParams.get("state");
    history.replaceState(null, "", "/account-deletion/");

    if (url.searchParams.has("error")) {
      if (!confirmed || !state || state.length > 128 || returnedState !== state) {
        throw new Error("invalid authorization error response");
      }
      clearTransientState();
      setStatus("Sign-in was cancelled or rejected. Your account was not changed.", "error");
      start.disabled = !confirm.checked;
      return;
    }
    const code = url.searchParams.get("code");
    if (
      !confirmed ||
      !code ||
      code.length > 4096 ||
      !state ||
      state.length > 128 ||
      !verifier ||
      verifier.length > 128 ||
      returnedState !== state
    ) {
      throw new Error("invalid authorization response");
    }
    clearTransientState();

    setStatus("Verifying your recent sign-in…", "progress");
    const tokenBody = new URLSearchParams({
      grant_type: "authorization_code",
      client_id: config.oidcClientId,
      redirect_uri: redirectUri,
      code,
      code_verifier: verifier,
    });
    const tokenFetch = await boundedFetch(
      `${trimSlash(config.oidcIssuer)}/protocol/openid-connect/token`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: tokenBody,
        cache: "no-store",
        credentials: "omit",
        redirect: "error",
        referrerPolicy: "no-referrer",
      },
    );
    const tokenResponse = tokenFetch.response;
    if (!tokenResponse.ok) {
      releaseBoundedFetch(tokenFetch);
      throw new Error("token exchange failed");
    }
    if (!hasSafeTokenCachePolicy(tokenResponse)) {
      releaseBoundedFetch(tokenFetch);
      throw new Error("unsafe token response cache policy");
    }
    let tokenPayload = await readBoundedJson(tokenFetch, MAX_JSON_BYTES);
    if (
      typeof tokenPayload.access_token !== "string" ||
      tokenPayload.access_token.length < 16 ||
      tokenPayload.access_token.length > 16384 ||
      !/^[A-Za-z0-9._~+\/-]+=*$/.test(tokenPayload.access_token) ||
      tokenPayload.token_type !== "Bearer"
    ) {
      throw new Error("missing access token");
    }
    accessToken = tokenPayload.access_token;
    tokenPayload.access_token = "";
    tokenPayload.refresh_token = "";
    tokenPayload.id_token = "";
    tokenPayload = null;

    setStatus("Submitting the deletion request…", "progress");
    let deletionResponse;
    let dispatched = false;
    try {
      dispatched = true;
      deletionResponse = await boundedFetch(`${trimSlash(config.apiBaseUrl)}/v1/me`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${accessToken}` },
        cache: "no-store",
        credentials: "omit",
        redirect: "error",
        referrerPolicy: "no-referrer",
      });
    } catch (_) {
      if (dispatched) {
        setStatus(
          "The request was sent, but its final response was unavailable. Deletion may already be pending. Retry safely or contact support with the time of this attempt.",
          "error",
        );
        return;
      }
      throw new Error("deletion request was not dispatched");
    } finally {
      accessToken = null;
    }

    if (
      !hasExactCachePolicy(deletionResponse.response, ["private", "no-store"])
    ) {
      releaseBoundedFetch(deletionResponse);
      setStatus(
        "The request reached Pakperk, but its response was not safe to process. Deletion may already be pending. Retry or contact support.",
        "error",
      );
      return;
    }
    let deletionPayload;
    try {
      deletionPayload = await readBoundedJson(deletionResponse, 16384);
    } catch (_) {
      setStatus(
        "The request reached Pakperk, but its response could not be verified. Deletion may already be pending. Retry or contact support.",
        "error",
      );
      return;
    }
    if (
      deletionResponse.response.status === 503 &&
      deletionResponse.response.headers.get("retry-after") === "30" &&
      validUnavailableEnvelope(deletionPayload)
    ) {
      setStatus(
        `Your deletion was accepted locally and is pending secure ledger synchronization. Access is disabled. If you contact support, provide request ID ${deletionPayload.error.request_id}.`,
        "success",
      );
      confirm.checked = false;
      start.disabled = true;
      return;
    }
    if (deletionResponse.response.status !== 202 || !validAcceptedEnvelope(deletionPayload)) {
      setStatus(
        "Pakperk returned an unexpected result after receiving the request. Deletion may already be pending. Retry or contact support.",
        "error",
      );
      return;
    }
    confirm.checked = false;
    start.disabled = true;
    if (deletionPayload.deletion.state === "failed_terminal") {
      setStatus(
        `Your account remains disabled, but automated deletion stopped and needs support intervention. Contact support with operation ID ${deletionPayload.deletion.operation_id}.`,
        "error",
      );
      return;
    }
    if (deletionPayload.deletion.state === "completed") {
      setStatus("Your account deletion is complete.", "success");
      return;
    }
    setStatus(
      "Your deletion request was accepted. Access is disabled now; provider and app data removal continue in the background.",
      "success",
    );
  }

  async function boundedFetch(url, options) {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(url, { ...options, signal: controller.signal });
      return { response, controller, timer, released: false };
    } catch (error) {
      window.clearTimeout(timer);
      throw error;
    }
  }

  async function readBoundedJson(bounded, maximumBytes) {
    const response = bounded.response;
    const contentType = (response.headers.get("content-type") || "").toLowerCase();
    if (contentType.split(";", 1)[0].trim() !== "application/json") {
      releaseBoundedFetch(bounded);
      throw new Error("unexpected content type");
    }
    const declared = Number(response.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > maximumBytes) {
      releaseBoundedFetch(bounded);
      throw new Error("response too large");
    }
    if (!response.body) {
      releaseBoundedFetch(bounded);
      throw new Error("missing response body");
    }
    const reader = response.body.getReader();
    const chunks = [];
    let length = 0;
    let complete = false;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          complete = true;
          break;
        }
        length += value.byteLength;
        if (length > maximumBytes) throw new Error("response too large");
        chunks.push(value);
      }
    } finally {
      if (!complete) await reader.cancel().catch(() => {});
      releaseBoundedFetch(bounded);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    chunks.forEach((chunk) => {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    });
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  }

  function releaseBoundedFetch(bounded) {
    if (!bounded || bounded.released) return;
    bounded.released = true;
    window.clearTimeout(bounded.timer);
  }

  function cacheDirectives(response) {
    const value = response.headers.get("cache-control") || "";
    return value
      .split(",")
      .map((directive) => directive.trim().toLowerCase())
      .filter(Boolean);
  }

  function hasSafeTokenCachePolicy(response) {
    const directives = cacheDirectives(response);
    return directives.includes("no-store") && !directives.includes("public");
  }

  function hasExactCachePolicy(response, expected) {
    const directives = cacheDirectives(response);
    return (
      directives.length === expected.length &&
      new Set(directives).size === expected.length &&
      expected.every((directive) => directives.includes(directive))
    );
  }

  function validAcceptedEnvelope(payload) {
    const deletion = payload && payload.deletion;
    const states = new Set([
      "requested",
      "sessions_revoked",
      "identity_deleted",
      "app_data_deleted",
      "completed",
      "failed_retryable",
      "failed_terminal",
    ]);
    return Boolean(
      deletion &&
        hasExactKeys(payload, ["deletion"]) &&
        typeof deletion === "object" &&
        hasExactKeys(deletion, ["operation_id", "state", "requested_at", "updated_at"]) &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
          deletion.operation_id || "",
        ) &&
        states.has(deletion.state) &&
        validUtcTimestamp(deletion.requested_at) &&
        validUtcTimestamp(deletion.updated_at) &&
        Date.parse(deletion.updated_at) >= Date.parse(deletion.requested_at),
    );
  }

  function validUtcTimestamp(value) {
    return (
      typeof value === "string" &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
      Number.isFinite(Date.parse(value))
    );
  }

  function validUnavailableEnvelope(payload) {
    return Boolean(
      payload &&
        hasExactKeys(payload, ["error"]) &&
        payload.error &&
        hasExactKeys(payload.error, ["code", "message", "retryable", "request_id"]) &&
        payload.error.code === "ACCOUNT_DELETION_UNAVAILABLE" &&
        payload.error.message ===
          "Your account is disabled, but durable deletion processing is temporarily unavailable. Cleanup will continue automatically." &&
        payload.error.retryable === true &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
          payload.error.request_id || "",
        ),
    );
  }

  function hasExactKeys(value, expected) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const actual = Object.keys(value).sort();
    const wanted = [...expected].sort();
    return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
  }

  function clearTransientState() {
    sessionStorage.removeItem(`${STORAGE_PREFIX}state`);
    sessionStorage.removeItem(`${STORAGE_PREFIX}verifier`);
    sessionStorage.removeItem(`${STORAGE_PREFIX}confirmed`);
  }

  function randomUrlSafe(bytes) {
    const value = new Uint8Array(bytes);
    crypto.getRandomValues(value);
    return base64Url(value);
  }

  async function sha256UrlSafe(value) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
    return base64Url(new Uint8Array(digest));
  }

  function base64Url(value) {
    let binary = "";
    value.forEach((byte) => {
      binary += String.fromCharCode(byte);
    });
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  }

  function trimSlash(value) {
    return value.replace(/\/$/, "");
  }

  function setStatus(message, kind) {
    status.hidden = false;
    status.dataset.kind = kind;
    status.textContent = message;
  }

  window.addEventListener("pagehide", () => {
    accessToken = null;
  });
})();
