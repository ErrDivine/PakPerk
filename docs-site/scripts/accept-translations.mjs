import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  TRANSLATION_POLICY_VERSION,
  translationPolicyDigest,
} from "./translation-policy.mjs";
import { validateTranslationQuality } from "./translation-quality.mjs";
import { validateTranslationStructure } from "./translation-structure.mjs";

const defaultRepositoryRoot = path.resolve(import.meta.dirname, "../..");
const acceptanceWorkflow = "scripts/accept-translations.mjs";

export async function acceptTranslations(
  requestedPaths,
  {
    repositoryRoot = defaultRepositoryRoot,
    acceptedAt = new Date().toISOString(),
  } = {},
) {
  if (!Array.isArray(requestedPaths) || requestedPaths.length === 0) {
    throw new Error("Provide at least one Markdown path relative to docs/, such as adr/0001-example.md");
  }
  const reviewTimestamp = normalizedTimestamp(acceptedAt);
  const normalizedPaths = [...new Set(requestedPaths.map(normalizeDocumentPath))];
  const root = path.resolve(repositoryRoot);
  const sourceRoot = path.join(root, "docs");
  const translatedRoot = path.join(root, "docs-site", "content", "zh");
  const manifestPath = path.join(translatedRoot, ".source-digests.json");

  const accepted = [];
  for (const relativePath of normalizedPaths) {
    const sourcePath = resolveWithin(sourceRoot, relativePath);
    const translationPath = resolveWithin(translatedRoot, relativePath);
    const [source, translation] = await Promise.all([
      readRequiredFile(sourcePath, sourceRoot, relativePath, "English source"),
      readRequiredFile(translationPath, translatedRoot, relativePath, "Chinese translation"),
    ]);

    try {
      validateTranslationStructure(source, translation, relativePath);
      validateTranslationQuality(source, translation, relativePath, relativePath);
    } catch (error) {
      throw new Error(`${relativePath}: translation validation failed: ${error.message}`, { cause: error });
    }

    accepted.push({
      relativePath,
      sourceSha256: sha256(source),
      translationSha256: sha256(translation),
      policyVersion: TRANSLATION_POLICY_VERSION,
      policyDigest: translationPolicyDigest(relativePath),
    });
  }

  const manifest = await readManifest(manifestPath);
  for (const record of accepted) {
    const existing = manifest[record.relativePath];
    if (existing !== undefined && !isPlainObject(existing)) {
      throw new Error(`Translation manifest record for ${record.relativePath} must be an object`);
    }
    manifest[record.relativePath] = acceptedManifestRecord(existing || {}, record, reviewTimestamp);
  }

  const ordered = Object.fromEntries(
    Object.entries(manifest).sort(([left], [right]) => comparePaths(left, right)),
  );
  await mkdir(translatedRoot, { recursive: true });
  await writeFileAtomically(manifestPath, `${JSON.stringify(ordered, null, 2)}\n`);

  return accepted.map(({ relativePath }) => relativePath);
}

function normalizeDocumentPath(requestedPath) {
  if (typeof requestedPath !== "string" || requestedPath.trim() === "") {
    throw new TypeError("Every accepted translation path must be a non-empty string");
  }
  if (requestedPath.includes("\0")) throw new Error("Translation paths must not contain a null byte");

  let candidate = requestedPath.trim().replaceAll("\\", "/").replace(/^\.\//, "");
  if (candidate.startsWith("docs/")) candidate = candidate.slice("docs/".length);
  if (path.posix.isAbsolute(candidate) || /^[a-z]:/iu.test(candidate)) {
    throw new Error(`Translation path must be relative to docs/: ${requestedPath}`);
  }

  const relativePath = path.posix.normalize(candidate);
  if (
    relativePath === "." ||
    relativePath === ".." ||
    relativePath.startsWith("../") ||
    !relativePath.endsWith(".md")
  ) {
    throw new Error(`Translation path must name a Markdown file inside docs/: ${requestedPath}`);
  }
  return relativePath;
}

function resolveWithin(root, relativePath) {
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(resolvedRoot, ...relativePath.split("/"));
  const relation = path.relative(resolvedRoot, resolved);
  if (relation === "" || relation === ".." || relation.startsWith(`..${path.sep}`) || path.isAbsolute(relation)) {
    throw new Error(`Translation path escapes its documentation root: ${relativePath}`);
  }
  return resolved;
}

async function readRequiredFile(file, root, relativePath, kind) {
  let resolvedFile;
  try {
    resolvedFile = await realpath(file);
  } catch (error) {
    if (error?.code === "ENOENT") throw new Error(`${relativePath}: missing ${kind}`);
    throw new Error(`${relativePath}: unable to resolve ${kind}: ${error.message}`, { cause: error });
  }
  const resolvedRoot = await realpath(root);
  const relation = path.relative(resolvedRoot, resolvedFile);
  if (relation === "" || relation === ".." || relation.startsWith(`..${path.sep}`) || path.isAbsolute(relation)) {
    throw new Error(`${relativePath}: ${kind} resolves outside its documentation root`);
  }
  try {
    if (!(await stat(resolvedFile)).isFile()) throw new Error("path is not a regular file");
    return await readFile(resolvedFile, "utf8");
  } catch (error) {
    throw new Error(`${relativePath}: unable to read ${kind}: ${error.message}`, { cause: error });
  }
}

async function readManifest(file) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw new Error(`Unable to read translation manifest: ${error.message}`, { cause: error });
  }
  if (!isPlainObject(parsed)) throw new Error("Translation manifest must contain a JSON object");
  return parsed;
}

function normalizedTimestamp(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError("Human-review acceptance time must be a non-empty ISO-8601 string");
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    throw new TypeError(`Invalid human-review acceptance time: ${value}`);
  }
  return parsed.toISOString();
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function acceptedManifestRecord(existing, record, acceptedAt) {
  const exactGeneratedBytes =
    existing.sourceSha256 === record.sourceSha256 &&
    existing.translationSha256 === record.translationSha256;
  return {
    sourceSha256: record.sourceSha256,
    translationSha256: record.translationSha256,
    policyVersion: record.policyVersion,
    policyDigest: record.policyDigest,
    ...(exactGeneratedBytes && typeof existing.model === "string" ? { model: existing.model } : {}),
    acceptance: {
      method: "human-review",
      acceptedAt,
      workflow: acceptanceWorkflow,
    },
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function writeFileAtomically(file, content) {
  const temporaryPath = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporaryPath, content, "utf8");
    await rename(temporaryPath, file);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function usage() {
  return "Usage: npm run accept-translations -- <docs-relative.md> [more-docs.md ...]";
}

async function runCli() {
  const requestedPaths = process.argv.slice(2);
  if (requestedPaths.includes("--help") || requestedPaths.includes("-h")) {
    console.log(usage());
    return;
  }
  if (requestedPaths.some((argument) => argument.startsWith("-"))) {
    throw new Error(`Unknown option. ${usage()}`);
  }
  const accepted = await acceptTranslations(requestedPaths);
  for (const relativePath of accepted) {
    console.log(`Accepted human-reviewed translation: ${relativePath}`);
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    await runCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
