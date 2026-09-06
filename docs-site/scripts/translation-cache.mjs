import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

export const TRANSLATION_SEGMENT_CACHE_VERSION = "pakperk-docs-segment-cache-v1";
export const TRANSLATION_OPTIONS_VERSION = "ollama-qwen-markdown-v2-exact-literals";
export const TRANSLATION_REQUEST_OPTIONS = Object.freeze({
  attempts: 3,
  initialTemperature: 0.1,
  retryTemperature: 0,
  numContextTokens: 8_192,
  think: false,
  stream: false,
  keepAlive: "15m",
});

export function defaultTranslationCacheRoot() {
  return path.join(tmpdir(), TRANSLATION_SEGMENT_CACHE_VERSION);
}

export function resolveTranslationCacheRoot(configuredPath) {
  return configuredPath ? path.resolve(configuredPath) : defaultTranslationCacheRoot();
}

export function createTranslationSegmentCacheKey(cacheInput) {
  const identity = normalizedCacheIdentity(cacheInput);
  return digestFields([
    TRANSLATION_SEGMENT_CACHE_VERSION,
    identity.relativePath,
    identity.part,
    identity.total,
    identity.policyDigest,
    identity.model,
    identity.optionsVersion,
    stableJson(identity.requestOptions),
    identity.segment,
  ]);
}

export function createTranslationSegmentCompatibilityKey(cacheInput) {
  const identity = normalizedCacheIdentity(cacheInput);
  return digestFields([
    TRANSLATION_SEGMENT_CACHE_VERSION,
    identity.relativePath,
    identity.part,
    identity.total,
    identity.model,
    identity.optionsVersion,
    stableJson(identity.requestOptions),
    identity.segment,
  ]);
}

export function translationSegmentCachePath(cacheRoot, key) {
  if (!/^[a-f0-9]{64}$/.test(key)) throw new Error("translation cache key must be a SHA-256 digest");
  return path.join(cacheRoot, `${key}.json`);
}

export async function readValidatedTranslationSegment({ cacheRoot, cacheInput, validate }) {
  const key = createTranslationSegmentCacheKey(cacheInput);
  const cachePath = translationSegmentCachePath(cacheRoot, key);
  try {
    const record = JSON.parse(await readFile(cachePath, "utf8"));
    validatePrimaryRecord(record, cacheInput, key);
    const validated = await validate(record.translation);
    if (typeof validated !== "string") throw new Error("translation cache validator must return a string");
    return validated;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    await rm(cachePath, { force: true }).catch(() => undefined);
    return null;
  }
}

