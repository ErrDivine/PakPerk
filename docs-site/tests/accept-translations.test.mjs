import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { acceptTranslations } from "../scripts/accept-translations.mjs";
import {
  TRANSLATION_POLICY_VERSION,
  translationPolicyDigest,
} from "../scripts/translation-policy.mjs";

const acceptedAt = "2026-09-01T12:34:56.000Z";

test("accepts validated translations with hashes, policy identity, provenance, and stable ordering", async () => {
  const fixture = await createFixture();
  try {
    const firstPath = "alpha.md";
    const secondPath = "nested/zeta.md";
    const firstSource = "# Guest access\n\nGuest access remains available.\n";
    const firstTranslation = "# 访客访问\n\n访客访问仍然可用。\n";
    const secondSource = "# API route\n\nValidate the route.\n";
    const secondTranslation = "# API 路由\n\n验证该路由。\n";
    await writePair(fixture, firstPath, firstSource, firstTranslation);
    await writePair(fixture, secondPath, secondSource, secondTranslation);
    await writeManifest(fixture, {
      "preserved.md": { custom: "untouched" },
      [firstPath]: {
        sourceSha256: "stale-source",
        translationSha256: "stale-translation",
        policyVersion: "old-policy",
        model: "qwen3:8b",
      },
      [secondPath]: {
        sourceSha256: sha256(secondSource),
        translationSha256: sha256(secondTranslation),
        policyVersion: "old-policy",
        model: "qwen3:8b",
      },
    });

    const accepted = await acceptTranslations([`docs/${secondPath}`, firstPath, firstPath], {
      repositoryRoot: fixture,
      acceptedAt,
    });

    assert.deepEqual(accepted, [secondPath, firstPath]);
    const manifestText = await readFile(manifestPath(fixture), "utf8");
    const manifest = JSON.parse(manifestText);
    assert.deepEqual(Object.keys(manifest), [firstPath, secondPath, "preserved.md"]);
    assert.equal(manifest["preserved.md"].custom, "untouched");
    assert.equal(manifest[secondPath].model, "qwen3:8b");
    assert.equal(manifest[firstPath].model, undefined);
    assert.deepEqual(Object.keys(manifest[secondPath]), [
      "sourceSha256",
      "translationSha256",
      "policyVersion",
      "policyDigest",
      "model",
      "acceptance",
    ]);
    assert.deepEqual(manifest[secondPath].acceptance, {
      method: "human-review",
      acceptedAt,
      workflow: "scripts/accept-translations.mjs",
    });
    for (const [relativePath, source, translation] of [
      [firstPath, firstSource, firstTranslation],
      [secondPath, secondSource, secondTranslation],
    ]) {
      assert.equal(manifest[relativePath].sourceSha256, sha256(source));
      assert.equal(manifest[relativePath].translationSha256, sha256(translation));
      assert.equal(manifest[relativePath].policyVersion, TRANSLATION_POLICY_VERSION);
      assert.equal(manifest[relativePath].policyDigest, translationPolicyDigest(relativePath));
    }
    assert.equal(manifestText, `${JSON.stringify(manifest, null, 2)}\n`);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects a mixed batch before changing an existing manifest", async () => {
  const fixture = await createFixture();
  try {
    await writePair(
      fixture,
      "valid.md",
      "# Guest access\n\nGuest access remains available.\n",
      "# 访客访问\n\n访客访问仍然可用。\n",
    );
    await writePair(
      fixture,
      "invalid.md",
      "# API route\n\nValidate the route.\n",
      "# API 路由\n\n这是错误的翻译。\n",
    );
    const originalManifest = '{\n  "preserved.md": {\n    "custom": "untouched"\n  }\n}\n';
    await mkdir(path.dirname(manifestPath(fixture)), { recursive: true });
    await writeFile(manifestPath(fixture), originalManifest, "utf8");

    await assert.rejects(
      acceptTranslations(["valid.md", "invalid.md"], {
        repositoryRoot: fixture,
        acceptedAt,
      }),
      /invalid\.md: translation validation failed/,
    );
    assert.equal(await readFile(manifestPath(fixture), "utf8"), originalManifest);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects missing pairs and paths outside the documentation roots without creating a manifest", async () => {
  const fixture = await createFixture();
  try {
    await Promise.all([
      mkdir(path.join(fixture, "docs"), { recursive: true }),
      mkdir(path.join(fixture, "docs-site", "content", "zh"), { recursive: true }),
    ]);
    await writeFile(path.join(fixture, "docs", "missing-translation.md"), "# Missing\n", "utf8");
    await writeFile(
      path.join(fixture, "docs-site", "content", "zh", "missing-source.md"),
      "# 缺失\n",
      "utf8",
    );

    await assert.rejects(
      acceptTranslations(["missing-translation.md"], {
        repositoryRoot: fixture,
        acceptedAt,
      }),
      /missing Chinese translation/,
    );
    await assert.rejects(
      acceptTranslations(["missing-source.md"], { repositoryRoot: fixture, acceptedAt }),
      /missing English source/,
    );
    await assert.rejects(
      acceptTranslations(["../outside.md"], {
        repositoryRoot: fixture,
        acceptedAt,
      }),
      /must name a Markdown file inside docs/,
    );
    for (const invalidPath of ["UPPER.MD", "C:drive-relative.md"]) {
      await assert.rejects(
        acceptTranslations([invalidPath], { repositoryRoot: fixture, acceptedAt }),
        /Translation path must/,
      );
    }
    await assert.rejects(
      acceptTranslations([], { repositoryRoot: fixture, acceptedAt }),
      /Provide at least one Markdown path/,
    );
    await assert.rejects(readFile(manifestPath(fixture), "utf8"), { code: "ENOENT" });
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects symlink escapes and a malformed manifest without overwriting it", async () => {
  const fixture = await createFixture();
  try {
    const source = "# Guest access\n\nGuest access remains available.\n";
    const translation = "# 访客访问\n\n访客访问仍然可用。\n";
    await writePair(fixture, "valid.md", source, translation);

    const malformedManifest = "[]\n";
    await writeFile(manifestPath(fixture), malformedManifest, "utf8");
    await assert.rejects(
      acceptTranslations(["valid.md"], { repositoryRoot: fixture, acceptedAt }),
      /Translation manifest must contain a JSON object/,
    );
    assert.equal(await readFile(manifestPath(fixture), "utf8"), malformedManifest);

    await writeFile(path.join(fixture, "outside.md"), source, "utf8");
    await symlink("../outside.md", path.join(fixture, "docs", "escape.md"));
    await writeFile(
      path.join(fixture, "docs-site", "content", "zh", "escape.md"),
      translation,
      "utf8",
    );
    await assert.rejects(
      acceptTranslations(["escape.md"], { repositoryRoot: fixture, acceptedAt }),
      /English source resolves outside its documentation root/,
    );
    assert.equal(await readFile(manifestPath(fixture), "utf8"), malformedManifest);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

async function createFixture() {
  return mkdtemp(path.join(tmpdir(), "pakperk-accept-translations-test-"));
}

async function writePair(root, relativePath, source, translation) {
  const sourcePath = path.join(root, "docs", relativePath);
  const translationPath = path.join(root, "docs-site", "content", "zh", relativePath);
  await Promise.all([
    mkdir(path.dirname(sourcePath), { recursive: true }),
    mkdir(path.dirname(translationPath), { recursive: true }),
  ]);
  await Promise.all([
    writeFile(sourcePath, source, "utf8"),
    writeFile(translationPath, translation, "utf8"),
  ]);
}

async function writeManifest(root, manifest) {
  const file = manifestPath(root);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

function manifestPath(root) {
  return path.join(root, "docs-site", "content", "zh", ".source-digests.json");
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
