import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { TRANSLATION_POLICY_VERSION, translationPolicyDigest } from "./translation-policy.mjs";
import { validateTranslationQuality } from "./translation-quality.mjs";
import { validateTranslationStructure } from "./translation-structure.mjs";

const root = path.resolve(import.meta.dirname, "../..");
const docsSiteRoot = path.join(root, "docs-site");
const sourceRoot = path.join(root, "docs");
const translatedRoot = path.join(docsSiteRoot, "content", "zh");
const translationManifestPath = path.join(translatedRoot, ".source-digests.json");
const generatedPath = path.join(docsSiteRoot, "app", "generated", "docs.ts");
const defaultDocumentPath = path.join(docsSiteRoot, "app", "generated", "default-doc.ts");
const publicDataRoot = path.join(docsSiteRoot, "public", "docs-data");
const workRoot = path.join(docsSiteRoot, "work");
const checkOnly = process.argv.includes("--check");

const categoryLabels = {
  guides: { en: "Guides", zh: "指南" },
  product: { en: "Product & API", zh: "产品与 API" },
  architecture: { en: "Architecture", zh: "架构决策" },
  operations: { en: "Operations", zh: "运维手册" },
  delivery: { en: "Delivery evidence", zh: "交付记录" },
  policy: { en: "Policy & store", zh: "政策与商店" },
};

const files = (await walk(sourceRoot))
  .filter((file) => file.endsWith(".md") || file.endsWith(".json"))
  .sort((a, b) => orderFor(a) - orderFor(b) || comparePaths(a, b));
const publishedPaths = new Set(
  files.map((file) => path.relative(sourceRoot, file).split(path.sep).join("/")),
);
const translationManifest = await readJson(translationManifestPath, {});

const docs = [];
const contents = [];
let currentTranslationCount = 0;
await mkdir(workRoot, { recursive: true });
const stagingRoot = await mkdtemp(path.join(workRoot, "docs-generation-"));
const stagedDataRoot = path.join(stagingRoot, "docs-data");
const stagedGeneratedPath = path.join(stagingRoot, "docs.ts");
const stagedDefaultDocumentPath = path.join(stagingRoot, "default-doc.ts");

