import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  protectMarkdownForTranslation,
  normalizeSurplusMarkdownHardBreaks,
  removeAddedMarkdownLinks,
  restoreAndValidateTranslation,
  splitMarkdown,
  validateTranslationStructure,
} from "./translation-structure.mjs";
import {
  modelProtectedLiteralsFor,
  TRANSLATION_POLICY_VERSION,
  translationPolicyDigest,
  translationSystemPrompt,
} from "./translation-policy.mjs";
import {
  normalizeTranslationTerminology,
  validateTranslationQuality,
} from "./translation-quality.mjs";
import {
  createTranslationSegmentCacheKey,
  deleteTranslationSegment,
  readValidatedTranslationSegment,
  revalidateCompatibleTranslationSegment,
  resolveTranslationCacheRoot,
  TRANSLATION_OPTIONS_VERSION,
  TRANSLATION_REQUEST_OPTIONS,
  writeTranslationSegment,
} from "./translation-cache.mjs";

const root = path.resolve(import.meta.dirname, "../..");
const sourceRoot = path.join(root, "docs");
const outputRoot = path.join(root, "docs-site", "content", "zh");
const manifestPath = path.join(outputRoot, ".source-digests.json");
const model = process.env.PAKPERK_TRANSLATION_MODEL || "qwen3:8b";
const force = process.argv.includes("--force");
const requestTimeoutMilliseconds = Number(process.env.PAKPERK_TRANSLATION_TIMEOUT_MS || 180_000);
const requestedFile = process.env.PAKPERK_TRANSLATION_FILE?.split(path.sep).join("/");
const segmentCacheRoot = resolveTranslationCacheRoot(process.env.PAKPERK_TRANSLATION_CACHE_DIR);
if (!force) console.log(`Translation segment cache: ${segmentCacheRoot}`);

const allFiles = (await walk(sourceRoot))
  .filter((file) => file.endsWith(".md"))
  .sort(comparePaths);
const files = requestedFile
  ? allFiles.filter((file) => path.relative(sourceRoot, file).split(path.sep).join("/") === requestedFile)
  : allFiles;
if (requestedFile && files.length === 0) throw new Error(`Unknown documentation path: ${requestedFile}`);
const manifest = await readJson(manifestPath, {});
const publishedPaths = new Set(
  allFiles.map((file) => path.relative(sourceRoot, file).split(path.sep).join("/")),
);
for (const relativePath of Object.keys(manifest)) {
  if (!publishedPaths.has(relativePath)) delete manifest[relativePath];
}

const failures = [];
for (const [index, sourcePath] of files.entries()) {
  const relativePath = path.relative(sourceRoot, sourcePath).split(path.sep).join("/");
  const outputPath = path.join(outputRoot, relativePath);
  const source = await readFile(sourcePath, "utf8");
  const sourceSha256 = sha256(source);
  const policyDigest = translationPolicyDigest(relativePath);
  if (!force && (await isCurrent(source, sourceSha256, policyDigest, outputPath, manifest[relativePath], relativePath))) {
    console.log(`[${index + 1}/${files.length}] current ${relativePath}`);
    continue;
  }

  try {
    const segments = splitMarkdown(source);
    const translated = [];
    const segmentCacheKeys = [];
    console.log(`[${index + 1}/${files.length}] translating ${relativePath} (${segments.length} segments)`);

    for (const [segmentIndex, segment] of segments.entries()) {
      const part = segmentIndex + 1;
      const total = segments.length;
      let response = null;
      let cacheKey = null;
      let cacheInput = null;
      if (!force) {
        cacheInput = {
          segment,
          relativePath,
          part,
          total,
          policyDigest,
          model,
          optionsVersion: TRANSLATION_OPTIONS_VERSION,
          requestOptions: TRANSLATION_REQUEST_OPTIONS,
        };
        cacheKey = createTranslationSegmentCacheKey(cacheInput);
        segmentCacheKeys.push(cacheKey);
        response = await readValidatedTranslationSegment({
          cacheRoot: segmentCacheRoot,
          cacheInput,
          validate: (candidate) => processCandidateTranslation(segment, candidate, relativePath, part, total),
        });
        if (response !== null) console.log(`  cached part ${part}/${total}`);
        else {
          try {
            response = await revalidateCompatibleTranslationSegment({
              cacheRoot: segmentCacheRoot,
              cacheInput,
              validate: (candidate) =>
                processCandidateTranslation(segment, candidate, relativePath, part, total),
            });
            if (response !== null) console.log(`  revalidated cached part ${part}/${total}`);
          } catch (error) {
            console.warn(`  unable to promote a compatible cached part ${part}/${total}: ${error.message}`);
          }
        }
      }
      if (response === null) {
        response = await translate(segment, relativePath, part, total);
        if (!force) {
          try {
            await writeTranslationSegment({ cacheRoot: segmentCacheRoot, cacheInput, translation: response });
          } catch (error) {
            console.warn(`  unable to cache part ${part}/${total}: ${error.message}`);
          }
        }
        console.log(`  completed part ${part}/${total}`);
      }
      const trailingSpace = segment.match(/\s*$/)?.[0] || "";
      translated.push(`${response.trimEnd()}${trailingSpace}`);
    }

    await mkdir(path.dirname(outputPath), { recursive: true });
    const output = `${translated.join("").trimEnd()}\n`;
    try {
      validateTranslationStructure(source, output, relativePath);
      validateTranslationQuality(source, output, relativePath, relativePath);
    } catch (error) {
      if (!force) await clearCachedSegments(segmentCacheKeys, relativePath);
      throw error;
    }
    await writeFileAtomically(outputPath, output);
    manifest[relativePath] = {
      sourceSha256,
      translationSha256: sha256(output),
      policyVersion: TRANSLATION_POLICY_VERSION,
      policyDigest,
      model,
    };
    await writeManifest();
    if (!force) await clearCachedSegments(segmentCacheKeys, relativePath);
  } catch (error) {
    failures.push({ relativePath, message: error.message });
    console.error(`[${index + 1}/${files.length}] failed ${relativePath}: ${error.message}`);
  }
}

