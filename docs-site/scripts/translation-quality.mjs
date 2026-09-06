import {
  exactUiLabelsFor,
  FORBIDDEN_TRANSLATION_RULES,
  mandatoryTerminologyFor,
  PAKPERK_UI_LABELS,
  PRESERVED_EXACT_UI_LABELS,
  PRESERVED_TECHNICAL_NAMES,
  TERMINOLOGY_NORMALIZATIONS,
} from "./translation-policy.mjs";
import { protectMarkdownForTranslation } from "./translation-structure.mjs";

const openingFencePattern = /^[\t ]*(`{3,}|~{3,})[^\r\n]*(?:\r?\n)?$/;
const englishWindowWords = 10;
const minimumEnglishWindowCharacters = 60;
const minimumNonTechnicalWords = 4;

const modelControlPatterns = [
  /\/no_think\b/iu,
  /<\/?think>/iu,
  /<\|(?:assistant|user|system|im_start|im_end|endoftext)\|>/iu,
];

const inventedCommentaryPatterns = [
  /翻译结果如下/u,
  /(?:原文|源文档)[^。\n]{0,40}(?:不完整|未完成|未提供|缺失)/u,
  /根据上下文(?:推测|猜测|推断)/u,
  /(?:（|\()注：[^\n]*(?:原文|上下文)/u,
  /作为(?:一个)?(?:AI|语言模型)/iu,
];

const technicalEnglishWords = new Set([
  "api", "app", "connect", "http", "https", "json", "markdown", "openapi", "store",
  "yaml", "debug", "profile", "release", "id", "ids", "url", "urls", "ui", "sdk",
  ...PRESERVED_TECHNICAL_NAMES.flatMap(englishWords),
  ...PAKPERK_UI_LABELS.flatMap(englishWords),
].map((word) => word.toLowerCase()));

const exactUiLabels = new Set(PRESERVED_EXACT_UI_LABELS);
const contextualUiLabels = PAKPERK_UI_LABELS.filter((label) => !exactUiLabels.has(label));

export function normalizeTranslationTerminology(
  source,
  translation,
  relativePath = "",
  label = relativePath || "translation",
) {
  const protectedMarkdown = protectMarkdownForTranslation(translation, label);
  const visibleSource = normalizeWhitespace(visibleProse(source));
  let normalized = protectedMarkdown.masked;
  for (const rule of TERMINOLOGY_NORMALIZATIONS) {
    if (rule.sourcePattern.test(visibleSource)) {
      normalized = normalized.replace(rule.pattern, rule.replacement);
    }
  }
  normalized = normalized
    .replace(/(\p{Script=Han}):(\*{1,3})(?=[\t ]|$)/gmu, "$1：$2")
    .replace(/(\p{Script=Han})(\*{1,3})?:(?=[\t ]|$)/gmu, "$1$2：")
    .replace(/(\p{Script=Han})[\t ]+(?=\p{Script=Han})/gu, "$1");
  return protectedMarkdown.restore(normalized);
}

/**
 * Rejects high-confidence translation quality failures in visible Markdown prose.
 * Structural validation remains the responsibility of translation-structure.mjs.
 */
export function validateTranslationQuality(
  source,
  translation,
  relativePath = "",
  label = relativePath || "translation",
) {
  if (typeof source !== "string" || typeof translation !== "string") {
    throw new TypeError(`${label}: source and translation must be strings`);
  }

  const visibleSource = visibleProse(source);
  const visibleTranslation = visibleProse(translation);
  const normalizedSource = normalizeWhitespace(visibleSource);

  for (const pattern of modelControlPatterns) {
    const match = visibleTranslation.match(pattern);
    if (match) throw new Error(`${label}: model-control token leaked into prose: ${JSON.stringify(match[0])}`);
  }

  for (const pattern of inventedCommentaryPatterns) {
    const match = visibleTranslation.match(pattern);
    if (match && !visibleSource.match(pattern)) {
      throw new Error(`${label}: translator commentary was added to prose: ${JSON.stringify(match[0])}`);
    }
  }

  for (const rule of FORBIDDEN_TRANSLATION_RULES) {
    if (rule.sourcePattern && !rule.sourcePattern.test(normalizedSource)) continue;
    const match = visibleTranslation.match(rule.pattern);
    if (match) {
      throw new Error(`${label}: known bad calque (${rule.description}): ${JSON.stringify(match[0])}`);
    }
  }

  const duplicatedPhrase = findDuplicatedChinesePhrase(visibleTranslation);
  if (duplicatedPhrase) {
    throw new Error(`${label}: adjacent Chinese phrase was duplicated: ${JSON.stringify(duplicatedPhrase)}`);
  }

  validatePreservedNames(visibleSource, visibleTranslation, relativePath, label);
  const unchanged = findUnchangedEnglishProse(visibleSource, visibleTranslation);
  if (unchanged) {
    throw new Error(`${label}: substantial English prose copied unchanged: ${JSON.stringify(unchanged)}`);
  }
  validateBlockCoverage(visibleSource, visibleTranslation, relativePath, label);
}

function validatePreservedNames(source, translation, relativePath, label) {
  for (const name of PRESERVED_TECHNICAL_NAMES) {
    comparePreservedCount(name, source, translation, label, "technical name");
  }
  const pathExactUiLabels = new Set(exactUiLabelsFor(relativePath));
  for (const labelName of pathExactUiLabels) {
    comparePreservedCount(labelName, source, translation, label, "Pakperk UI label");
  }
  for (const contextualLabel of contextualUiLabels) {
    if (pathExactUiLabels.has(contextualLabel)) continue;
    const sourceCount = contextualLabelCount(source, contextualLabel);
    const translationCount = literalCount(translation, contextualLabel);
    if (translationCount < sourceCount) {
      throw new Error(
        `${label}: Pakperk UI label ${JSON.stringify(contextualLabel)} count decreased ` +
        `(${sourceCount} -> ${translationCount})`,
      );
    }
  }
}

function comparePreservedCount(name, source, translation, label, kind) {
  const sourceCount = literalCount(source, name);
  if (sourceCount === 0) return;
  const translationCount = literalCount(translation, name);
  if (translationCount < sourceCount) {
    throw new Error(`${label}: ${kind} ${JSON.stringify(name)} count decreased (${sourceCount} -> ${translationCount})`);
  }
}

function validateBlockCoverage(source, translation, relativePath, label) {
  const sourceUnits = coverageUnits(source);
  const translationUnits = coverageUnits(translation);
  if (sourceUnits.length !== translationUnits.length) {
    throw new Error(`${label}: visible prose unit count changed (${sourceUnits.length} -> ${translationUnits.length})`);
  }

  for (const [index, sourceUnitRaw] of sourceUnits.entries()) {
    const translationUnitRaw = translationUnits[index];
    const sourceUnit = normalizeWhitespace(stripMarkdownSyntax(sourceUnitRaw));
    const translationUnit = normalizeWhitespace(stripMarkdownSyntax(translationUnitRaw));
    if (!sourceUnit) continue;

    rejectShortUnchangedEnglish(sourceUnit, translationUnit, label, index);
    rejectMissingSentenceMarkers(sourceUnit, translationUnit, label, index);
    rejectInsufficientBlockCoverage(sourceUnit, translationUnit, label, index);
    validateObligationStrength(sourceUnit, translationUnit, label, index);

    for (const rule of mandatoryTerminologyFor(relativePath)) {
      if (!rule.sourcePattern.test(sourceUnit)) continue;
      const matchesConditionalTarget = rule.conditionalTargets.some((conditionalTarget) =>
        conditionalTarget.sourcePattern.test(sourceUnit) &&
        conditionalTarget.targetPattern.test(translationUnit));
      if (!rule.targetPattern.test(translationUnit) && !matchesConditionalTarget) {
        throw new Error(
          `${label}: required terminology ${JSON.stringify(rule.sourceLabel)} -> ` +
          `${JSON.stringify(rule.targetLabel)} is missing from prose unit ${index + 1}; ` +
          `translation: ${JSON.stringify(diagnosticOverview(
            translationUnit,
            240,
            mandatoryDiagnosticCue(rule),
          ))}`,
        );
      }
    }
  }
}

function rejectShortUnchangedEnglish(source, translation, label, index) {
  const sourceTokens = englishWords(source).map((word) => word.toLowerCase());
  if (sourceTokens.length === 0 || sourceTokens.length >= englishWindowWords) return;
  if (!sourceTokens.some((word) => !technicalEnglishWords.has(word))) return;
  if (/\p{Script=Han}/u.test(translation)) return;
  const translationTokens = englishWords(translation).map((word) => word.toLowerCase());
  if (!containsTokenSequence(translationTokens, sourceTokens)) return;
  throw new Error(
    `${label}: short English prose copied unchanged in prose unit ${index + 1}` +
    diagnosticContext(source, translation),
  );
}

function rejectMissingSentenceMarkers(source, translation, label, index) {
  const sourceMarkers = sentenceMarkerCount(source);
  if (sourceMarkers < 2) return;
  const translationMarkers = sentenceMarkerCount(translation);
  if (translationMarkers < sourceMarkers) {
    throw new Error(
      `${label}: sentence/clause markers decreased in prose unit ${index + 1} ` +
      `(${sourceMarkers} -> ${translationMarkers}); source prose may have been omitted` +
      diagnosticContext(source, translation),
    );
  }
}

function rejectInsufficientBlockCoverage(source, translation, label, index) {
  const sourceWordCount = englishWords(source)
    .filter((word) => !technicalEnglishWords.has(word.toLowerCase())).length;
  if (sourceWordCount < 12) return;
  const translatedSemanticUnits = (translation.match(/\p{Script=Han}/gu) || []).length +
    englishWords(translation).filter((word) => !technicalEnglishWords.has(word.toLowerCase())).length;
  const minimumUnits = Math.max(4, Math.floor(sourceWordCount * 0.25));
  if (translatedSemanticUnits < minimumUnits) {
    throw new Error(
      `${label}: prose unit ${index + 1} is too short to cover its source ` +
      `(${sourceWordCount} source words -> ${translatedSemanticUnits} translated semantic units)` +
      diagnosticContext(source, translation),
    );
  }
}

function validateObligationStrength(source, translation, label, index) {
  const obligations = [
    { source: /\bmust\s+never\b/iu, target: /不得|绝不能|严禁|禁止|不允许|必须[^。；]{0,12}绝不/u, name: "must never" },
    { source: /\b(?:MUST NOT|Must not|must not)\b/u, target: /不得|禁止|严禁|不能|不允许|必须[^。；]{0,12}不/u, name: "must not" },
    { source: /\bmust\b(?!\s+(?:not|never)\b)/iu, target: /必须|务必|需要/u, name: "must" },
    { source: /\bSHOULD NOT\b/u, target: /不应|不得/u, name: "SHOULD NOT" },
    { source: /\bSHOULD\b(?!\s+NOT)/u, target: /应|建议/u, name: "SHOULD" },
    { source: /\bMAY\b/u, target: /可以|可/u, name: "MAY" },
  ];
  for (const obligation of obligations) {
    if (obligation.source.test(source) && !obligation.target.test(translation)) {
      throw new Error(
        `${label}: obligation strength for ${obligation.name} was not preserved in prose unit ${index + 1}` +
        diagnosticContext(source, translation),
      );
    }
  }
}

function coverageUnits(markdown) {
  return markdownBlocks(markdown).flatMap((block) => {
    const lines = block.split(/\r?\n/);
    if (lines.every((line) => /^\s*$/.test(line) || referenceDefinition(line))) return [];

    const tableRows = lines.filter((line) => tableCells(line));
    if (tableRows.length >= 2 && tableRows.some((line) => tableCells(line)?.every(isTableDelimiter))) {
      return tableRows
        .filter((line) => !tableCells(line).every(isTableDelimiter))
        .flatMap((line) => tableCells(line));
    }

    if (lines.some((line) => listMarker(line))) {
      const units = [];
      let current = "";
      for (const line of lines) {
        if (listMarker(line)) {
          if (current.trim()) units.push(current);
          current = line.replace(/^([\t ]*(?:>[\t ]*)*)(?:[-+*]|\d+[.)])[\t ]+(?:\[[ xX]\][\t ]+)?/, "");
        } else {
          current += ` ${line.trim()}`;
        }
      }
      if (current.trim()) units.push(current);
      return units;
    }

    const headingLines = lines.filter((line) => /^[\t ]{0,3}#{1,6}(?:[\t ]+|$)/.test(line));
    if (headingLines.length === lines.filter((line) => line.trim()).length) {
      return headingLines.map((line) => line.replace(/^[\t ]{0,3}#{1,6}[\t ]*/, ""));
    }
    return [block.replace(/^[\t ]*>[\t ]?/gm, "")];
  });
}

function markdownBlocks(markdown) {
  return markdown
    .trim()
    .split(/\r?\n[\t ]*\r?\n/)
    .map((block) => block.trim())
    .filter(Boolean);
}

function stripMarkdownSyntax(value) {
  return value
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/gm, "")
    .replace(/^\s*>\s?/gm, "")
    .replace(/!?(?:\[([^\]]*)\])(?:\[[^\]]*\]|\([^)]*\))/g, "$1")
    .replace(/[*_~]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function visibleProse(markdown) {
  return maskLinkDestinations(maskInlineCode(maskFencedCode(markdown)));
}

function maskFencedCode(markdown) {
  let output = "";
  let fence = null;
  for (const match of markdown.matchAll(/.*(?:\r?\n|$)/g)) {
    const line = match[0];
    if (!line) continue;
    if (!fence) {
      const opening = line.match(openingFencePattern);
      if (!opening) {
        output += line;
        continue;
      }
      fence = { character: opening[1][0], length: opening[1].length };
      output += maskCharacters(line);
      continue;
    }

    output += maskCharacters(line);
    const withoutNewline = line.replace(/\r?\n$/, "").trim();
    if (withoutNewline.length >= fence.length && [...withoutNewline].every((character) => character === fence.character)) {
      fence = null;
    }
  }
  return output;
}

function maskInlineCode(markdown) {
  let output = "";
  let cursor = 0;
  let index = 0;
  while (index < markdown.length) {
    if (markdown[index] !== "`") {
      index += 1;
      continue;
    }
    let runLength = 1;
    while (markdown[index + runLength] === "`") runLength += 1;
    const delimiter = "`".repeat(runLength);
    let closing = markdown.indexOf(delimiter, index + runLength);
    while (closing !== -1 && (markdown[closing - 1] === "`" || markdown[closing + runLength] === "`")) {
      closing = markdown.indexOf(delimiter, closing + runLength);
    }
    if (closing === -1) {
      index += runLength;
      continue;
    }
    const end = closing + runLength;
    output += markdown.slice(cursor, index);
    output += maskCharacters(markdown.slice(index, end));
    cursor = end;
    index = end;
  }
  return output + markdown.slice(cursor);
}

