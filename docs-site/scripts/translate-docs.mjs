import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "../..");
const sourceRoot = path.join(root, "docs");
const outputRoot = path.join(root, "docs-site", "content", "zh");
const model = process.env.PAKPERK_TRANSLATION_MODEL || "qwen3:8b";
const force = process.argv.includes("--force");

const files = (await walk(sourceRoot))
  .filter((file) => file.endsWith(".md"))
  .sort((a, b) => a.localeCompare(b));

for (const [index, sourcePath] of files.entries()) {
  const relativePath = path.relative(sourceRoot, sourcePath);
  const outputPath = path.join(outputRoot, relativePath);
  if (!force && (await isCurrent(sourcePath, outputPath))) {
    console.log(`[${index + 1}/${files.length}] current ${relativePath}`);
    continue;
  }

  const source = await readFile(sourcePath, "utf8");
  const segments = splitMarkdown(source);
  const translated = [];
  console.log(`[${index + 1}/${files.length}] translating ${relativePath} (${segments.length} segments)`);

  for (const [segmentIndex, segment] of segments.entries()) {
    let response;
    try {
      response = await translate(segment, relativePath, segmentIndex + 1, segments.length);
    } catch (error) {
      if (!String(error.message).includes("code block")) throw error;
      console.log(`  preserving code blocks separately for ${relativePath} part ${segmentIndex + 1}`);
      response = await translateAroundCode(segment, relativePath, segmentIndex + 1, segments.length);
    }
    const trailingSpace = segment.match(/\s*$/)?.[0] || "";
    translated.push(`${restoreTechnicalText(segment, response.trimEnd())}${trailingSpace}`);
  }

  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${translated.join("").trimEnd()}\n`, "utf8");
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

async function isCurrent(sourcePath, outputPath) {
  try {
    const [sourceInfo, outputInfo] = await Promise.all([stat(sourcePath), stat(outputPath)]);
    return outputInfo.mtimeMs >= sourceInfo.mtimeMs;
  } catch {
    return false;
  }
}

function splitMarkdown(source) {
  const paragraphs = [];
  let paragraph = "";
  let inFence = false;
  for (const line of source.match(/.*(?:\n|$)/g) || []) {
    if (!line) continue;
    paragraph += line;
    if (/^```/.test(line)) inFence = !inFence;
    if (!inFence && /^\s*$/.test(line)) {
      paragraphs.push(paragraph);
      paragraph = "";
    }
  }
  if (paragraph) paragraphs.push(paragraph);

  const segments = [];
  let buffer = "";
  for (const block of paragraphs) {
    if (buffer && buffer.length + block.length > 11_000) {
      segments.push(buffer);
      buffer = "";
    }
    buffer += block;
  }
  if (buffer) segments.push(buffer);
  return segments;
}

function restoreTechnicalText(source, translation) {
  let output = translation;
  output = restoreMatches(output, /```[\s\S]*?```/g, source.match(/```[\s\S]*?```/g) || [], "code block");

  const sourceTargets = outsideCode(source).match(/(?<=\]\()[^)\s]+(?=\))/g) || [];
  const outputOutsideCode = outsideCode(output);
  const outputTargets = outputOutsideCode.match(/(?<=\]\()[^)\s]+(?=\))/g) || [];
  if (sourceTargets.length !== outputTargets.length) {
    throw new Error(`Translation changed the number of Markdown link targets (${sourceTargets.length} → ${outputTargets.length})`);
  }
  for (const [index, target] of outputTargets.entries()) output = output.replace(target, sourceTargets[index]);
  return output;
}

function restoreMatches(output, pattern, originals, label) {
  const matches = output.match(pattern) || [];
  if (matches.length !== originals.length) {
    throw new Error(`Translation changed the number of ${label}s (${originals.length} → ${matches.length})`);
  }
  let restored = output;
  for (const [index, match] of matches.entries()) restored = restored.replace(match, originals[index]);
  return restored;
}

function outsideCode(source) {
  return source.replace(/```[\s\S]*?```/g, "");
}

async function translate(markdown, file, part, total) {
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const response = await fetch("http://127.0.0.1:11434/api/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model,
        stream: false,
        think: false,
        options: { temperature: attempt === 1 ? 0.1 : 0, num_ctx: 8_192 },
        messages: [
          {
            role: "system",
            content:
              "Translate the supplied software documentation from English to Simplified Chinese. " +
              "Preserve every Markdown marker, heading level, list number, table, link destination, inline-code span, and fenced code block. " +
              "Never translate or change text inside backticks or fenced code blocks. " +
              "Keep Pakperk, arXiv, Rust, Flutter, API, OIDC, Keycloak, PostgreSQL, Kubernetes, Helm, and OpenTelemetry in English. " +
              "Do not summarize, omit, add commentary, or wrap the result in another code fence. Return only the translated Markdown.",
          },
          { role: "user", content: markdown },
        ],
      }),
    });

    if (!response.ok) {
      if (attempt === 3) throw new Error(`Ollama returned ${response.status}: ${await response.text()}`);
      continue;
    }
    const payload = await response.json();
    const content = payload?.message?.content;
    if (!content) {
      if (attempt === 3) throw new Error("Ollama returned no translated content");
      continue;
    }
    try {
      restoreTechnicalText(markdown, content);
      return content;
    } catch (error) {
      if (attempt === 3) throw new Error(`${file} part ${part}/${total}: ${error.message}`);
    }
  }
  throw new Error(`${file} part ${part}/${total}: translation failed`);
}

async function translateAroundCode(markdown, file, part, total) {
  const pieces = markdown.split(/(```[\s\S]*?```)/g);
  const translated = [];
  for (const piece of pieces) {
    if (!piece) continue;
    if (piece.startsWith("```")) {
      translated.push(piece);
      continue;
    }
    if (!piece.trim()) {
      translated.push(piece);
      continue;
    }
    const trailingSpace = piece.match(/\s*$/)?.[0] || "";
    const response = await translate(piece, file, part, total);
    translated.push(`${restoreTechnicalText(piece, response.trimEnd())}${trailingSpace}`);
  }
  return translated.join("");
}
