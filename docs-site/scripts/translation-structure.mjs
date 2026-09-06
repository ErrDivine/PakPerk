const openingFencePattern = /^[\t ]*(`{3,}|~{3,})[^\r\n]*(?:\r?\n)?$/;

export function restoreAndValidateTranslation(source, candidate, label = "translation") {
  let restored = restoreProtectedRanges(
    candidate,
    fencedCodeRanges(candidate, label),
    fencedCodeRanges(source, label).map((range) => range.value),
    "fenced code blocks",
    label,
  );
  restored = restoreProtectedRanges(
    restored,
    inlineCodeRanges(restored),
    inlineCodeRanges(source).map((range) => range.value),
    "inline-code spans",
    label,
  );
  restored = restoreProtectedRanges(
    restored,
    linkDestinationRanges(restored),
    linkDestinationRanges(source).map((range) => range.value),
    "Markdown link destinations",
    label,
  );
  restored = restoreProtectedRanges(
    restored,
    rawHtmlRanges(restored),
    rawHtmlRanges(source).map((range) => range.value),
    "raw HTML fragments",
    label,
  );
  validateTranslationStructure(source, restored, label);
  return restored;
}

export function protectMarkdownForTranslation(source, label = "translation", options = {}) {
  const structuralRanges = [
    ...fencedCodeRanges(source, label).map((range) => ({ ...range, kind: "code" })),
    ...inlineCodeRanges(source).map((range) => ({ ...range, kind: "code" })),
    ...linkDestinationRanges(source).map((range) => ({ ...range, kind: "link" })),
    ...rawHtmlRanges(source).map((range) => ({ ...range, kind: "markup" })),
    ...technicalNumberRanges(source, label).map((range) => ({ ...range, kind: "number" })),
  ];
  const ranges = [
    ...structuralRanges,
    ...protectedLiteralRanges(source, options.protectedLiterals, structuralRanges, label),
  ].sort((left, right) => left.start - right.start);
  const protectedRanges = [];
  let masked = "";
  let cursor = 0;

  for (const [index, range] of ranges.entries()) {
    if (range.start < cursor) {
      throw new Error(`${label}: protected Markdown ranges overlap`);
    }
    const descriptor = protectedDescriptor(range);
    const marker = `PAKPERK_PROTECTED_${String(index + 1).padStart(4, "0")}_${descriptor}`;
    const token = range.kind === "link"
      ? `https://pakperk.invalid/__protected/${marker}`
      : `\`{{${marker}}}\``;
    masked += source.slice(cursor, range.start);
    masked += token;
    protectedRanges.push({ token, value: range.value });
    cursor = range.end;
  }
  masked += source.slice(cursor);

  return {
    masked,
    restore(candidate) {
      let previousIndex = -1;
      for (const { token } of protectedRanges) {
        const firstIndex = candidate.indexOf(token);
        const lastIndex = candidate.lastIndexOf(token);
        if (firstIndex === -1) throw new Error(`${label}: protected placeholder ${token} is missing`);
        if (firstIndex !== lastIndex) throw new Error(`${label}: protected placeholder ${token} was duplicated`);
        if (firstIndex < previousIndex) throw new Error(`${label}: protected placeholders were reordered`);
        previousIndex = firstIndex;
      }

      let restored = candidate;
      for (const { token, value } of protectedRanges) restored = restored.replace(token, () => value);
      if (/\{\{PAKPERK_[A-Z0-9_]+\}\}|https:\/\/pakperk\.invalid\/__protected\/PAKPERK_[A-Z0-9_]+/.test(restored)) {
        throw new Error(`${label}: unexpected protected placeholder remains`);
      }
      return restored;
    },
  };
}