await writeManifest();
if (failures.length > 0) {
  const summary = failures.map(({ relativePath, message }) => `- ${relativePath}: ${message}`).join("\n");
  throw new Error(`Translation failed for ${failures.length} document(s):\n${summary}`);
}

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(entryPath)));
    else files.push(entryPath);
  }
  return files;
}

async function isCurrent(source, sourceSha256, policyDigest, outputPath, record, relativePath) {
  try {
    const output = await readFile(outputPath, "utf8");
    if (
      record?.sourceSha256 !== sourceSha256 ||
      record?.translationSha256 !== sha256(output) ||
      record?.policyVersion !== TRANSLATION_POLICY_VERSION ||
      record?.policyDigest !== policyDigest
    ) return false;
    validateTranslationStructure(source, output, relativePath);
    validateTranslationQuality(source, output, relativePath, relativePath);
    return true;
  } catch {
    return false;
  }
}

async function writeManifest() {
  const ordered = Object.fromEntries(Object.entries(manifest).sort(([left], [right]) => comparePaths(left, right)));
  await mkdir(outputRoot, { recursive: true });
  await writeFileAtomically(manifestPath, `${JSON.stringify(ordered, null, 2)}\n`);
}

async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return fallback;
    throw error;
  }
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

async function translate(markdown, file, part, total) {
  const protectedMarkdown = protectMarkdownForTranslation(
    markdown,
    `${file} part ${part}/${total}`,
    { protectedLiterals: modelProtectedLiteralsFor(file) },
  );
  let validationFeedback = "";
  for (let attempt = 1; attempt <= TRANSLATION_REQUEST_OPTIONS.attempts; attempt += 1) {
    let response;
    try {
      response = await fetch("http://127.0.0.1:11434/api/chat", {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal: AbortSignal.timeout(requestTimeoutMilliseconds),
        body: JSON.stringify({
          model,
          stream: TRANSLATION_REQUEST_OPTIONS.stream,
          think: TRANSLATION_REQUEST_OPTIONS.think,
          keep_alive: TRANSLATION_REQUEST_OPTIONS.keepAlive,
          options: {
            temperature: attempt === 1
              ? TRANSLATION_REQUEST_OPTIONS.initialTemperature
              : TRANSLATION_REQUEST_OPTIONS.retryTemperature,
            num_ctx: TRANSLATION_REQUEST_OPTIONS.numContextTokens,
          },
          messages: [
            {
              role: "system",
              content: `${translationSystemPrompt(file)}${validationFeedback}`,
            },
            { role: "user", content: protectedMarkdown.masked },
          ],
        }),
      });
    } catch (error) {
      if (attempt === TRANSLATION_REQUEST_OPTIONS.attempts) {
        throw new Error(`Ollama request failed: ${error.message}`);
      }
      validationFeedback = "\n\nThe previous request failed before validation. Return the complete translation now.";
      continue;
    }

    if (!response.ok) {
      if (attempt === TRANSLATION_REQUEST_OPTIONS.attempts) {
        throw new Error(`Ollama returned ${response.status}: ${await response.text()}`);
      }
      validationFeedback = `\n\nThe previous request returned HTTP ${response.status}. Return the complete translation now.`;
      continue;
    }
    const payload = await response.json();
    const content = payload?.message?.content;
    if (!content) {
      if (attempt === TRANSLATION_REQUEST_OPTIONS.attempts) {
        throw new Error("Ollama returned no translated content");
      }
      validationFeedback = "\n\nThe previous response was empty. Return the complete translated Markdown now.";
      continue;
    }
    try {
      const restored = protectedMarkdown.restore(content);
      return processCandidateTranslation(markdown, restored, file, part, total);
    } catch (error) {
      if (attempt === TRANSLATION_REQUEST_OPTIONS.attempts) {
        throw new Error(`${file} part ${part}/${total}: ${error.message}`);
      }
      console.warn(`  retrying part ${part}/${total} after validation failure: ${error.message}`);
      validationFeedback =
        `\n\nYour previous response failed an automated structure check: ${error.message}. ` +
        "Translate the original text again and correct that exact problem. Return the complete translated Markdown only.";
    }
  }
  throw new Error(`${file} part ${part}/${total}: translation failed`);
}

function processCandidateTranslation(markdown, candidate, file, part, total) {
  const label = `${file} part ${part}/${total}`;
  const normalized = normalizeTranslationTerminology(markdown, candidate, file, label);
  const linksCleaned = removeAddedMarkdownLinks(markdown, normalized);
  const hardBreaksNormalized = normalizeSurplusMarkdownHardBreaks(markdown, linksCleaned, label);
  const validated = restoreAndValidateTranslation(markdown, hardBreaksNormalized, label);
  validateTranslationQuality(markdown, validated, file, label);
  return validated;
}

async function clearCachedSegments(keys, relativePath) {
  const results = await Promise.allSettled(
    keys.map((key) => deleteTranslationSegment(segmentCacheRoot, key)),
  );
  const failure = results.find((result) => result.status === "rejected");
  if (failure) console.warn(`  unable to clear segment cache for ${relativePath}: ${failure.reason?.message}`);
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
