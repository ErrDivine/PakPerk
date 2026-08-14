import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the Pakperk documentation library", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Pakperk Docs — Build, operate, and ship with context<\/title>/i);
  assert.match(html, /Pakperk/);
  assert.match(html, /Documentation library/);
  assert.match(html, /Pakperk developer guide/);
  assert.match(html, /Switch between English and Simplified Chinese/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("the generated library covers every repository document", async () => {
  const docsRoot = new URL("../../docs/", import.meta.url);
  const generated = await readFile(new URL("../app/generated/docs.ts", import.meta.url), "utf8");
  const page = await readFile(new URL("../app/docs-explorer.tsx", import.meta.url), "utf8");
  const packageJson = await readFile(new URL("../package.json", import.meta.url), "utf8");
  const sourceFiles = await walk(docsRoot);
  const publishedFiles = sourceFiles
    .filter((file) => /\.(?:md|json)$/.test(file))
    .map((file) => path.relative(fileURLToPath(docsRoot), file).split(path.sep).join("/"));

  for (const relativePath of publishedFiles) assert.match(generated, new RegExp(escapeRegex(relativePath)));
  assert.match(page, /role="switch"/);
  assert.match(page, /content\.htmlZh/);
  assert.match(page, /localStorage\.setItem\("pakperk-docs-language"/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
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

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