function protectedDescriptor(range) {
  if (range.kind === "link") return "LINK";
  if (range.kind === "markup") return "MARKUP";
  if (range.kind === "literal") return "LITERAL";
  if (range.kind === "number") return `NUMBER_${range.value.replace(/[^A-Za-z0-9]+/g, "_")}`;
  if (range.value.length > 160 || /\r?\n/.test(range.value)) return "CODE_BLOCK";
  const descriptor = range.value
    .replace(/`/g, "")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 72);
  return descriptor || "CODE";
}

function protectedLiteralRanges(source, configuredLiterals, excludedRanges, label) {
  if (configuredLiterals === undefined) return [];
  if (!Array.isArray(configuredLiterals)) {
    throw new TypeError(`${label}: protectedLiterals must be an array of non-empty strings`);
  }
  const literals = [...new Set(configuredLiterals)].sort((left, right) =>
    right.length - left.length || (left < right ? -1 : left > right ? 1 : 0));
  if (literals.some((literal) => typeof literal !== "string" || literal.length === 0)) {
    throw new TypeError(`${label}: protectedLiterals must be an array of non-empty strings`);
  }

  const ranges = [];
  const occupied = [...excludedRanges];
  for (const literal of literals) {
    let start = source.indexOf(literal);
    while (start !== -1) {
      const end = start + literal.length;
      if (
        hasLiteralBoundaries(source, literal, start, end) &&
        !occupied.some((range) => rangesOverlap(start, end, range.start, range.end))
      ) {
        const range = { start, end, value: literal, kind: "literal" };
        ranges.push(range);
        occupied.push(range);
      }
      start = source.indexOf(literal, start + literal.length);
    }
  }
  return ranges;
}

function hasLiteralBoundaries(source, literal, start, end) {
  const first = literal.match(/^./u)?.[0] || "";
  const last = literal.match(/.$/u)?.[0] || "";
  const previous = source.slice(0, start).match(/.$/u)?.[0] || "";
  const next = source.slice(end).match(/^./u)?.[0] || "";
  if (literalWordCharacter(first) && literalWordCharacter(previous)) return false;
  if (literalWordCharacter(last) && literalWordCharacter(next)) return false;
  return true;
}

function literalWordCharacter(character) {
  return /[\p{L}\p{N}_]/u.test(character);
}

function rangesOverlap(leftStart, leftEnd, rightStart, rightEnd) {
  return leftStart < rightEnd && rightStart < leftEnd;
}

export function removeAddedMarkdownLinks(source, candidate) {
  const allowedDestinations = new Map();
  for (const { value } of linkDestinationRanges(source)) {
    allowedDestinations.set(value, (allowedDestinations.get(value) || 0) + 1);
  }

  const protectedRanges = [
    ...fencedCodeRanges(candidate, "translation"),
    ...inlineCodeRanges(candidate),
  ].sort((left, right) => left.start - right.start);
  const visible = maskRanges(candidate, protectedRanges);
  const pattern = /(!?)\[([^\]]*)\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/g;
  let cleaned = "";
  let cursor = 0;
  let changed = false;

  for (const match of visible.matchAll(pattern)) {
    const destination = candidate.slice(
      match.index + match[0].indexOf(match[3]),
      match.index + match[0].indexOf(match[3]) + match[3].length,
    );
    const remaining = allowedDestinations.get(destination) || 0;
    if (remaining > 0) {
      allowedDestinations.set(destination, remaining - 1);
      continue;
    }

    const labelStart = match.index + match[0].indexOf("[") + 1;
    const label = candidate.slice(labelStart, labelStart + match[2].length);
    cleaned += candidate.slice(cursor, match.index);
    cleaned += label;
    cursor = match.index + match[0].length;
    changed = true;
  }

  return changed ? cleaned + candidate.slice(cursor) : candidate;
}

export function normalizeSurplusMarkdownHardBreaks(source, candidate, label = "translation") {
  if (typeof source !== "string" || typeof candidate !== "string") {
    throw new TypeError(`${label}: source and candidate must be strings`);
  }
  const sourceShapes = markdownBlockShapes(source);
  const candidateShapes = markdownBlockShapes(candidate);
  if (
    sourceShapes.length !== candidateShapes.length ||
    sourceShapes.some((shape, index) => shape !== candidateShapes[index])
  ) {
    return candidate;
  }

  const required = new Set(
    hardBreakEntries(source).map((entry) => hardBreakPositionKey(entry)),
  );
  const surplus = hardBreakEntries(candidate)
    .filter((entry) => !required.has(hardBreakPositionKey(entry)))
    .sort((left, right) => right.start - left.start);
  let normalized = candidate;
  for (const entry of surplus) {
    normalized = normalized.slice(0, entry.start) + normalized.slice(entry.end);
  }
  return normalized;
}

export function validateTranslationStructure(source, translation, label = "translation") {
  compareValues(
    "fenced code blocks",
    fencedCodeRanges(source, label).map((range) => range.value),
    fencedCodeRanges(translation, label).map((range) => range.value),
    label,
  );
  compareValues(
    "inline-code spans",
    inlineCodeRanges(source).map((range) => range.value),
    inlineCodeRanges(translation).map((range) => range.value),
    label,
  );
  compareValues(
    "Markdown link destinations",
    linkDestinationRanges(source).map((range) => range.value),
    linkDestinationRanges(translation).map((range) => range.value),
    label,
  );
  compareValues("inline Markdown link kinds", inlineLinkKinds(source), inlineLinkKinds(translation), label);
  compareValues("reference-link shapes", referenceLinkShapes(source), referenceLinkShapes(translation), label);
  compareValues(
    "raw HTML fragments",
    rawHtmlRanges(source).map((range) => range.value),
    rawHtmlRanges(translation).map((range) => range.value),
    label,
  );
  compareValues("Markdown footnote shapes", footnoteShapes(source), footnoteShapes(translation), label);
  compareValues("setext heading levels", setextHeadingLevels(source), setextHeadingLevels(translation), label);
  compareValues(
    "Markdown hard breaks",
    hardBreakEntries(source).map((entry) => hardBreakPositionKey(entry)),
    hardBreakEntries(translation).map((entry) => hardBreakPositionKey(entry)),
    label,
  );
  compareValues("heading levels", headingLevels(source), headingLevels(translation), label);
  compareValues("list markers", listMarkers(source), listMarkers(translation), label);
  compareValues("table structure", tableShapes(source), tableShapes(translation), label);
  compareValues("Markdown block structure", markdownBlockShapes(source), markdownBlockShapes(translation), label);
  compareValues("technical numbers", technicalNumbers(source), technicalNumbers(translation), label);
}

export function splitMarkdown(source, maximumSegmentLength = 3_200) {
  const paragraphs = [];
  let paragraph = "";
  let fence = null;

  for (const { text } of linesWithOffsets(source)) {
    if (!fence && atxHeadingLine(text) && paragraph && /\S/u.test(paragraph)) {
      paragraphs.push(paragraph);
      paragraph = "";
    }
    paragraph += text;
    if (fence) {
      if (isClosingFence(text, fence)) fence = null;
    } else {
      fence = openingFence(text);
    }
    if (!fence && /^\s*$/.test(text)) {
      paragraphs.push(paragraph);
      paragraph = "";
    }
  }
  if (fence) throw new Error("source contains an unclosed fenced code block");
  if (paragraph) paragraphs.push(paragraph);

  const units = attachHeadingBlocks(paragraphs, maximumSegmentLength);
  const segments = [];
  let buffer = "";
  for (const block of units) {
    if (buffer && buffer.length + block.length > maximumSegmentLength) {
      segments.push(buffer);
      buffer = "";
    }
    buffer += block;
  }
  if (buffer) segments.push(buffer);
  return segments;
}

function attachHeadingBlocks(blocks, maximumSegmentLength) {
  const units = [];
  let pendingHeadings = "";
  for (const block of blocks) {
    if (atxHeadingBlock(block) || (pendingHeadings && !block.trim())) {
      pendingHeadings += block;
      continue;
    }

    if (!pendingHeadings) {
      units.push(...splitOversizedBlock(block, maximumSegmentLength));
      continue;
    }

    const availableForContent = Math.max(1, maximumSegmentLength - pendingHeadings.length);
    const contentPieces = splitOversizedBlock(block, availableForContent);
    if (contentPieces.length === 0) continue;
    units.push(`${pendingHeadings}${contentPieces[0]}`, ...contentPieces.slice(1));
    pendingHeadings = "";
  }

  if (pendingHeadings) {
    if (units.length === 0) units.push(pendingHeadings);
    else units[units.length - 1] += pendingHeadings;
  }
  return units;
}

function atxHeadingBlock(block) {
  const contentLines = block.split(/\r?\n/).filter((line) => line.trim());
  return contentLines.length > 0 && contentLines.every(atxHeadingLine);
}

function atxHeadingLine(line) {
  return /^[\t ]{0,3}#{1,6}(?:[\t ]+|$)/u.test(line.replace(/\r?\n$/, ""));
}

function splitOversizedBlock(block, maximumSegmentLength) {
  if (block.length <= maximumSegmentLength) return [block];

  const pieces = [];
  let buffer = "";
  let fence = null;
  for (const { text } of linesWithOffsets(block)) {
    if (!fence && buffer && buffer.length + text.length > maximumSegmentLength) {
      pieces.push(buffer);
      buffer = "";
    }
    buffer += text;
    if (fence) {
      if (isClosingFence(text, fence)) fence = null;
    } else {
      fence = openingFence(text);
    }
  }
  if (buffer) pieces.push(buffer);
  return pieces;
}

export function splitAroundFencedBlocks(source, label = "translation") {
  const ranges = fencedCodeRanges(source, label);
  const pieces = [];
  let cursor = 0;
  for (const range of ranges) {
    if (range.start > cursor) pieces.push({ protected: false, text: source.slice(cursor, range.start) });
    pieces.push({ protected: true, text: range.value });
    cursor = range.end;
  }
  if (cursor < source.length) pieces.push({ protected: false, text: source.slice(cursor) });
  return pieces;
}

function restoreProtectedRanges(value, ranges, originals, kind, label) {
  if (ranges.length !== originals.length) {
    throw new Error(`${label}: ${kind} count changed (${originals.length} -> ${ranges.length})`);
  }
  let restored = "";
  let cursor = 0;
  for (const [index, range] of ranges.entries()) {
    restored += value.slice(cursor, range.start);
    restored += originals[index];
    cursor = range.end;
  }
  return restored + value.slice(cursor);
}

function compareValues(kind, expected, actual, label) {
  if (expected.length !== actual.length) {
    throw new Error(`${label}: ${kind} count changed (${expected.length} -> ${actual.length})`);
  }
  for (const [index, value] of expected.entries()) {
    if (value !== actual[index]) {
      const detail = kind === "technical numbers"
        ? ` (${JSON.stringify(value)} -> ${JSON.stringify(actual[index])})`
        : "";
      throw new Error(`${label}: ${kind} changed at item ${index + 1}${detail}`);
    }
  }
}

function fencedCodeRanges(markdown, label) {
  const ranges = [];
  let fence = null;
  for (const line of linesWithOffsets(markdown)) {
    if (!fence) {
      const opening = openingFence(line.text);
      if (opening) fence = { ...opening, start: line.start };
      continue;
    }
    if (isClosingFence(line.text, fence)) {
      const end = line.end;
      ranges.push({ start: fence.start, end, value: markdown.slice(fence.start, end) });
      fence = null;
    }
  }
  if (fence) throw new Error(`${label}: unclosed fenced code block`);
  return ranges;
}

function openingFence(line) {
  const match = line.match(openingFencePattern);
  if (!match) return null;
  return { character: match[1][0], length: match[1].length };
}

function isClosingFence(line, fence) {
  const withoutNewline = line.replace(/\r?\n$/, "").trim();
  return withoutNewline.length >= fence.length &&
    [...withoutNewline].every((character) => character === fence.character);
}

function inlineCodeRanges(markdown) {
  const fenced = fencedCodeRanges(markdown, "translation");
  const ranges = [];
  let fenceIndex = 0;
  let index = 0;
  while (index < markdown.length) {
    const protectedRange = fenced[fenceIndex];
    if (protectedRange && index >= protectedRange.start) {
      index = protectedRange.end;
      fenceIndex += 1;
      continue;
    }
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
    ranges.push({ start: index, end, value: markdown.slice(index, end) });
    index = end;
  }
  return ranges;
}

function linkDestinationRanges(markdown) {
  const protectedRanges = [...fencedCodeRanges(markdown, "translation"), ...inlineCodeRanges(markdown)]
    .sort((left, right) => left.start - right.start);
  const visible = maskRanges(markdown, protectedRanges);
  const pattern = /!?\[[^\]]*\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/g;
  const ranges = [];
  for (const match of visible.matchAll(pattern)) {
    const marker = match[0].indexOf("](") + 2;
    const localStart = match[0].indexOf(match[1], marker);
    const start = match.index + localStart;
    ranges.push({ start, end: start + match[1].length, value: markdown.slice(start, start + match[1].length) });
  }
  for (const match of visible.matchAll(/^[\t ]{0,3}\[(?!\^)[^\]\n]+\]:[\t ]*(<[^>\n]+>|\S+)/gm)) {
    const localStart = match[0].lastIndexOf(match[1]);
    const start = match.index + localStart;
    ranges.push({ start, end: start + match[1].length, value: markdown.slice(start, start + match[1].length) });
  }
  for (const match of visible.matchAll(/<(https?:\/\/[^>\n]+|mailto:[^>\n]+|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+)>/g)) {
    const localStart = match[0].indexOf(match[1]);
    const start = match.index + localStart;
    ranges.push({ start, end: start + match[1].length, value: markdown.slice(start, start + match[1].length) });
  }
  return ranges.sort((left, right) => left.start - right.start);
}

function inlineLinkKinds(markdown) {
  const visible = maskCode(markdown);
  return [...visible.matchAll(/(!?)\[[^\]]*\]\(\s*(?:<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/g)]
    .map((match) => match[1] ? "image" : "link");
}

function referenceLinkShapes(markdown) {
  const visible = maskCode(markdown);
  const shapes = [];
  for (const match of visible.matchAll(/(!?)\[([^\]]+)\]\[([^\]]*)\]/g)) {
    shapes.push(`${match[1] ? "image" : "link"}:${match[3] ? "full" : "collapsed"}`);
  }
  for (const match of visible.matchAll(/^[\t ]{0,3}\[(?!\^)([^\]\n]+)\]:[\t ]*(?:<[^>\n]+>|\S+)/gm)) {
    shapes.push(`definition:${normalizeReferenceLabel(match[1])}`);
  }
  return shapes;
}

function normalizeReferenceLabel(label) {
  return label.trim().replace(/[\t ]+/g, " ").toLowerCase();
}

function rawHtmlRanges(markdown) {
  const protectedRanges = [...fencedCodeRanges(markdown, "translation"), ...inlineCodeRanges(markdown)]
    .sort((left, right) => left.start - right.start);
  const visible = maskRanges(markdown, protectedRanges);
  const ranges = [];
  const pattern = /<!--[\s\S]*?-->|<\/?(?!https?:\/\/|mailto:)[A-Za-z][^>\n]*>|<![A-Z][^>\n]*>|<\?[^>\n]*\?>/g;
  for (const match of visible.matchAll(pattern)) {
    ranges.push({ start: match.index, end: match.index + match[0].length, value: markdown.slice(match.index, match.index + match[0].length) });
  }
  return ranges;
}

function footnoteShapes(markdown) {
  const visible = maskCode(markdown);
  const shapes = [];
  for (const match of visible.matchAll(/^[\t ]{0,3}\[\^([^\]\n]+)\]:/gm)) shapes.push(`definition:${match[1]}`);
  for (const match of visible.matchAll(/\[\^([^\]\n]+)\](?!:)/g)) shapes.push(`reference:${match[1]}`);
  return shapes;
}

function setextHeadingLevels(markdown) {
  const lines = maskCode(markdown).split(/\r?\n/);
  const levels = [];
  for (let index = 1; index < lines.length; index += 1) {
    if (!lines[index - 1].trim()) continue;
    if (/^[\t ]{0,3}=+[\t ]*$/.test(lines[index])) levels.push(1);
    else if (/^[\t ]{0,3}-{2,}[\t ]*$/.test(lines[index])) levels.push(2);
  }
  return levels;
}

function hardBreakEntries(markdown) {
  const protectedRanges = [
    ...fencedCodeRanges(markdown, "translation"),
    ...inlineCodeRanges(markdown),
  ].sort((left, right) => left.start - right.start);
  const entries = [];
  let protectedIndex = 0;
  let blockIndex = -1;
  let lineIndex = -1;
  let inBlock = false;
  let fence = null;

  for (const line of linesWithOffsets(markdown)) {
    const withoutNewline = line.text.replace(/\r?\n$/, "");
    if (!fence && /^\s*$/.test(withoutNewline)) {
      inBlock = false;
      lineIndex = -1;
      continue;
    }
    if (!inBlock) {
      blockIndex += 1;
      lineIndex = 0;
      inBlock = true;
    } else {
      lineIndex += 1;
    }

    if (fence) {
      if (isClosingFence(line.text, fence)) fence = null;
      continue;
    }
    const openedFence = openingFence(line.text);
    if (openedFence) {
      fence = openedFence;
      continue;
    }

    let kind;
    let start;
    const trailingSpaces = withoutNewline.match(/ {2,}$/)?.[0];
    if (trailingSpaces) {
      kind = "spaces";
      start = line.start + withoutNewline.length - trailingSpaces.length;
    } else {
      const trailingBackslashes = withoutNewline.match(/\\+$/)?.[0];
      if (trailingBackslashes && trailingBackslashes.length % 2 === 1) {
        kind = "backslash";
        start = line.start + withoutNewline.length - 1;
      }
    }
    if (!kind) continue;

    while (protectedRanges[protectedIndex]?.end <= start) protectedIndex += 1;
    const protectedRange = protectedRanges[protectedIndex];
    if (protectedRange && protectedRange.start <= start && start < protectedRange.end) continue;
    entries.push({
      blockIndex,
      lineIndex,
      kind,
      start,
      end: line.start + withoutNewline.length,
    });
  }
  return entries;
}

function hardBreakPositionKey(entry) {
  return `${entry.blockIndex}:${entry.lineIndex}:${entry.kind}`;
}

function headingLevels(markdown) {
  const visible = maskCode(markdown);
  return [...visible.matchAll(/^[\t ]{0,3}(#{1,6})(?:[\t ]+|$)/gm)].map((match) => match[1].length);
}

function listMarkers(markdown) {
  const visible = maskCode(markdown);
  const markers = [];
  for (const line of visible.split(/\r?\n/)) {
    const match = line.match(/^([\t ]*(?:>[\t ]*)*)([-+*]|\d+[.)])[\t ]+(\[[ xX]\][\t ]+)?/);
    if (!match) continue;
    const indentation = match[1].replace(/[^\t >]/g, "");
    markers.push(`${indentation}:${match[2]}:${match[3]?.trim() || ""}`);
  }
  return markers;
}

function tableShapes(markdown) {
  const lines = maskCode(markdown).split(/\r?\n/);
  const tables = [];
  for (let index = 1; index < lines.length; index += 1) {
    const delimiter = tableCells(lines[index]);
    const header = tableCells(lines[index - 1]);
    if (!delimiter || !header || delimiter.length !== header.length || !delimiter.every(isDelimiterCell)) continue;
    const rows = [header.length, delimiter.map(delimiterAlignment).join(",")];
    let rowIndex = index + 1;
    while (rowIndex < lines.length) {
      const cells = tableCells(lines[rowIndex]);
      if (!cells) break;
      rows.push(cells.length);
      rowIndex += 1;
    }
    tables.push(JSON.stringify(rows));
    index = rowIndex - 1;
  }
  return tables;
}

function markdownBlockShapes(markdown) {
  const ranges = fencedCodeRanges(markdown, "translation");
  let collapsed = "";
  let cursor = 0;
  for (const [index, range] of ranges.entries()) {
    collapsed += markdown.slice(cursor, range.start);
    collapsed += `\nPAKPERK_CODE_BLOCK_${index + 1}\n`;
    cursor = range.end;
  }
  collapsed += markdown.slice(cursor);

  return collapsed
    .trim()
    .split(/\r?\n[\t ]*\r?\n/)
    .filter(Boolean)
    .map((block) => {
      const trimmed = block.trim();
      const heading = trimmed.match(/^(#{1,6})(?:[\t ]+|$)/);
      if (heading) return `heading:${heading[1].length}`;
      if (/^PAKPERK_CODE_BLOCK_\d+$/.test(trimmed)) return "code";
      if (/^(?:[\t ]*>)/.test(trimmed)) return "quote";
      if (/^(?:[\t ]*)(?:[-+*]|\d+[.)])[\t ]+/.test(trimmed)) return "list";
      if (trimmed.split(/\r?\n/).some((line) => tableCells(line)?.every(isDelimiterCell))) return "table";
      return "prose";
    });
}

function tableCells(line) {
  let value = line.trim();
  if (!value.includes("|")) return null;
  if (value.startsWith("|")) value = value.slice(1);
  if (/(?<!\\)\|$/.test(value)) value = value.slice(0, -1);
  const cells = value.split(/(?<!\\)\|/).map((cell) => cell.trim());
  return cells.length > 1 ? cells : null;
}

function isDelimiterCell(cell) {
  return /^:?-{3,}:?$/.test(cell);
}

function delimiterAlignment(cell) {
  return `${cell.startsWith(":") ? "l" : ""}${cell.endsWith(":") ? "r" : ""}` || "none";
}

function technicalNumbers(markdown) {
  return maskCode(markdown).match(/\d+(?:[._:/+-]\d+)*%?/g) || [];
}

function technicalNumberRanges(markdown, label) {
  const protectedRanges = [
    ...fencedCodeRanges(markdown, label),
    ...inlineCodeRanges(markdown),
    ...linkDestinationRanges(markdown),
    ...rawHtmlRanges(markdown),
  ].sort((left, right) => left.start - right.start);
  const visible = maskRanges(markdown, protectedRanges);
  return [...visible.matchAll(/\d+(?:[._:/+-]\d+)*%?/g)].map((match) => ({
    start: match.index,
    end: match.index + match[0].length,
    value: match[0],
  }));
}

function maskCode(markdown) {
  const ranges = [...fencedCodeRanges(markdown, "translation"), ...inlineCodeRanges(markdown)]
    .sort((left, right) => left.start - right.start);
  return maskRanges(markdown, ranges);
}

function maskRanges(value, ranges) {
  let masked = "";
  let cursor = 0;
  for (const range of ranges) {
    masked += value.slice(cursor, range.start);
    masked += value.slice(range.start, range.end).replace(/[^\r\n]/g, " ");
    cursor = range.end;
  }
  return masked + value.slice(cursor);
}

function linesWithOffsets(value) {
  const lines = [];
  for (const match of value.matchAll(/.*(?:\r?\n|$)/g)) {
    if (!match[0]) continue;
    lines.push({ text: match[0], start: match.index, end: match.index + match[0].length });
  }
  return lines;
}