function maskLinkDestinations(markdown) {
  const ranges = [];
  for (const match of markdown.matchAll(/!?(?:\[[\s\S]*?\])\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/g)) {
    const localStart = match[0].lastIndexOf(match[1]);
    ranges.push({ start: match.index + localStart, end: match.index + localStart + match[1].length });
  }
  for (const match of markdown.matchAll(/^[\t ]{0,3}\[(?!\^)[^\]\n]+\]:[\t ]*(<[^>\n]+>|\S+)/gm)) {
    const localStart = match[0].lastIndexOf(match[1]);
    ranges.push({ start: match.index + localStart, end: match.index + localStart + match[1].length });
  }
  return maskRanges(markdown, ranges.sort((left, right) => left.start - right.start));
}

function maskRanges(value, ranges) {
  let output = "";
  let cursor = 0;
  for (const range of ranges) {
    if (range.start < cursor) continue;
    output += value.slice(cursor, range.start);
    output += maskCharacters(value.slice(range.start, range.end));
    cursor = range.end;
  }
  return output + value.slice(cursor);
}

function maskCharacters(value) {
  return value.replace(/[^\r\n]/g, " ");
}

function findUnchangedEnglishProse(source, translation) {
  const translationWindows = new Set();
  for (const run of englishRuns(translation)) {
    for (const window of qualifyingWindows(run)) translationWindows.add(window.key);
  }
  for (const run of englishRuns(source)) {
    for (const window of qualifyingWindows(run)) {
      if (translationWindows.has(window.key)) return window.excerpt;
    }
  }
  return null;
}

