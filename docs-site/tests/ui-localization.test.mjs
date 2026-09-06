import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const explorerUrl = new URL("../app/docs-explorer.tsx", import.meta.url);
const stylesUrl = new URL("../app/globals.css", import.meta.url);
const layoutUrl = new URL("../app/layout.tsx", import.meta.url);
const pageUrl = new URL("../app/page.tsx", import.meta.url);

test("the language switch keeps browser semantics, navigation, and persistence in sync", async () => {
  const explorer = await readFile(explorerUrl, "utf8");

  assert.match(explorer, /document\.documentElement\.lang = language === "zh" \? "zh-CN" : "en"/);
  assert.match(explorer, /document\.title = `\$\{language === "zh"/);
  assert.match(explorer, /querySelector<HTMLMetaElement>\('meta\[name="description"\]'\)/);
  assert.match(explorer, /localStorage\.setItem\("pakperk-docs-language", location\.language\)/);
  assert.match(explorer, /href=\{`\/\?lang=\$\{language\}`\}/);
  assert.match(explorer, /aria-label=\{t\.home\}/);
  assert.match(explorer, /aria-label=\{t\.metadata\}/);
  assert.match(explorer, /aria-label=\{t\.adjacent\}/);
  assert.match(explorer, /aria-controls="document-navigation"/);
  assert.match(explorer, /id="document-navigation"/);
  assert.match(explorer, /lang="en">EN<\/span>/);
  assert.match(explorer, /lang="zh-CN">中文<\/span>/);
});

test("static metadata advertises the Chinese edition without mislabeling the default HTML", async () => {
  const [layout, page] = await Promise.all([
    readFile(layoutUrl, "utf8"),
    readFile(pageUrl, "utf8"),
  ]);

  assert.match(layout, /<html lang="en">/);
  assert.match(layout, /property="og:locale" content="en_US"/);
  assert.match(layout, /property="og:locale:alternate" content="zh_CN"/);
  assert.match(page, /source-matched Simplified Chinese translations when available/);
});

test("search indexes both languages and transient messages declare their language", async () => {
  const explorer = await readFile(explorerUrl, "utf8");

  assert.match(explorer, /document\.titleZh,[\s\S]*document\.summaryZh,[\s\S]*document\.path/);
  assert.match(explorer, /role="status" lang="\$\{language === "zh" \? "zh-CN" : "en"\}"/);
  assert.match(explorer, /htmlZh: '<p role="alert" lang="zh-CN">/);
});

test("the narrow layout hides the closed drawer from focus and stacks document paging", async () => {
  const styles = await readFile(stylesUrl, "utf8");
  const mobile = sliceBetween(styles, "@media (max-width: 820px)", "@media (max-width: 540px)");
  const narrow = sliceBetween(styles, "@media (max-width: 540px)", "@media (prefers-reduced-motion: reduce)");

  assert.match(mobile, /\.sidebar \{[^}]*transform: translateX\(-105%\)[^}]*visibility: hidden/);
  assert.match(mobile, /\.sidebar\.is-open \{[^}]*transform: translateX\(0\)[^}]*visibility: visible/);
  assert.match(mobile, /\.document-stage \{[^}]*margin-left: 0/);
  assert.match(narrow, /\.page-turner \{[^}]*grid-template-columns: 1fr/);
});

function sliceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `missing CSS marker: ${startMarker}`);
  assert.notEqual(end, -1, `missing CSS marker: ${endMarker}`);
  return source.slice(start, end);
}
