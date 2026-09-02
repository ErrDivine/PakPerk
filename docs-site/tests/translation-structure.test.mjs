import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  MODEL_PROTECTED_LITERALS,
  modelProtectedLiteralsFor,
} from "../scripts/translation-policy.mjs";
import {
  protectMarkdownForTranslation,
  normalizeSurplusMarkdownHardBreaks,
  removeAddedMarkdownLinks,
  restoreAndValidateTranslation,
  splitMarkdown,
  validateTranslationStructure,
} from "../scripts/translation-structure.mjs";

const source = await readFile(new URL("fixtures/translation-source.md", import.meta.url), "utf8");
const validTranslation = await readFile(new URL("fixtures/translation-valid.md", import.meta.url), "utf8");

test("accepts a translation with matching Markdown and technical structure", () => {
  assert.doesNotThrow(() => validateTranslationStructure(source, validTranslation, "fixture"));
});

test("restores protected code and link targets before validation", () => {
  const candidate = validTranslation
    .replace("`PAKPERK_API_BASE_URL`", "`已翻译`")
    .replace("../mobile-device-development.md#android-phone-usb-loop", "../错误路径.md")
    .replace("curl --fail http://localhost:8080/health/ready", "curl --fail http://wrong.invalid");
  const restored = restoreAndValidateTranslation(source, candidate, "fixture");

  assert.match(restored, /`PAKPERK_API_BASE_URL`/);
  assert.match(restored, /\.\.\/mobile-device-development\.md#android-phone-usb-loop/);
  assert.match(restored, /curl --fail http:\/\/localhost:8080\/health\/ready/);
});

test("masks inline code and link destinations before model inference", () => {
  const protectedMarkdown = protectMarkdownForTranslation(source, "fixture");

  assert.doesNotMatch(protectedMarkdown.masked, /keep `PAKPERK_API_BASE_URL`/);
  assert.doesNotMatch(protectedMarkdown.masked, /curl --fail/);
  assert.doesNotMatch(protectedMarkdown.masked, /mobile-device-development/);
  assert.doesNotMatch(protectedMarkdown.masked, /1\.2/);
  assert.match(protectedMarkdown.masked, /\{\{PAKPERK_PROTECTED_0001_NUMBER_1_2\}\}/);

  const restored = protectedMarkdown.restore(protectedMarkdown.masked.replace("Connect", "连接"));
  assert.match(restored, /`PAKPERK_API_BASE_URL`/);
  assert.match(restored, /\.\.\/mobile-device-development\.md#android-phone-usb-loop/);
  const firstToken = protectedMarkdown.masked.match(/`\{\{PAKPERK_PROTECTED_0001_[^}]+\}\}`/)?.[0];
  assert.ok(firstToken);
  assert.throws(() => protectedMarkdown.restore(protectedMarkdown.masked.replace(firstToken, "")), /placeholder .* is missing/);
});

test("protects exact technical names with longest-first overlap handling", () => {
  const namedSource = "JWKS, GROBID, Ingress, WAL, and SQLCipher use Helm Chart beside Helm.\n";
  const protectedMarkdown = protectMarkdownForTranslation(
    namedSource,
    "exact technical names",
    { protectedLiterals: MODEL_PROTECTED_LITERALS },
  );

  assert.equal((protectedMarkdown.masked.match(/_LITERAL/g) || []).length, 7);
  assert.doesNotMatch(protectedMarkdown.masked, /JWKS|GROBID|Ingress|WAL|SQLCipher|\bChart\b|\bHelm\b/u);
  const restored = protectedMarkdown.restore(protectedMarkdown.masked);
  assert.equal(restored, namedSource);
  assert.doesNotMatch(restored, /PAKPERK_PROTECTED/u);
});

test("protects singular lowercase outbox in prose without matching code, links, or substrings", () => {
  const outboxSource =
    "Drain the sync outbox; outboxes are a different word. Keep `outbox` and [the path](https://example.test/outbox).\n";
  const protectedMarkdown = protectMarkdownForTranslation(
    outboxSource,
    "lowercase technical literal",
    { protectedLiterals: MODEL_PROTECTED_LITERALS },
  );

  assert.equal((protectedMarkdown.masked.match(/_LITERAL/g) || []).length, 1);
  assert.match(protectedMarkdown.masked, /outboxes are a different word/u);
  assert.match(protectedMarkdown.masked, /_outbox\}\}`/u);
  assert.match(protectedMarkdown.masked, /_LINK/u);
  assert.equal(protectedMarkdown.restore(protectedMarkdown.masked), outboxSource);
});

test("does not add literal protection inside code or link destinations", () => {
  const nestedSource = `\`JWKS\` and [reference](https://example.test/GROBID/Ingress)

\`\`\`text
Helm Chart
\`\`\`
`;
  const protectedMarkdown = protectMarkdownForTranslation(
    nestedSource,
    "nested technical names",
    { protectedLiterals: MODEL_PROTECTED_LITERALS },
  );

  assert.doesNotMatch(protectedMarkdown.masked, /_LITERAL/u);
  assert.equal(protectedMarkdown.restore(protectedMarkdown.masked), nestedSource);
});

test("uses exact literal boundaries and leaves ambiguous UI words visible", () => {
  const boundarySource = "JWKSVerifier MyGROBID IngressController HelmChart jwks remain prose.\n";
  const boundaryProtected = protectMarkdownForTranslation(
    boundarySource,
    "literal boundaries",
    { protectedLiterals: MODEL_PROTECTED_LITERALS },
  );
  assert.equal(boundaryProtected.masked, boundarySource);

  const labelsSource = "Read You Search Library Deep Reader Passport\n";
  const labelsProtected = protectMarkdownForTranslation(
    labelsSource,
    "UI literal selection",
    { protectedLiterals: MODEL_PROTECTED_LITERALS },
  );
  assert.match(labelsProtected.masked, /^Read You Search /u);
  assert.equal((labelsProtected.masked.match(/_LITERAL/g) || []).length, 3);
  assert.doesNotMatch(labelsProtected.masked, /Library|Deep Reader|Passport/u);
  assert.equal(labelsProtected.restore(labelsProtected.masked), labelsSource);
});

test("protects only the path-specific ADR UI labels", () => {
  const labelSource = "Read You Abstract Introduction Connections\n";
  const driftProtected = protectMarkdownForTranslation(
    labelSource,
    "Drift ADR labels",
    { protectedLiterals: modelProtectedLiteralsFor("adr/0002-drift-local-database.md") },
  );
  assert.equal((driftProtected.masked.match(/_LITERAL/g) || []).length, 2);
  assert.match(driftProtected.masked, /^Read You Abstract /u);
  assert.doesNotMatch(driftProtected.masked, /Introduction|Connections/u);
  assert.equal(driftProtected.restore(driftProtected.masked), labelSource);

  const routingProtected = protectMarkdownForTranslation(
    labelSource,
    "routing ADR labels",
    { protectedLiterals: modelProtectedLiteralsFor("adr/0003-stateful-shell-routing.md") },
  );
  assert.equal((routingProtected.masked.match(/_LITERAL/g) || []).length, 5);
  assert.doesNotMatch(routingProtected.masked, /Read|You|Abstract|Introduction|Connections/u);
  assert.equal(routingProtected.restore(routingProtected.masked), labelSource);

  const unrelatedProtected = protectMarkdownForTranslation(
    labelSource,
    "ordinary prose",
    { protectedLiterals: modelProtectedLiteralsFor("developer-guide.md") },
  );
  assert.equal(unrelatedProtected.masked, labelSource);
});

test("removes model-added links while retaining source links and translated labels", () => {
  const candidate = validTranslation.replace(
    "## 连接手机",
    "## 连接手机\n\n请查看 [模型添加的链接](https://example.invalid) 和 `[代码内链接](https://keep.invalid)`。",
  );
  const cleaned = removeAddedMarkdownLinks(source, candidate);

  assert.match(cleaned, /请查看 模型添加的链接 和 `\[代码内链接\]\(https:\/\/keep\.invalid\)`/);
  assert.match(cleaned, /\[真机指南\]\(\.\.\/mobile-device-development\.md#android-phone-usb-loop\)/);
  assert.doesNotMatch(cleaned, /example\.invalid/);
});

test("protects and validates multiline inline-link destinations", () => {
  const multilineSource = "See [Manual paper search and\nimport](../paper-import.md).\n";
  const multilineTranslation = "请参阅[手动论文搜索与\n导入](../paper-import.md)。\n";
  const protectedMarkdown = protectMarkdownForTranslation(multilineSource, "fixture");

  assert.doesNotMatch(protectedMarkdown.masked, /paper-import/);
  assert.doesNotThrow(() => validateTranslationStructure(multilineSource, multilineTranslation, "fixture"));
  assert.throws(
    () => validateTranslationStructure(
      multilineSource,
      multilineTranslation.replace("../paper-import.md", "../wrong.md"),
      "fixture",
    ),
    /Markdown link destinations changed/,
  );
});

test("protects reference definitions and rejects added link-like nodes", () => {
  const referenceSource = "[guide]: ../developer-guide.md\n\nSee [the guide][guide].\n";
  const referenceTranslation = "[guide]: ../developer-guide.md\n\n请参阅[该指南][guide]。\n";
  const protectedMarkdown = protectMarkdownForTranslation(referenceSource, "fixture");

  assert.doesNotMatch(protectedMarkdown.masked, /developer-guide/);
  assert.doesNotThrow(() => validateTranslationStructure(referenceSource, referenceTranslation, "fixture"));
  assert.throws(
    () => validateTranslationStructure(referenceSource, `${referenceTranslation}<https://example.invalid>\n`, "fixture"),
    /Markdown link destinations count changed/,
  );
  assert.throws(
    () => validateTranslationStructure("Safe prose.\n", "安全正文。<a href=\"https://example.invalid\">链接</a>\n", "fixture"),
    /raw HTML fragments count changed/,
  );
  assert.throws(
    () => validateTranslationStructure("Safe prose.\n", "安全正文。[^note]\n\n[^note]: 说明\n", "fixture"),
    /Markdown footnote shapes count changed/,
  );
});

test("preserves source autolinks, link kinds, and hard line breaks", () => {
  assert.doesNotThrow(() => validateTranslationStructure(
    "Open <https://example.com>.  \nNext line.\n",
    "打开 <https://example.com>。  \n下一行。\n",
    "fixture",
  ));
  assert.throws(
    () => validateTranslationStructure("[Guide](guide.md)\n", "![指南](guide.md)\n", "fixture"),
    /inline Markdown link kinds changed/,
  );
  assert.throws(
    () => validateTranslationStructure("First line.  \nSecond line.\n", "第一行。\n第二行。\n", "fixture"),
    /Markdown hard breaks count changed/,
  );
});

test("removes only surplus hard breaks at aligned Markdown block positions", () => {
  const hardBreakSource = "# Status\n\n**Status:** Accepted  \n**Date:** Today\n";
  const hardBreakCandidate = "# 状态  \n\n**状态：** 已接受  \n**日期：** 今天  \n";
  const normalized = normalizeSurplusMarkdownHardBreaks(
    hardBreakSource,
    hardBreakCandidate,
    "fixture",
  );

  assert.equal(normalized, "# 状态\n\n**状态：** 已接受  \n**日期：** 今天\n");
  assert.doesNotThrow(() => validateTranslationStructure(hardBreakSource, normalized, "fixture"));
});

test("does not invent a missing source-required hard break", () => {
  const hardBreakSource = "**Status:** Accepted  \n**Date:** Today\n";
  const missingBreak = "**状态：** 已接受\n**日期：** 今天\n";
  const normalized = normalizeSurplusMarkdownHardBreaks(hardBreakSource, missingBreak, "fixture");

  assert.equal(normalized, missingBreak);
  assert.throws(
    () => validateTranslationStructure(hardBreakSource, normalized, "fixture"),
    /Markdown hard breaks count changed/,
  );
});

test("never removes hard-break-looking whitespace inside fenced code", () => {
  const fencedSource = "```text\nliteral\n```\n";
  const fencedCandidate = "```text\nliteral  \n```\n";
  const normalized = normalizeSurplusMarkdownHardBreaks(fencedSource, fencedCandidate, "fixture");

  assert.equal(normalized, fencedCandidate);
  assert.throws(
    () => validateTranslationStructure(fencedSource, normalized, "fixture"),
    /fenced code blocks changed/,
  );
});

test("rejects changed headings, lists, tables, and technical numbers", () => {
  assert.throws(
    () => validateTranslationStructure(source, validTranslation.replace("## 连接手机", "### 连接手机"), "fixture"),
    /heading levels changed/,
  );
  assert.throws(
    () => validateTranslationStructure(source, validTranslation.replace("2. 运行命令", "- 运行命令"), "fixture"),
    /list markers changed/,
  );
  assert.throws(
    () => validateTranslationStructure(source, validTranslation.replace("| API | HTTP 200 |", "| API | HTTP | 200 |"), "fixture"),
    /table structure changed/,
  );
  assert.throws(
    () => validateTranslationStructure(source, validTranslation.replace("版本 1.2", "版本 1.3"), "fixture"),
    /technical numbers changed.*1\.2.*1\.3/,
  );
  assert.throws(
    () => validateTranslationStructure(source, validTranslation.replace("运行命令", "运行命令\n\n模型添加的说明"), "fixture"),
    /Markdown block structure count changed/,
  );
});

test("does not split an indented fenced block at an internal blank line", () => {
  const segments = splitMarkdown(source, 80);
  const codeSegment = segments.find((segment) => segment.includes("curl --fail"));

  assert.ok(codeSegment);
  assert.match(codeSegment, /echo[\s\S]*\n\n[\s\S]*curl --fail/);
  assert.equal(segments.filter((segment) => segment.includes("```bash")).length, 1);
});

test("splits an oversized list on safe line boundaries", () => {
  const oversized = Array.from({ length: 20 }, (_, index) => `- Step ${index}: ${"detail ".repeat(8)}\n`).join("");
  const segments = splitMarkdown(oversized, 180);

  assert.ok(segments.length > 1);
  assert.ok(segments.every((segment) => segment.length <= 180));
  assert.equal(segments.join(""), oversized);
});

test("carries a trailing heading into the next segment with its content", () => {
  const prefix = `\`\`\`text
code example
\`\`\`

| State | Meaning |
| --- | --- |
| ready | accepted |

The preceding account contract is complete.

`;
  const headings = `## Account-owned and deletion extensions

### Required behavior

`;
  const following = `Account deletion uses a dedicated worker and ledger.

The provider operation remains fail-closed.
`;
  const markdown = `${prefix}${headings}${following}`;
  const maximumSegmentLength = prefix.length + headings.length;
  const segments = splitMarkdown(markdown, maximumSegmentLength);

  assert.equal(segments.join(""), markdown);
  assert.ok(segments.every((segment) => !segmentEndsWithAtxHeading(segment)));
  assert.ok(segments.some((segment) =>
    segment.includes(`${headings}Account deletion uses a dedicated worker and ledger.`)));
  assert.ok(segments.every((segment) => segment.length <= maximumSegmentLength));
});

test("keeps an oversized heading and following list safe and reconstructable", () => {
  const heading = "## Account-owned and deletion extensions\n\n";
  const list = Array.from({ length: 18 }, (_, index) =>
    `- Requirement ${index}: preserve account boundary\n`).join("");
  const markdown = `${heading}${list}`;
  const segments = splitMarkdown(markdown, 100);

  assert.equal(segments.join(""), markdown);
  assert.match(segments[0], /^## Account-owned and deletion extensions\n\n- Requirement 0:/u);
  assert.ok(segments.every((segment) => !segmentEndsWithAtxHeading(segment)));
  assert.ok(segments.every((segment) => segment.length <= 100));
  assert.ok(segments.slice(1).every((segment) => segment.startsWith("- Requirement ")));
});

function segmentEndsWithAtxHeading(segment) {
  const lastLine = segment.trimEnd().split(/\r?\n/).at(-1) || "";
  return /^[\t ]{0,3}#{1,6}(?:[\t ]+|$)/u.test(lastLine);
}