function englishRuns(value) {
  const tokens = [...value.matchAll(/(?<![\p{L}\p{N}_])[A-Za-z]+(?:['’-][A-Za-z]+)*(?![\p{L}\p{N}_])/gu)]
    .map((match) => ({ value: match[0], start: match.index, end: match.index + match[0].length }));
  const runs = [];
  let run = [];
  for (const token of tokens) {
    const previous = run.at(-1);
    const gap = previous ? value.slice(previous.end, token.start) : "";
    if (previous && (/\p{Script=Han}/u.test(gap) || /\r?\n[\t ]*\r?\n/.test(gap) || gap.length > 80)) {
      if (run.length) runs.push(run);
      run = [];
    }
    run.push(token);
  }
  if (run.length) runs.push(run);
  return runs;
}

function qualifyingWindows(run) {
  const windows = [];
  for (let index = 0; index + englishWindowWords <= run.length; index += 1) {
    const tokens = run.slice(index, index + englishWindowWords);
    const normalized = tokens.map((token) => token.value.toLowerCase());
    const characterCount = normalized.reduce((total, word) => total + word.length, englishWindowWords - 1);
    const nonTechnicalCount = normalized.filter((word) => !technicalEnglishWords.has(word)).length;
    if (characterCount < minimumEnglishWindowCharacters || nonTechnicalCount < minimumNonTechnicalWords) continue;
    windows.push({ key: normalized.join("\u0001"), excerpt: tokens.map((token) => token.value).join(" ") });
  }
  return windows;
}

function findDuplicatedChinesePhrase(value) {
  for (const match of value.matchAll(/([\p{Script=Han}]{4,18})(?:[，、；：]?[\t ]*)\1/gu)) {
    return match[0];
  }
  return null;
}

function sentenceMarkerCount(value) {
  const normalized = value
    .replace(/\b(?:e\.g|i\.e|etc)\./giu, " ")
    .replace(/(?<=\d)\.(?=\d)/g, " ");
  return (normalized.match(/[。！？!?]|\.(?=(?:["'’”）)\]}*_~]+)?(?:\s|$))/gu) || []).length;
}

function literalCount(value, literal) {
  const escaped = literal.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...value.matchAll(new RegExp(`(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])`, "gu"))].length;
}

function contextualLabelCount(value, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const boundedLabel = `(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])`;
  const uiNoun = "tab|stage|screen|destination|route|surface|view|page|button|control|label";
  const pattern = new RegExp(
    `(?:` +
      `(?:\\*\\*|__|[“"])[\\t ]*${boundedLabel}[\\t ]*(?:\\*\\*|__|[”"])|` +
      `(?:${uiNoun})[\\t ]+(?:the[\\t ]+)?${boundedLabel}|` +
      `${boundedLabel}[\\t ]+(?:${uiNoun})` +
    `)`,
    "giu",
  );
  return [...value.matchAll(pattern)].length;
}

function englishWords(value) {
  return [...value.matchAll(/(?<![\p{L}\p{N}_])[A-Za-z]+(?:['’-][A-Za-z]+)*(?![\p{L}\p{N}_])/gu)]
    .map((match) => match[0]);
}

function containsTokenSequence(haystack, needle) {
  if (needle.length > haystack.length) return false;
  outer: for (let index = 0; index <= haystack.length - needle.length; index += 1) {
    for (let offset = 0; offset < needle.length; offset += 1) {
      if (haystack[index + offset] !== needle[offset]) continue outer;
    }
    return true;
  }
  return false;
}

function normalizeWhitespace(value) {
  return value.replace(/\s+/g, " ").trim();
}

function diagnosticExcerpt(value, maximumCharacters = 160) {
  const singleLine = singleLineDiagnosticValue(value);
  const characters = [...singleLine];
  if (characters.length <= maximumCharacters) return singleLine;
  return `${characters.slice(0, maximumCharacters - 1).join("")}…`;
}

function diagnosticOverview(value, maximumCharacters = 240, cuePattern = null) {
  const singleLine = singleLineDiagnosticValue(value);
  const characters = [...singleLine];
  if (characters.length <= maximumCharacters) return singleLine;

  const separator = " … ";
  const availableCharacters = maximumCharacters - ([...separator].length * 2);
  const headLength = Math.floor(availableCharacters / 3);
  const middleLength = Math.floor(availableCharacters / 3);
  const tailLength = availableCharacters - headLength - middleLength;
  const tailStart = characters.length - tailLength;
  let middleStart = Math.floor((characters.length - middleLength) / 2);
  const cueMatch = cuePattern ? singleLine.match(cuePattern) : null;
  if (cueMatch?.index !== undefined) {
    const cueStart = [...singleLine.slice(0, cueMatch.index)].length;
    if (cueStart >= headLength && cueStart < tailStart) {
      middleStart = Math.max(
        headLength,
        Math.min(tailStart - middleLength, cueStart - Math.floor(middleLength / 2)),
      );
    }
  }
  return characters.slice(0, headLength).join("") + separator +
    characters.slice(middleStart, middleStart + middleLength).join("") + separator +
    characters.slice(tailStart).join("");
}

function singleLineDiagnosticValue(value) {
  const withoutControls = [...value].map((character) => {
    const codePoint = character.codePointAt(0);
    return codePoint < 32 || codePoint === 127 ? " " : character;
  }).join("");
  return normalizeWhitespace(withoutControls);
}

function mandatoryDiagnosticCue(rule) {
  if (rule.id === "fail-closed") return /失败|关闭|拒绝/u;
  return null;
}

function diagnosticContext(source, translation) {
  return `; source: ${JSON.stringify(diagnosticExcerpt(source))}; ` +
    `translation: ${JSON.stringify(diagnosticExcerpt(translation))}`;
}

function listMarker(line) {
  return /^([\t ]*(?:>[\t ]*)*)(?:[-+*]|\d+[.)])[\t ]+(?:\[[ xX]\][\t ]+)?/.test(line);
}

function referenceDefinition(line) {
  return /^[\t ]{0,3}\[(?!\^)[^\]\n]+\]:[\t ]*\S+/.test(line);
}

function tableCells(line) {
  let value = line.trim();
  if (!value.includes("|")) return null;
  if (value.startsWith("|")) value = value.slice(1);
  if (/(?<!\\)\|$/.test(value)) value = value.slice(0, -1);
  const cells = value.split(/(?<!\\)\|/).map((cell) => cell.trim());
  return cells.length > 1 ? cells : null;
}

function isTableDelimiter(cell) {
  return /^:?-{3,}:?$/.test(cell);
}
