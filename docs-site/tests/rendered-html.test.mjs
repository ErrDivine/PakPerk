import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import {
  TRANSLATION_POLICY_VERSION,
  translationPolicyDigest,
} from "../scripts/translation-policy.mjs";
import { validateTranslationQuality } from "../scripts/translation-quality.mjs";
import { validateTranslationStructure } from "../scripts/translation-structure.mjs";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request(new URL(pathname, "http://localhost"), { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the Pakperk documentation library", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Pakperk Docs — Develop, test on phones, and deploy<\/title>/i);
  assert.match(html, /Pakperk/);
  assert.match(html, /Documentation library/);
  assert.match(html, /Pakperk developer guide/);
  assert.match(html, /Switch between English and Simplified Chinese/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("server-renders an explicit Chinese request in Chinese before hydration", async () => {
  const response = await render("/?lang=zh&doc=backend-deployment");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /<div class="docs-shell" lang="zh-CN">/);
  assert.match(html, /aria-label="文档库"/);
  assert.match(html, /aria-label="在英文和简体中文之间切换"/);
  assert.doesNotMatch(html, /aria-label="Documentation library"/);
});

test("the generated library covers every repository document", async () => {
  const docsRoot = new URL("../../docs/", import.meta.url);
  const generated = await readFile(new URL("../app/generated/docs.ts", import.meta.url), "utf8");
  const generatedDocuments = parseGeneratedDocuments(generated);
  const page = await readFile(new URL("../app/docs-explorer.tsx", import.meta.url), "utf8");
  const packageJson = await readFile(new URL("../package.json", import.meta.url), "utf8");
  const translationManifest = await readJsonOrDefault(
    new URL("../content/zh/.source-digests.json", import.meta.url),
    {},
  );
  const sourceFiles = await walk(docsRoot);
  const publishedFiles = sourceFiles
    .filter((file) => /\.(?:md|json)$/.test(file))
    .map((file) => path.relative(fileURLToPath(docsRoot), file).split(path.sep).join("/"));

  assert.equal(generatedDocuments.length, publishedFiles.length);
  const documentsByPath = new Map(generatedDocuments.map((document) => [document.path, document]));
  for (const relativePath of publishedFiles) {
    const source = await readFile(new URL(relativePath, docsRoot), "utf8");
    const document = documentsByPath.get(relativePath);
    assert.ok(document, `missing generated metadata for ${relativePath}`);
    assert.equal(document.sourceSha256, sha256(source), `stale generated metadata for ${relativePath}`);
    const expectedTranslationStatus = await translationStatusFor(
      relativePath,
      source,
      translationManifest[relativePath],
    );
    assert.equal(
      document.translationStatus,
      expectedTranslationStatus,
      `incorrect translation status for ${relativePath}`,
    );
    if (document.translationStatus !== "translated") {
      const content = JSON.parse(
        await readFile(new URL(`../public/docs-data/${document.id}.json`, import.meta.url), "utf8"),
      );
      assert.equal(content.htmlZh, content.html, `unsafe Chinese fallback for ${relativePath}`);
    }
  }

  const expectedDataFiles = generatedDocuments.map((document) => `${document.id}.json`).sort();
  const actualDataFiles = (await readdir(new URL("../public/docs-data/", import.meta.url)))
    .filter((file) => file.endsWith(".json"))
    .sort();
  assert.deepEqual(actualDataFiles, expectedDataFiles, "public docs data contains a missing or orphaned document");

  assert.ok(documentsByPath.has("developer-guide.md"));
  assert.ok(documentsByPath.has("mobile-device-development.md"));
  assert.ok(documentsByPath.has("backend-deployment.md"));
  assert.match(page, /role="switch"/);
  assert.match(page, /content\.htmlZh/);
  assert.match(page, /translationStatus/);
  assert.match(page, /localStorage\.setItem\("pakperk-docs-language"/);
  assert.match(packageJson, /npm run check-docs/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
});

test("generated articles do not repeat their source title", async () => {
  const content = JSON.parse(
    await readFile(new URL("../public/docs-data/developer-guide.json", import.meta.url), "utf8"),
  );
  assert.doesNotMatch(content.html, /<h1\b/i);
  assert.doesNotMatch(content.html, /id="pakperk-developer-guide"/i);
  assert.match(content.html, /<h2 id="choose-the-path-you-need">/i);
});

async function walk(url) {
  const directory = fileURLToPath(url);
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(pathToFileURL(`${entryPath}/`))));
    else files.push(entryPath);
  }
  return files;
}

function parseGeneratedDocuments(source) {
  const prefix = "export const docs = ";
  const start = source.indexOf(prefix);
  const end = source.lastIndexOf(" as const;");
  assert.notEqual(start, -1, "generated document export is missing");
  assert.notEqual(end, -1, "generated document export terminator is missing");
  return JSON.parse(source.slice(start + prefix.length, end));
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function translationStatusFor(relativePath, source, record) {
  if (relativePath.endsWith(".json")) return "source";
  const translated = await readFile(
    new URL(`../content/zh/${relativePath}`, import.meta.url),
    "utf8",
  ).catch((error) => {
    if (error?.code === "ENOENT") return null;
    throw error;
  });
  if (translated === null) return "missing";
  if (record === undefined) return "unverified";
  if (
    record.sourceSha256 !== sha256(source) ||
    record.translationSha256 !== sha256(translated) ||
    record.policyVersion !== TRANSLATION_POLICY_VERSION ||
    record.policyDigest !== translationPolicyDigest(relativePath)
  ) {
    return "stale";
  }
  try {
    validateTranslationStructure(source, translated, relativePath);
    validateTranslationQuality(source, translated, relativePath, relativePath);
    return "translated";
  } catch {
    return "invalid";
  }
}

async function readJsonOrDefault(url, fallback) {
  try {
    return JSON.parse(await readFile(url, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return fallback;
    throw error;
  }
}
