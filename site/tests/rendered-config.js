import { readFile } from "node:fs/promises";

export const EXPECTED_API_ORIGIN = "https://api.staging.pakperk.app";
export const EXPECTED_OIDC_ORIGIN = "https://identity.staging.pakperk.app";
export const EXPECTED_SITE_ORIGIN = "https://staging.pakperk.app";
export const RENDERED_MANIFEST_PATH = process.env.PAKPERK_RENDERED_SITE_MANIFEST || "";

let renderedNginx = "";
let renderedPublicConfig = "";
if (RENDERED_MANIFEST_PATH) {
  const manifest = await readFile(RENDERED_MANIFEST_PATH, "utf8");
  renderedPublicConfig = literalBlock(manifest, "config.js", "  default.conf:");
  renderedNginx = literalBlock(manifest, "default.conf", "---");
}

export const TEST_CSP = renderedNginx
  ? renderedNginx.match(/add_header Content-Security-Policy "([^"]+)" always;/)?.[1] || ""
  : `default-src 'self'; base-uri 'none'; connect-src 'self' ${EXPECTED_API_ORIGIN} ${EXPECTED_OIDC_ORIGIN}; ` +
    "font-src 'self'; form-action 'none'; frame-ancestors 'none'; img-src 'self' data:; " +
    "object-src 'none'; script-src 'self'; style-src 'self'";

export { renderedNginx, renderedPublicConfig };

function literalBlock(manifest, key, nextMarker) {
  const marker = `  ${key}: |\n`;
  const start = manifest.indexOf(marker);
  if (start < 0) throw new Error(`rendered ConfigMap is missing ${key}`);
  const contentStart = start + marker.length;
  const end = manifest.indexOf(`\n${nextMarker}`, contentStart);
  if (end < 0) throw new Error(`rendered ConfigMap has no boundary after ${key}`);
  return manifest
    .slice(contentStart, end)
    .split("\n")
    .map((line) => (line.startsWith("    ") ? line.slice(4) : line))
    .join("\n");
}
