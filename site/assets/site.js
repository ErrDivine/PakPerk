(function () {
  "use strict";

  const config = window.__PAKPERK_PUBLIC_CONFIG__;
  const deploymentError = validateConfig(config);
  document.documentElement.dataset.config = deploymentError ? "invalid" : "ready";

  document.querySelectorAll("[data-document-version]").forEach((node) => {
    node.textContent = deploymentError ? "configuration unavailable" : config.documentVersion;
  });

  document.querySelectorAll("[data-support-link]").forEach((node) => {
    if (deploymentError) {
      node.removeAttribute("href");
      node.setAttribute("aria-disabled", "true");
      return;
    }
    node.href = `mailto:${config.supportEmail}`;
  });

  const warning = document.querySelector("[data-config-warning]");
  if (warning && deploymentError) {
    warning.hidden = false;
    warning.textContent = "This deployment is not configured for public use.";
  }

  function validateConfig(value) {
    if (!value || typeof value !== "object") return "missing config";
    if (value.environment !== "staging" && value.environment !== "production") {
      return "invalid environment";
    }
    for (const key of ["publicOrigin", "apiBaseUrl", "oidcIssuer"]) {
      let parsed;
      try {
        parsed = new URL(value[key]);
      } catch (_) {
        return `invalid ${key}`;
      }
      if (parsed.protocol !== "https:" || parsed.username || parsed.password) {
        return `unsafe ${key}`;
      }
      const host = parsed.hostname.toLowerCase();
      if (
        host === "localhost" ||
        host === "127.0.0.1" ||
        host === "::1" ||
        host.endsWith(".localhost") ||
        host === "example.com" ||
        host === "example.org" ||
        host === "example.net" ||
        host.endsWith(".example.com") ||
        host.endsWith(".example.org") ||
        host.endsWith(".example.net") ||
        host.endsWith(".example") ||
        host.endsWith(".invalid")
      ) {
        return `placeholder ${key}`;
      }
      if (key !== "oidcIssuer" && parsed.pathname !== "/") return `invalid ${key}`;
      if (parsed.search || parsed.hash) return `invalid ${key}`;
    }
    if (
      typeof value.oidcClientId !== "string" ||
      !/^[A-Za-z0-9._-]{3,128}$/.test(value.oidcClientId)
    ) {
      return "invalid OIDC client";
    }
    if (
      typeof value.supportEmail !== "string" ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.supportEmail) ||
      /(?:example\.(?:com|org|net)|example|invalid)$/i.test(value.supportEmail.split("@")[1] || "")
    ) {
      return "invalid support contact";
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value.documentVersion || "")) {
      return "invalid document version";
    }
    return "";
  }

  window.PakperkPublicConfig = Object.freeze({
    value: deploymentError ? null : Object.freeze({ ...config }),
    error: deploymentError,
  });
})();
