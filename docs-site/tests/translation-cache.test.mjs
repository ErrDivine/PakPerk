import assert from "node:assert/strict";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createTranslationSegmentCacheKey,
  createTranslationSegmentCompatibilityKey,
  defaultTranslationCacheRoot,
  readValidatedTranslationSegment,
  revalidateCompatibleTranslationSegment,
  resolveTranslationCacheRoot,
  TRANSLATION_OPTIONS_VERSION,
  TRANSLATION_REQUEST_OPTIONS,
  TRANSLATION_SEGMENT_CACHE_VERSION,
  translationSegmentCachePath,
  writeTranslationSegment,
} from "../scripts/translation-cache.mjs";

const baseKeyInput = {
  segment: "# Account\n\nRequire authentication.\n",
  relativePath: "account-authentication.md",
  part: 1,
  total: 3,
  policyDigest: "a".repeat(64),
  model: "qwen3:8b",
  optionsVersion: TRANSLATION_OPTIONS_VERSION,
  requestOptions: TRANSLATION_REQUEST_OPTIONS,
};

test("segment cache keys cover source, location, policy, model, and translation options", () => {
  const original = createTranslationSegmentCacheKey(baseKeyInput);
  const compatible = createTranslationSegmentCompatibilityKey(baseKeyInput);
  const variants = [
    { ...baseKeyInput, segment: `${baseKeyInput.segment}\n` },
    { ...baseKeyInput, relativePath: "adr/0001-oidc-and-keycloak-reference.md" },
    { ...baseKeyInput, part: 2 },
    { ...baseKeyInput, total: 4 },
    { ...baseKeyInput, policyDigest: "b".repeat(64) },
    { ...baseKeyInput, model: "qwen3:14b" },
    { ...baseKeyInput, optionsVersion: `${TRANSLATION_OPTIONS_VERSION}-changed` },
    {
      ...baseKeyInput,
      requestOptions: { ...TRANSLATION_REQUEST_OPTIONS, initialTemperature: 0.2 },
    },
  ].map(createTranslationSegmentCacheKey);

  assert.match(original, /^[a-f0-9]{64}$/);
  assert.ok(variants.every((candidate) => candidate !== original));
  assert.equal(new Set(variants).size, variants.length);
  assert.equal(
    createTranslationSegmentCacheKey({
      ...baseKeyInput,
      requestOptions: Object.fromEntries(Object.entries(TRANSLATION_REQUEST_OPTIONS).reverse()),
    }),
    original,
  );
  assert.notEqual(
    createTranslationSegmentCacheKey({ ...baseKeyInput, policyDigest: "b".repeat(64) }),
    original,
  );
  assert.equal(
    createTranslationSegmentCompatibilityKey({ ...baseKeyInput, policyDigest: "b".repeat(64) }),
    compatible,
  );
});

test("default and configured cache roots remain narrowly resolved", () => {
  assert.equal(
    defaultTranslationCacheRoot(),
    path.join(tmpdir(), TRANSLATION_SEGMENT_CACHE_VERSION),
  );
  assert.equal(resolveTranslationCacheRoot("./custom-cache"), path.resolve("./custom-cache"));
});

test("cache reads revalidate accepted content", async () => {
  const cacheRoot = await mkdtemp(path.join(tmpdir(), "pakperk-segment-cache-test-"));
  try {
    await writeTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      translation: "# 账户\n\n需要身份认证。\n",
    });
    let validations = 0;
    const cached = await readValidatedTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      validate(candidate) {
        validations += 1;
        assert.match(candidate, /身份认证/u);
        return candidate;
      },
    });
    assert.equal(cached, "# 账户\n\n需要身份认证。\n");
    assert.equal(validations, 1);
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});

test("corrupt or validation-failing entries fall back as misses and are deleted", async () => {
  const cacheRoot = await mkdtemp(path.join(tmpdir(), "pakperk-segment-cache-test-"));
  const key = createTranslationSegmentCacheKey(baseKeyInput);
  const cachePath = translationSegmentCachePath(cacheRoot, key);
  try {
    await writeFile(cachePath, "not json\n", "utf8");
    assert.equal(await readValidatedTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      validate: (candidate) => candidate,
    }), null);
    await assert.rejects(access(cachePath), { code: "ENOENT" });

    await writeTranslationSegment({ cacheRoot, cacheInput: baseKeyInput, translation: "invalid translation" });
    assert.equal(await readValidatedTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      validate() {
        throw new Error("structure mismatch");
      },
    }), null);
    await assert.rejects(access(cachePath), { code: "ENOENT" });
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});

