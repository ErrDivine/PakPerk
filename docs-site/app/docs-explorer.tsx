"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { DocumentMetadata, TranslationStatus } from "./document-types";
import { docs as generatedDocuments } from "./generated/docs";
import { resolveDocsLocation } from "./navigation-state.mjs";

const documents: readonly DocumentMetadata[] = generatedDocuments;
const documentIds = new Set(documents.map((document) => document.id));
type Document = DocumentMetadata;
type Language = "en" | "zh";
type DocumentContent = { id: string; html: string; htmlZh: string };

const copy = {
  en: {
    library: "Documentation library",
    search: "Find a document",
    searchHint: "Search titles, summaries, and file paths",
    shortcut: "Press / to search",
    skip: "Skip to document",
    contents: "On this page",
    readingTime: (minutes: number) => `${minutes} min read`,
    wordCount: (words: string) => `${words} words`,
    source: "Repository source",
    synced: "Built from repository docs",
    openMenu: "Open document navigation",
    closeMenu: "Close document navigation",
    noResults: "No documents found",
    noResultsHint: "Try a product name, protocol, or operational phrase.",
    previous: "Previous",
    next: "Next",
    translationNote: "Source-matched Chinese translation",
    translationBody:
      "This locally generated translation is recorded against the current English source. Use the English repository document for implementation, compliance, and release decisions.",
    fallbackNote: "English fallback",
    fallbackBody:
      "A source-matched Chinese translation is not available yet, so this page shows the authoritative English document.",
    staleNote: "English fallback: translation out of date",
    staleBody:
      "The checked-in Chinese translation does not match this exact English source revision. The site is showing English rather than presenting stale guidance as current.",
    unverifiedNote: "English fallback: translation not verified",
    unverifiedBody:
      "A Chinese file exists, but it has no digest record tying it to this exact English source. The site shows English until the translation is regenerated.",
    invalidNote: "English fallback: translation validation failed",
    invalidBody:
      "The Chinese file did not pass structural or terminology-quality checks. The site shows the authoritative English source instead.",
    documentCount: (count: number) => `${count} documents`,
    intro: "Start locally, test on a real phone, or deploy Pakperk with the implementation context intact.",
    kicker: "Implementation-linked",
    searchResults: "Search results",
    clear: "Clear search",
    top: "Back to top",
    languageSwitch: "Switch between English and Simplified Chinese",
    home: "Pakperk Docs home",
    metadata: "Document details",
    adjacent: "Adjacent documents",
  },
  zh: {
    library: "文档库",
    search: "查找文档",
    searchHint: "搜索标题、摘要和文件路径",
    shortcut: "按 / 开始搜索",
    skip: "跳到文档正文",
    contents: "本页目录",
    readingTime: (minutes: number) => `预计阅读 ${minutes} 分钟`,
    wordCount: (words: string) => `英文原文 ${words} 个单词`,
    source: "仓库源文档",
    synced: "由仓库文档生成",
    openMenu: "打开文档导航",
    closeMenu: "关闭文档导航",
    noResults: "未找到文档",
    noResultsHint: "请尝试产品名称、协议名或运维关键词。",
    previous: "上一篇",
    next: "下一篇",
    translationNote: "与当前源文档匹配的中文翻译",
    translationBody:
      "这份本地生成的翻译已绑定当前英文源文档。涉及实现、合规与发布决策时，请以英文仓库文档为准。",
    fallbackNote: "显示英文源文档",
    fallbackBody:
      "此页面暂时没有与当前源文档匹配的中文翻译，因此显示权威英文版本。",
    staleNote: "显示英文源文档：中文翻译已过期",
    staleBody:
      "仓库中的中文翻译与当前英文源文档版本不一致。本站选择显示英文，而不会把过期指引标为最新内容。",
    unverifiedNote: "显示英文源文档：中文翻译尚未验证",
    unverifiedBody:
      "仓库中存在中文文件，但没有哈希摘要记录可证明它对应当前英文源文档。重新生成翻译前，本站会显示英文。",
    invalidNote: "显示英文源文档：中文翻译未通过校验",
    invalidBody:
      "中文文件未通过结构或术语质量校验，因此本站改为显示权威英文源文档。",
    documentCount: (count: number) => `${count} 篇文档`,
    intro: "从本地开发开始，在真机上测试，或在保留实现背景的前提下部署 Pakperk。",
    kicker: "与实现同步",
    searchResults: "搜索结果",
    clear: "清除搜索",
    top: "返回顶部",
    languageSwitch: "在英文和简体中文之间切换",
    home: "Pakperk 文档首页",
    metadata: "文档信息",
    adjacent: "相邻文档",
  },
} as const;