export async function revalidateCompatibleTranslationSegment({ cacheRoot, cacheInput, validate }) {
  const currentIdentity = normalizedCacheIdentity(cacheInput);
  const currentKey = createTranslationSegmentCacheKey(currentIdentity);
  const compatibilityKey = createTranslationSegmentCompatibilityKey(currentIdentity);
  let entries;
  try {
    entries = await readdir(cacheRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }

  const candidateNames = entries
    .filter((entry) => entry.isFile() && /^[a-f0-9]{64}\.json$/.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  for (const candidateName of candidateNames) {
    const candidateKey = candidateName.slice(0, -".json".length);
    if (candidateKey === currentKey) continue;
    const candidatePath = path.join(cacheRoot, candidateName);
    let record;
    try {
      record = JSON.parse(await readFile(candidatePath, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") await rm(candidatePath, { force: true }).catch(() => undefined);
      continue;
    }

    if (!compatibleRecordShape(record) || record.compatibilityKey !== compatibilityKey) continue;
    if (!compatibleIdentityMatches(record.identity, currentIdentity, candidateKey, compatibilityKey)) {
      await rm(candidatePath, { force: true }).catch(() => undefined);
      continue;
    }

    let validated;
    try {
      validated = await validate(record.translation);
      if (typeof validated !== "string") throw new Error("translation cache validator must return a string");
    } catch {
      await rm(candidatePath, { force: true }).catch(() => undefined);
      continue;
    }

    await writeTranslationSegment({ cacheRoot, cacheInput: currentIdentity, translation: validated });
    await rm(candidatePath, { force: true }).catch(() => undefined);
    return validated;
  }
  return null;
}

export async function writeTranslationSegment({ cacheRoot, cacheInput, translation }) {
  if (typeof translation !== "string") throw new TypeError("cached translation must be a string");
  const identity = normalizedCacheIdentity(cacheInput);
  const key = createTranslationSegmentCacheKey(identity);
  const compatibilityKey = createTranslationSegmentCompatibilityKey(identity);
  const cachePath = translationSegmentCachePath(cacheRoot, key);
  await mkdir(cacheRoot, { recursive: true });
  const temporaryPath = `${cachePath}.${process.pid}.${randomUUID()}.tmp`;
  const record = {
    version: TRANSLATION_SEGMENT_CACHE_VERSION,
    key,
    compatibilityKey,
    identity,
    translation,
  };
  try {
    await writeFile(temporaryPath, `${JSON.stringify(record)}\n`, "utf8");
    await rename(temporaryPath, cachePath);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

export async function deleteTranslationSegment(cacheRoot, key) {
  await rm(translationSegmentCachePath(cacheRoot, key), { force: true });
}

function validatePrimaryRecord(record, cacheInput, key) {
  if (
    record?.version !== TRANSLATION_SEGMENT_CACHE_VERSION ||
    record?.key !== key ||
    typeof record?.translation !== "string"
  ) {
    throw new Error("translation cache record has an invalid shape");
  }
  // Records written before compatible reuse was introduced remain safe for
  // their exact policy-bound primary key, but can never be discovered across policies.
  if (record.identity === undefined && record.compatibilityKey === undefined) return;
  const identity = normalizedCacheIdentity(cacheInput);
  if (
    !compatibleRecordShape(record) ||
    stableJson(record.identity) !== stableJson(identity) ||
    record.compatibilityKey !== createTranslationSegmentCompatibilityKey(identity)
  ) {
    throw new Error("translation cache record identity does not match its primary key");
  }
}

function compatibleRecordShape(record) {
  return record?.version === TRANSLATION_SEGMENT_CACHE_VERSION &&
    typeof record?.key === "string" &&
    typeof record?.compatibilityKey === "string" &&
    record?.identity && typeof record.identity === "object" &&
    typeof record?.translation === "string";
}

function compatibleIdentityMatches(recordIdentity, currentIdentity, candidateKey, compatibilityKey) {
  let normalizedRecord;
  try {
    normalizedRecord = normalizedCacheIdentity(recordIdentity);
  } catch {
    return false;
  }
  return candidateKey === createTranslationSegmentCacheKey(normalizedRecord) &&
    compatibilityKey === createTranslationSegmentCompatibilityKey(normalizedRecord) &&
    stableJson(withoutPolicyDigest(normalizedRecord)) === stableJson(withoutPolicyDigest(currentIdentity));
}

function normalizedCacheIdentity(cacheInput) {
  const identity = {
    segment: cacheInput?.segment,
    relativePath: cacheInput?.relativePath,
    part: cacheInput?.part,
    total: cacheInput?.total,
    policyDigest: cacheInput?.policyDigest,
    model: cacheInput?.model,
    optionsVersion: cacheInput?.optionsVersion ?? TRANSLATION_OPTIONS_VERSION,
    requestOptions: JSON.parse(stableJson(cacheInput?.requestOptions ?? TRANSLATION_REQUEST_OPTIONS)),
  };
  for (const field of ["segment", "relativePath", "policyDigest", "model", "optionsVersion"]) {
    if (typeof identity[field] !== "string") throw new TypeError(`translation cache ${field} must be a string`);
  }
  if (!Number.isInteger(identity.part) || identity.part < 1) {
    throw new TypeError("translation cache part must be a positive integer");
  }
  if (!Number.isInteger(identity.total) || identity.total < identity.part) {
    throw new TypeError("translation cache total must be an integer no smaller than part");
  }
  return identity;
}

function withoutPolicyDigest(identity) {
  return {
    segment: identity.segment,
    relativePath: identity.relativePath,
    part: identity.part,
    total: identity.total,
    model: identity.model,
    optionsVersion: identity.optionsVersion,
    requestOptions: identity.requestOptions,
  };
}

function digestFields(values) {
  const digest = createHash("sha256");
  for (const value of values) {
    const text = String(value);
    digest.update(String(Buffer.byteLength(text, "utf8")));
    digest.update(":");
    digest.update(text, "utf8");
    digest.update("\0");
  }
  return digest.digest("hex");
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(",")}}`;
  }
  const serialized = JSON.stringify(value);
  if (serialized === undefined) throw new TypeError("translation cache options must be JSON-serializable");
  return serialized;
}