try {
  await mkdir(stagedDataRoot, { recursive: true });
  for (const sourcePath of files) {
    const relativePath = path.relative(sourceRoot, sourcePath).split(path.sep).join("/");
    const id = relativePath.replace(/\.(?:md|json)$/i, "").replaceAll("/", "--");
    const isJson = sourcePath.endsWith(".json");
    const source = await readFile(sourcePath, "utf8");
    const sourceSha256 = sha256(source);
    const translatedPath = path.join(translatedRoot, relativePath);
    const translatedDraft = isJson ? null : await readFile(translatedPath, "utf8").catch(() => null);
    const translationRecord = translationManifest[relativePath];
    const policyDigest = isJson ? null : translationPolicyDigest(relativePath);
    const translationMatchesSource =
      translatedDraft !== null &&
      translationRecord?.sourceSha256 === sourceSha256 &&
      translationRecord?.translationSha256 === sha256(translatedDraft) &&
      translationRecord?.policyVersion === TRANSLATION_POLICY_VERSION &&
      translationRecord?.policyDigest === policyDigest;
    let translationStatus;
    if (isJson) translationStatus = "source";
    else if (translatedDraft === null) translationStatus = "missing";
    else if (translationRecord === undefined) translationStatus = "unverified";
    else if (!translationMatchesSource) translationStatus = "stale";
    else {
      try {
        validateTranslationStructure(source, translatedDraft, relativePath);
        validateTranslationQuality(source, translatedDraft, relativePath, relativePath);
        translationStatus = "translated";
      } catch (error) {
        translationStatus = "invalid";
        console.warn(`Ignoring structurally invalid translation for ${relativePath}: ${error.message}`);
      }
    }
    let translated = translationStatus === "translated" ? translatedDraft : source;
    const html = isJson ? renderJson(source) : renderMarkdown(source, relativePath);
    let htmlZh = html;
    if (translationStatus === "translated") {
      try {
        htmlZh = alignHeadingIds(html, renderMarkdown(translated, relativePath));
        currentTranslationCount += 1;
      } catch (error) {
        translationStatus = "invalid";
        translated = source;
        console.warn(`Ignoring unrenderable translation for ${relativePath}: ${error.message}`);
      }
    }
    const title = isJson ? "OpenAPI v1 contract" : extractTitle(source, relativePath);
    const titleZh = isJson ? "OpenAPI v1 接口契约" : extractTitle(translated, relativePath);
    const summary = isJson
      ? "The generated machine-readable contract for the Pakperk v1 HTTP API."
      : extractSummary(source);
    const summaryZh = isJson
      ? "Pakperk v1 HTTP API 的机器可读生成契约。"
      : extractSummary(translated);
    const category = categoryFor(relativePath);

    docs.push({
      id,
      path: relativePath,
      sourceSha256,
      translationStatus,
      category,
      categoryLabel: categoryLabels[category],
      title,
      titleZh,
      summary,
      summaryZh,
      dataUrl: `/docs-data/${id}.json`,
      wordCount: source.trim().split(/\s+/).length,
      readingMinutes: Math.max(1, Math.ceil(source.trim().split(/\s+/).length / 230)),
      toc: extractToc(html),
      tocZh: extractToc(htmlZh),
    });
    const content = { id, html, htmlZh };
    contents.push(content);
    await writeFile(path.join(stagedDataRoot, `${id}.json`), JSON.stringify(content), "utf8");
  }

  await writeFile(
    stagedGeneratedPath,
    `// Generated by scripts/generate-docs.mjs. Do not edit by hand.\n` +
      `export const docs = ${JSON.stringify(docs)} as const;\n`,
    "utf8",
  );
  const defaultDocument = contents.find((document) => document.id === "developer-guide") || contents[0];
  await writeFile(
    stagedDefaultDocumentPath,
    `// Generated by scripts/generate-docs.mjs. Do not edit by hand.\n` +
      `export const defaultDocument = ${JSON.stringify(defaultDocument)} as const;\n`,
    "utf8",
  );

  const outputs = [
    { source: stagedDataRoot, target: publicDataRoot, directory: true, label: "public/docs-data" },
    { source: stagedGeneratedPath, target: generatedPath, directory: false, label: "app/generated/docs.ts" },
    { source: stagedDefaultDocumentPath, target: defaultDocumentPath, directory: false, label: "app/generated/default-doc.ts" },
  ];
  if (checkOnly) await assertOutputsCurrent(outputs);
  else await replaceOutputs(outputs, stagingRoot);

  const action = checkOnly ? "Checked" : "Generated";
  console.log(
    `${action} ${docs.length} documents (${currentTranslationCount} current Chinese translations) at ${generatedPath}`,
  );
} finally {
  await rm(stagingRoot, { recursive: true, force: true });
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

function renderMarkdown(markdown, relativePath) {
  const body = markdown.replace(/^\uFEFF?#\s+[^\r\n]+\r?\n(?:\r?\n)?/, "");
  const rendered = execFileSync(
    "pandoc",
    ["--from=gfm", "--to=html5", "--wrap=none"],
    { input: body, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
  );
  return rewriteLinks(rendered, relativePath);
}

function alignHeadingIds(sourceHtml, translatedHtml) {
  const sourceHeadings = [...sourceHtml.matchAll(/<h([2-6]) id="([^"]+)">/g)].map((match) => ({
    level: match[1],
    id: match[2],
  }));
  const translatedHeadings = [...translatedHtml.matchAll(/<h([2-6]) id="([^"]+)">/g)].map((match) => ({
    level: match[1],
    id: match[2],
  }));
  if (
    sourceHeadings.length !== translatedHeadings.length ||
    sourceHeadings.some((heading, index) => heading.level !== translatedHeadings[index]?.level)
  ) {
    throw new Error("Rendered translation heading structure differs from the English source");
  }
  let index = 0;
  return translatedHtml.replace(/<h([2-6]) id="[^"]+">/g, (heading) => {
    const sourceHeading = sourceHeadings[index++];
    return heading.replace(/id="[^"]+"/, `id="${sourceHeading.id}"`);
  });
}