type Copy = (typeof copy)[Language];

export function DocsExplorer({
  initialContent,
  initialLanguage,
}: {
  initialContent: DocumentContent;
  initialLanguage: Language;
}) {
  const [language, setLanguage] = useState<Language>(initialLanguage);
  const [selectedId, setSelectedId] = useState(initialContent.id);
  const [content, setContent] = useState<DocumentContent>(initialContent);
  const [query, setQuery] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [pendingSection, setPendingSection] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const articleRef = useRef<HTMLElement>(null);
  const contentCache = useRef(new Map([[initialContent.id, initialContent]]));
  const t = copy[language];

  useEffect(() => {
    const applyLocation = () => {
      const storedLanguage = window.localStorage.getItem("pakperk-docs-language");
      const location = resolveDocsLocation(
        window.location.search,
        storedLanguage,
        initialContent.id,
        documentIds,
      );
      window.localStorage.setItem("pakperk-docs-language", location.language);
      setLanguage(location.language);
      setSelectedId(location.selectedId);
      setPendingSection(location.section);
    };
    const initializationFrame = requestAnimationFrame(applyLocation);
    const handlePopState = () => applyLocation();

    const handleShortcut = (event: KeyboardEvent) => {
      if (event.key === "/" && !isTypingTarget(event.target)) {
        event.preventDefault();
        searchRef.current?.focus();
      }
      if (event.key === "Escape") {
        setMenuOpen(false);
        searchRef.current?.blur();
      }
    };
    window.addEventListener("popstate", handlePopState);
    window.addEventListener("keydown", handleShortcut);
    return () => {
      cancelAnimationFrame(initializationFrame);
      window.removeEventListener("popstate", handlePopState);
      window.removeEventListener("keydown", handleShortcut);
    };
  }, [initialContent.id]);

  useEffect(() => {
    if (content.id === selectedId) return;
    const cached = contentCache.current.get(selectedId);
    if (cached) {
      setContent(cached);
      return;
    }
    const selected = documents.find((document) => document.id === selectedId);
    if (!selected) return;
    let cancelled = false;
    fetch(selected.dataUrl)
      .then((response) => {
        if (!response.ok) throw new Error(`Document request failed with ${response.status}`);
        return response.json() as Promise<DocumentContent>;
      })
      .then((loaded) => {
        contentCache.current.set(loaded.id, loaded);
        if (!cancelled) setContent(loaded);
      })
      .catch(() => {
        if (!cancelled) {
          setContent({
            id: selectedId,
            html: '<p role="alert" lang="en">Document unavailable.</p>',
            htmlZh: '<p role="alert" lang="zh-CN">文档暂时无法加载。</p>',
          });
        }
      });
    return () => { cancelled = true; };
  }, [content.id, selectedId]);

  const selectedDocument =
    documents.find((document) => document.id === selectedId) || documents[0];

  useEffect(() => {
    document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
    document.title = `${language === "zh" ? selectedDocument.titleZh : selectedDocument.title} — ${language === "zh" ? "Pakperk 文档" : "Pakperk Docs"}`;
    const description = document.querySelector<HTMLMetaElement>('meta[name="description"]');
    if (description) {
      description.content = language === "zh" ? selectedDocument.summaryZh : selectedDocument.summary;
    }
  }, [language, selectedDocument]);

  useEffect(() => {
    if (!pendingSection || content.id !== selectedDocument.id) return;
    const frame = requestAnimationFrame(() => {
      document.getElementById(pendingSection)?.scrollIntoView({ behavior: "smooth" });
      setPendingSection(null);
    });
    return () => cancelAnimationFrame(frame);
  }, [content.id, language, pendingSection, selectedDocument.id]);

  const filteredDocuments = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase(language === "zh" ? "zh-CN" : "en-US");
    if (!normalized) return documents;
    return documents.filter((document) => {
      const haystack = [
        document.title,
        document.summary,
        document.titleZh,
        document.summaryZh,
        document.path,
      ].join(" ");
      return haystack.toLocaleLowerCase(language === "zh" ? "zh-CN" : "en-US").includes(normalized);
    });
  }, [language, query]);

  const groupedDocuments = useMemo(() => {
    const groups = new Map<string, Document[]>();
    for (const document of filteredDocuments) {
      const current = groups.get(document.category) || [];
      current.push(document);
      groups.set(document.category, current);
    }
    return [...groups.entries()];
  }, [filteredDocuments]);

  const selectedIndex = documents.findIndex((document) => document.id === selectedDocument.id);
  const previousDocument = selectedIndex > 0 ? documents[selectedIndex - 1] : undefined;
  const nextDocument = selectedIndex < documents.length - 1 ? documents[selectedIndex + 1] : undefined;
  const toc = language === "zh" ? selectedDocument.tocZh : selectedDocument.toc;
  const translationMessage = translationMessageFor(selectedDocument.translationStatus, t);
  const selectedTitleLanguage = documentTitleLanguage(language, selectedDocument.translationStatus);

  const selectDocument = useCallback((id: string, section?: string) => {
    setSelectedId(id);
    setPendingSection(section || null);
    setMenuOpen(false);
    setQuery("");
    const params = new URLSearchParams(window.location.search);
    params.set("doc", id);
    params.set("lang", language);
    if (section) params.set("section", section);
    else params.delete("section");
    window.history.pushState(null, "", `?${params.toString()}`);
    if (!section) requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: "smooth" }));
  }, [language]);

  useEffect(() => {
    const article = articleRef.current;
    if (!article) return;

    const handleArticleClick = (event: MouseEvent) => {
      const target = event.target as HTMLElement;
      const link = target.closest<HTMLAnchorElement>("a[data-doc-link]");
      if (!link) return;
      event.preventDefault();
      selectDocument(link.dataset.docLink || "", link.dataset.docSection);
    };

    article.addEventListener("click", handleArticleClick);
    return () => article.removeEventListener("click", handleArticleClick);
  }, [selectDocument]);

  function switchLanguage() {
    const nextLanguage = language === "en" ? "zh" : "en";
    setLanguage(nextLanguage);
    window.localStorage.setItem("pakperk-docs-language", nextLanguage);
    const params = new URLSearchParams(window.location.search);
    params.set("lang", nextLanguage);
    params.set("doc", selectedDocument.id);
    window.history.replaceState(null, "", `?${params.toString()}`);
  }

  return (
    <div className="docs-shell" lang={language === "zh" ? "zh-CN" : "en"}>
      <a className="skip-link" href="#document-content">{t.skip}</a>
      <header className="topbar">
        <button
          className="menu-button"
          type="button"
          aria-label={menuOpen ? t.closeMenu : t.openMenu}
          aria-expanded={menuOpen}
          aria-controls="document-navigation"
          onClick={() => setMenuOpen((open) => !open)}
        >
          <span aria-hidden="true">{menuOpen ? "×" : "≡"}</span>
        </button>
        <Link className="wordmark" href={`/?lang=${language}`} aria-label={t.home}>
          <span className="mark" aria-hidden="true">P</span>
          <span>Pakperk</span>
          <span className="wordmark-divider">/</span>
          <span className="wordmark-section">Docs</span>
        </Link>
        <div className="header-meta">
          <span className="sync-indicator"><i />{t.synced}</span>
          <button
            className="language-switch"
            type="button"
            role="switch"
            aria-checked={language === "zh"}
            aria-label={t.languageSwitch}
            onClick={switchLanguage}
          >
            <span className={language === "en" ? "active" : ""} lang="en">EN</span>
            <b aria-hidden="true" />
            <span className={language === "zh" ? "active" : ""} lang="zh-CN">中文</span>
          </button>
        </div>
      </header>

      <aside id="document-navigation" className={`sidebar ${menuOpen ? "is-open" : ""}`} aria-label={t.library}>
        <div className="sidebar-intro">
          <span className="eyebrow">{t.kicker}</span>
          <p>{t.intro}</p>
          <span className="doc-total">{t.documentCount(documents.length)}</span>
        </div>
        <label className="search-box">
          <span className="visually-hidden">{t.search}</span>
          <span aria-hidden="true" className="search-icon">⌕</span>
          <input
            ref={searchRef}
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t.searchHint}
            autoComplete="off"
            aria-keyshortcuts="/"
          />
          {query ? (
            <button type="button" onClick={() => setQuery("")} aria-label={t.clear}>×</button>
          ) : <kbd title={t.shortcut} aria-hidden="true">/</kbd>}
        </label>

        <nav className="document-nav" aria-label={query ? t.searchResults : t.library}>
          {groupedDocuments.map(([category, categoryDocuments]) => {
            const categoryLabel = categoryDocuments[0].categoryLabel;
            return (
              <section className="nav-group" key={category}>
                <h2>{language === "zh" ? categoryLabel.zh : categoryLabel.en}</h2>
                <ul>
                  {categoryDocuments.map((document) => (
                    <li key={document.id}>
                      <button
                        type="button"
                        className={selectedDocument.id === document.id ? "selected" : ""}
                        aria-current={selectedDocument.id === document.id ? "page" : undefined}
                        onClick={() => selectDocument(document.id)}
                      >
                        <span lang={documentTitleLanguage(language, document.translationStatus)}>
                          {language === "zh" ? document.titleZh : document.title}
                        </span>
                        <small>{document.path}</small>
                      </button>
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
          {!filteredDocuments.length && (
            <div className="empty-search" role="status">
              <strong>{t.noResults}</strong>
              <p>{t.noResultsHint}</p>
            </div>
          )}
        </nav>
      </aside>

      {menuOpen && <button className="sidebar-scrim" aria-label={t.closeMenu} onClick={() => setMenuOpen(false)} />}

      <main className="document-stage" id="document-content">
        <article ref={articleRef} className="document">
          <header className="document-header">
            <div className="document-path">
              <span>{language === "zh" ? selectedDocument.categoryLabel.zh : selectedDocument.categoryLabel.en}</span>
              <i>/</i>
              <code>{selectedDocument.path}</code>
            </div>
            <h1 lang={selectedTitleLanguage}>
              {language === "zh" ? selectedDocument.titleZh : selectedDocument.title}
            </h1>
            <p className="document-summary" lang={selectedTitleLanguage}>
              {language === "zh" ? selectedDocument.summaryZh : selectedDocument.summary}
            </p>
            <div className="document-facts" aria-label={t.metadata}>
              <span><i className="fact-dot" />{t.readingTime(selectedDocument.readingMinutes)}</span>
              <span>{t.wordCount(selectedDocument.wordCount.toLocaleString(language === "zh" ? "zh-CN" : "en-US"))}</span>
              <a href={`https://github.com/ErrDivine/PakPerk/blob/main/docs/${selectedDocument.path}`} target="_blank" rel="noreferrer">{t.source} ↗</a>
            </div>
          </header>

          {language === "zh" && translationMessage && (
            <aside className="translation-note">
              <span aria-hidden="true">译</span>
              <div><strong>{translationMessage.title}</strong><p>{translationMessage.body}</p></div>
            </aside>
          )}

          <div
            className="prose"
            lang={documentProseLanguage(language, selectedDocument.translationStatus)}
            aria-busy={content.id !== selectedDocument.id}
            dangerouslySetInnerHTML={{
              __html: content.id === selectedDocument.id
                ? (language === "zh" ? content.htmlZh : content.html)
                : `<p class="document-loading" role="status" lang="${language === "zh" ? "zh-CN" : "en"}">${language === "zh" ? "正在加载文档…" : "Loading document…"}</p>`,
            }}
          />

          <nav className="page-turner" aria-label={t.adjacent}>
            {previousDocument ? (
              <button type="button" onClick={() => selectDocument(previousDocument.id)}>
                <small>← {t.previous}</small>
                <strong lang={documentTitleLanguage(language, previousDocument.translationStatus)}>
                  {language === "zh" ? previousDocument.titleZh : previousDocument.title}
                </strong>
              </button>
            ) : <span />}
            {nextDocument ? (
              <button type="button" className="next" onClick={() => selectDocument(nextDocument.id)}>
                <small>{t.next} →</small>
                <strong lang={documentTitleLanguage(language, nextDocument.translationStatus)}>
                  {language === "zh" ? nextDocument.titleZh : nextDocument.title}
                </strong>
              </button>
            ) : <span />}
          </nav>
        </article>

        <aside className="toc" aria-label={t.contents}>
          <span className="toc-label">{t.contents}</span>
          <ol>
            {toc.map((item) => (
              <li key={`${item.id}-${item.label}`} className={item.level === 3 ? "nested" : ""}>
                <a href={`#${item.id}`} lang={selectedTitleLanguage}>{item.label}</a>
              </li>
            ))}
          </ol>
          <a className="back-to-top" href="#document-content">↑ {t.top}</a>
        </aside>
      </main>
    </div>
  );
}

function isTypingTarget(target: EventTarget | null) {
  return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement;
}

function translationMessageFor(status: TranslationStatus, text: Copy) {
  switch (status) {
    case "translated":
      return { title: text.translationNote, body: text.translationBody };
    case "missing":
      return { title: text.fallbackNote, body: text.fallbackBody };
    case "stale":
      return { title: text.staleNote, body: text.staleBody };
    case "unverified":
      return { title: text.unverifiedNote, body: text.unverifiedBody };
    case "invalid":
      return { title: text.invalidNote, body: text.invalidBody };
    case "source":
      return null;
    default:
      return assertNever(status);
  }
}

function documentTitleLanguage(language: Language, status: TranslationStatus) {
  return language === "zh" && (status === "translated" || status === "source") ? "zh-CN" : "en";
}

function documentProseLanguage(language: Language, status: TranslationStatus) {
  return language === "zh" && status === "translated" ? "zh-CN" : "en";
}

function assertNever(value: never): never {
  throw new Error(`Unhandled translation status: ${value}`);
}