test("a policy-only change revalidates and atomically promotes a compatible candidate", async () => {
  const cacheRoot = await mkdtemp(path.join(tmpdir(), "pakperk-segment-cache-test-"));
  const currentInput = { ...baseKeyInput, policyDigest: "b".repeat(64) };
  const oldKey = createTranslationSegmentCacheKey(baseKeyInput);
  const currentKey = createTranslationSegmentCacheKey(currentInput);
  const oldPath = translationSegmentCachePath(cacheRoot, oldKey);
  const currentPath = translationSegmentCachePath(cacheRoot, currentKey);
  try {
    await writeTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      translation: "# 账户\n\n需要身份认证。\n",
    });
    assert.equal(await readValidatedTranslationSegment({
      cacheRoot,
      cacheInput: currentInput,
      validate: (candidate) => candidate,
    }), null);

    let validations = 0;
    const promoted = await revalidateCompatibleTranslationSegment({
      cacheRoot,
      cacheInput: currentInput,
      validate(candidate) {
        validations += 1;
        return candidate.replace("身份认证", "账户认证");
      },
    });
    assert.equal(promoted, "# 账户\n\n需要账户认证。\n");
    assert.equal(validations, 1);
    await access(currentPath);
    await assert.rejects(access(oldPath), { code: "ENOENT" });
    assert.equal(await readValidatedTranslationSegment({
      cacheRoot,
      cacheInput: currentInput,
      validate: (candidate) => candidate,
    }), promoted);
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});

test("a candidate forbidden by the current policy is rejected and deleted", async () => {
  const cacheRoot = await mkdtemp(path.join(tmpdir(), "pakperk-segment-cache-test-"));
  const currentInput = { ...baseKeyInput, policyDigest: "c".repeat(64) };
  const oldPath = translationSegmentCachePath(cacheRoot, createTranslationSegmentCacheKey(baseKeyInput));
  const currentPath = translationSegmentCachePath(cacheRoot, createTranslationSegmentCacheKey(currentInput));
  try {
    await writeTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      translation: "失败关闭。",
    });
    const promoted = await revalidateCompatibleTranslationSegment({
      cacheRoot,
      cacheInput: currentInput,
      validate() {
        throw new Error("newly forbidden translation");
      },
    });
    assert.equal(promoted, null);
    await assert.rejects(access(oldPath), { code: "ENOENT" });
    await assert.rejects(access(currentPath), { code: "ENOENT" });
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});

test("source, model, options, path, or position changes never reuse a candidate", async () => {
  const cacheRoot = await mkdtemp(path.join(tmpdir(), "pakperk-segment-cache-test-"));
  const oldPath = translationSegmentCachePath(cacheRoot, createTranslationSegmentCacheKey(baseKeyInput));
  const changedPolicy = "d".repeat(64);
  const incompatibleInputs = [
    { ...baseKeyInput, policyDigest: changedPolicy, segment: `${baseKeyInput.segment}\n` },
    { ...baseKeyInput, policyDigest: changedPolicy, model: "qwen3:14b" },
    {
      ...baseKeyInput,
      policyDigest: changedPolicy,
      requestOptions: { ...TRANSLATION_REQUEST_OPTIONS, initialTemperature: 0.2 },
    },
    { ...baseKeyInput, policyDigest: changedPolicy, optionsVersion: "changed-options" },
    { ...baseKeyInput, policyDigest: changedPolicy, relativePath: "adr/0001.md" },
    { ...baseKeyInput, policyDigest: changedPolicy, part: 2 },
    { ...baseKeyInput, policyDigest: changedPolicy, total: 4 },
  ];
  try {
    await writeTranslationSegment({
      cacheRoot,
      cacheInput: baseKeyInput,
      translation: "# 账户\n\n需要身份认证。\n",
    });
    let validations = 0;
    for (const cacheInput of incompatibleInputs) {
      assert.equal(await revalidateCompatibleTranslationSegment({
        cacheRoot,
        cacheInput,
        validate(candidate) {
          validations += 1;
          return candidate;
        },
      }), null);
    }
    assert.equal(validations, 0);
    await access(oldPath);
  } finally {
    await rm(cacheRoot, { recursive: true, force: true });
  }
});