function renderJson(source) {
  return `<pre><code class="language-json">${escapeHtml(source)}</code></pre>`;
}

function rewriteLinks(html, relativePath) {
  return html.replace(/href="([^"]+)"/g, (match, href) => {
    if (/^(?:[a-z]+:|#|\/)/i.test(href)) return match;
    const [target, anchor = ""] = href.split("#", 2);
    const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(relativePath), target));
    if (publishedPaths.has(resolved)) {
      const id = resolved.replace(/\.(?:md|json)$/i, "").replaceAll("/", "--");
      return `href="/?doc=${encodeURIComponent(id)}${anchor ? `&section=${encodeURIComponent(anchor)}` : ""}" data-doc-link="${id}"${anchor ? ` data-doc-section="${escapeHtml(anchor)}"` : ""}`;
    }
    if (resolved.startsWith("../")) {
      const repositoryPath = resolved.replace(/^(?:\.\.\/)+/, "");
      const view = target.endsWith("/") ? "tree" : "blob";
      return `href="https://github.com/ErrDivine/PakPerk/${view}/main/${escapeHtml(repositoryPath)}${anchor ? `#${escapeHtml(anchor)}` : ""}" target="_blank" rel="noreferrer"`;
    }
    if (target.endsWith("/") || /\.[a-z0-9]+$/i.test(target)) {
      const view = target.endsWith("/") ? "tree" : "blob";
      return `href="https://github.com/ErrDivine/PakPerk/${view}/main/docs/${escapeHtml(resolved)}${anchor ? `#${escapeHtml(anchor)}` : ""}" target="_blank" rel="noreferrer"`;
    }
    return match;
  });
}

function extractTitle(source, relativePath) {
  return source.match(/^#\s+(.+)$/m)?.[1]?.replace(/[`*_]/g, "") || humanize(relativePath);
}

function extractSummary(source) {
  const paragraph = source
    .split(/\n\s*\n/)
    .map((part) => part.trim())
    .find((part) => part && !/^(?:#|```|[-*+]\s|\d+\.\s|\|)/.test(part));
  const clean = stripMarkdown(paragraph || "").replace(/\s+/g, " ").trim();
  return clean.length > 220 ? `${clean.slice(0, 217).trimEnd()}…` : clean;
}

function stripMarkdown(source) {
  return source
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*(?:[-*+]|\d+\.)\s+/gm, "")
    .replace(/[>*_|]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function extractToc(html) {
  return [...html.matchAll(/<h([23]) id="([^"]+)">([\s\S]*?)<\/h\1>/g)].map((match) => ({
    level: Number(match[1]),
    id: match[2],
    label: match[3].replace(/<[^>]+>/g, "").replaceAll("&amp;", "&"),
  }));
}

function categoryFor(relativePath) {
  if (/^(?:user-guide|developer-guide|mobile-device-development|backend-deployment|mobile-app-links)\.md$/.test(relativePath)) return "guides";
  if (relativePath.startsWith("adr/") || relativePath === "architecture.md") return "architecture";
  if (relativePath.startsWith("runbooks/")) return "operations";
  if (relativePath.startsWith("phase-reports/") || /(?:completion-audit|production-v0\.0-plan|mobile-release)/.test(relativePath)) return "delivery";
  if (relativePath.startsWith("legal/") || relativePath.startsWith("store/") || relativePath === "content-policy.md") return "policy";
  return "product";
}

function orderFor(file) {
  const relativePath = path.relative(sourceRoot, file).split(path.sep).join("/");
  const category = categoryFor(relativePath);
  const categoryOrder = ["guides", "product", "architecture", "operations", "delivery", "policy"];
  const featured = [
    "developer-guide.md",
    "mobile-device-development.md",
    "backend-deployment.md",
    "user-guide.md",
    "mobile-app-links.md",
    "architecture.md",
    "openapi-v1.json",
  ];
  const featuredIndex = featured.indexOf(relativePath);
  return categoryOrder.indexOf(category) * 1_000 + (featuredIndex >= 0 ? featuredIndex : 100);
}

function humanize(value) {
  return value
    .replace(/\.(?:md|json)$/i, "")
    .split("/")
    .at(-1)
    .replaceAll("-", " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function escapeHtml(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return fallback;
    throw error;
  }
}

async function assertOutputsCurrent(outputs) {
  const mismatches = [];
  for (const output of outputs) {
    if (output.directory) {
      mismatches.push(...(await compareDirectories(output.source, output.target, output.label)));
    } else if (!(await filesMatch(output.source, output.target))) {
      mismatches.push(output.label);
    }
  }
  if (!mismatches.length) return;
  const details = mismatches.slice(0, 20).map((item) => `- ${item}`).join("\n");
  const remainder = mismatches.length > 20 ? `\n- ...and ${mismatches.length - 20} more` : "";
  throw new Error(
    `Generated documentation is out of date:\n${details}${remainder}\n` +
      "Run `npm run sync-docs`, review the generated diff, and commit it.",
  );
}

async function compareDirectories(expectedRoot, actualRoot, label) {
  const expectedFiles = (await walk(expectedRoot))
    .map((file) => path.relative(expectedRoot, file).split(path.sep).join("/"))
    .sort(comparePaths);
  let actualFiles;
  try {
    actualFiles = (await walk(actualRoot))
      .map((file) => path.relative(actualRoot, file).split(path.sep).join("/"))
      .sort(comparePaths);
  } catch (error) {
    if (error?.code === "ENOENT") return [`${label} is missing`];
    throw error;
  }
  const mismatches = [];
  const allFiles = [...new Set([...expectedFiles, ...actualFiles])].sort(comparePaths);
  for (const relativePath of allFiles) {
    if (!expectedFiles.includes(relativePath)) {
      mismatches.push(`${label}/${relativePath} is orphaned`);
    } else if (!actualFiles.includes(relativePath)) {
      mismatches.push(`${label}/${relativePath} is missing`);
    } else if (!await filesMatch(
      path.join(expectedRoot, relativePath),
      path.join(actualRoot, relativePath),
    )) {
      mismatches.push(`${label}/${relativePath}`);
    }
  }
  return mismatches;
}

async function filesMatch(expectedPath, actualPath) {
  try {
    const [expected, actual] = await Promise.all([readFile(expectedPath), readFile(actualPath)]);
    return expected.equals(actual);
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function replaceOutputs(outputs, temporaryRoot) {
  const completed = [];
  try {
    for (const [index, output] of outputs.entries()) {
      const backup = path.join(temporaryRoot, `previous-${index}`);
      let hadPrevious = true;
      try {
        await rename(output.target, backup);
      } catch (error) {
        if (error?.code === "ENOENT") hadPrevious = false;
        else throw error;
      }
      try {
        await rename(output.source, output.target);
      } catch (error) {
        if (hadPrevious) await rename(backup, output.target);
        throw error;
      }
      completed.push({ ...output, backup, hadPrevious });
    }
  } catch (error) {
    for (const output of completed.reverse()) {
      await rm(output.target, { recursive: output.directory, force: true });
      if (output.hadPrevious) await rename(output.backup, output.target);
    }
    throw error;
  }
  for (const output of completed) {
    if (output.hadPrevious) {
      await rm(output.backup, { recursive: output.directory, force: true });
    }
  }
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
