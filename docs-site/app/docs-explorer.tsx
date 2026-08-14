"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { docs as documents } from "./generated/docs";

type Document = (typeof documents)[number];
type Language = "en" | "zh";
type DocumentContent = { id: string; html: string; htmlZh: string };

const copy = {
  en: {
    library: "Documentation library",
    search: "Search all documentation",
    searchHint: "Search titles, guides, runbooks, and API terms",
    shortcut: "Press / to search",
    contents: "On this page",
    minutes: "min read",
    words: "words",
    source: "Repository source",
    synced: "Source synchronized",
    openMenu: "Open document navigation",
    closeMenu: "Close document navigation",
    noResults: "No documents found",
    noResultsHint: "Try a product name, protocol, or operational phrase.",
    previous: "Previous",
    next: "Next",
    translationNote: "Chinese translation",
    translationBody:
      "The Chinese edition is generated locally for navigation and understanding. The English repository source remains authoritative for implementation and release decisions.",
    docsCount: "documents",
    intro: "Build, operate, and ship Pakperk with the decision trail intact.",
    kicker: "One source of truth",
    searchResults: "Search results",
    clear: "Clear search",
    top: "Back to top",
  },
  zh: {
    library: "文档库",
    search: "搜索全部文档",
    searchHint: "搜索标题、指南、运维手册和 API 术语",
    shortcut: "按 / 开始搜索",
    contents: "本页目录",
    minutes: "分钟阅读",
    words: "词",
    source: "仓库源文档",
    synced: "已与源文档同步",
    openMenu: "打开文档导航",
    closeMenu: "关闭文档导航",
    noResults: "未找到文档",
    noResultsHint: "请尝试产品名称、协议名或运维关键词。",
    previous: "上一篇",
    next: "下一篇",
    translationNote: "中文翻译说明",
    translationBody:
      "中文版由本地模型生成，用于导航与理解。涉及实现、合规与发布决策时，请以英文仓库源文档为准。",
    docsCount: "篇文档",
    intro: "带着完整的决策脉络，构建、运维并发布 Pakperk。",
    kicker: "唯一事实来源",
    searchResults: "搜索结果",
    clear: "清除搜索",
    top: "返回顶部",
  },
} as const;

export function DocsExplorer({ initialContent }: { initialContent: DocumentContent }) {
  const [language, setLanguage] = useState<Language>("en");
  const [selectedId, setSelectedId] = useState("developer-guide");
  const [content, setContent] = useState<DocumentContent>(initialContent);
  const [query, setQuery] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const articleRef = useRef<HTMLElement>(null);
  const contentCache = useRef(new Map([[initialContent.id, initialContent]]));
  const t = copy[language];

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const requestedLanguage = params.get("lang");
    const storedLanguage = window.localStorage.getItem("pakperk-docs-language");
    if (requestedLanguage === "zh" || (!requestedLanguage && storedLanguage === "zh")) {
      setLanguage("zh");
    }
    const requestedDoc = params.get("doc");
    if (requestedDoc && documents.some((document) => document.id === requestedDoc)) {
      setSelectedId(requestedDoc);
    }
    const section = params.get("section");
    if (section) requestAnimationFrame(() => document.getElementById(section)?.scrollIntoView());

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
    window.addEventListener("keydown", handleShortcut);
    return () => window.removeEventListener("keydown", handleShortcut);
  }, [documents]);

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
        if (!cancelled) setContent({ id: selectedId, html: "<p>Document unavailable.</p>", htmlZh: "<p>文档暂时无法加载。</p>" });
      });
    return () => { cancelled = true; };
  }, [content.id, selectedId]);

  const selectedDocument =
    documents.find((document) => document.id === selectedId) || documents[0];

  const filteredDocuments = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase(language === "zh" ? "zh-CN" : "en-US");
    if (!normalized) return documents;
    return documents.filter((document) => {
      const haystack = language === "zh"
        ? `${document.titleZh} ${document.summaryZh} ${document.path}`
        : `${document.title} ${document.summary} ${document.path}`;
      return haystack.toLocaleLowerCase(language === "zh" ? "zh-CN" : "en-US").includes(normalized);
    });
  }, [documents, language, query]);

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

  function selectDocument(id: string, section?: string) {
    setSelectedId(id);
    setMenuOpen(false);
    setQuery("");
    const params = new URLSearchParams(window.location.search);
    params.set("doc", id);
    params.set("lang", language);
    if (section) params.set("section", section);
    else params.delete("section");
    window.history.replaceState(null, "", `?${params.toString()}`);
    requestAnimationFrame(() => {
      if (section) document.getElementById(section)?.scrollIntoView({ behavior: "smooth" });
      else window.scrollTo({ top: 0, behavior: "smooth" });
    });
  }

  function switchLanguage() {
    const nextLanguage = language === "en" ? "zh" : "en";
    setLanguage(nextLanguage);
    window.localStorage.setItem("pakperk-docs-language", nextLanguage);
    const params = new URLSearchParams(window.location.search);
    params.set("lang", nextLanguage);
    params.set("doc", selectedDocument.id);
    window.history.replaceState(null, "", `?${params.toString()}`);
  }

  function handleArticleClick(event: React.MouseEvent<HTMLElement>) {
    const target = event.target as HTMLElement;
    const link = target.closest<HTMLAnchorElement>("a[data-doc-link]");
    if (!link) return;
    event.preventDefault();
    selectDocument(link.dataset.docLink || "", link.dataset.docSection);
  }

  return (
    <div className="docs-shell" lang={language === "zh" ? "zh-CN" : "en"}>
      <a className="skip-link" href="#document-content">Skip to document</a>
      <header className="topbar">
        <button
          className="menu-button"
          type="button"
          aria-label={menuOpen ? t.closeMenu : t.openMenu}
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen((open) => !open)}
        >
          <span aria-hidden="true">{menuOpen ? "×" : "≡"}</span>
        </button>
        <a className="wordmark" href="/" aria-label="Pakperk Docs home">
          <span className="mark" aria-hidden="true">P</span>
          <span>Pakperk</span>
          <span className="wordmark-divider">/</span>
          <span className="wordmark-section">Docs</span>
        </a>
        <div className="header-meta">
          <span className="sync-indicator"><i />{t.synced}</span>
          <button
            className="language-switch"
            type="button"
            role="switch"
            aria-checked={language === "zh"}
            aria-label="Switch between English and Simplified Chinese"
            onClick={switchLanguage}
          >
            <span className={language === "en" ? "active" : ""}>EN</span>
            <b aria-hidden="true" />
            <span className={language === "zh" ? "active" : ""}>中文</span>
          </button>
        </div>
      </header>

      <aside className={`sidebar ${menuOpen ? "is-open" : ""}`} aria-label={t.library}>
        <div className="sidebar-intro">
          <span className="eyebrow">{t.kicker}</span>
          <p>{t.intro}</p>
          <span className="doc-total">{documents.length} {t.docsCount}</span>
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
          />
          {query ? (
            <button type="button" onClick={() => setQuery("")} aria-label={t.clear}>×</button>
          ) : <kbd>/</kbd>}
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
                        <span>{language === "zh" ? document.titleZh : document.title}</span>
                        <small>{document.path}</small>
                      </button>
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
          {!filteredDocuments.length && (
            <div className="empty-search">
              <strong>{t.noResults}</strong>
              <p>{t.noResultsHint}</p>
            </div>
          )}
        </nav>
      </aside>

      {menuOpen && <button className="sidebar-scrim" aria-label={t.closeMenu} onClick={() => setMenuOpen(false)} />}

      <main className="document-stage" id="document-content">
        <article ref={articleRef} className="document" onClick={handleArticleClick}>
          <header className="document-header">
            <div className="document-path">
              <span>{language === "zh" ? selectedDocument.categoryLabel.zh : selectedDocument.categoryLabel.en}</span>
              <i>/</i>
              <code>{selectedDocument.path}</code>
            </div>
            <h1>{language === "zh" ? selectedDocument.titleZh : selectedDocument.title}</h1>
            <p className="document-summary">
              {language === "zh" ? selectedDocument.summaryZh : selectedDocument.summary}
            </p>
            <div className="document-facts" aria-label="Document metadata">
              <span><i className="fact-dot" />{selectedDocument.readingMinutes} {t.minutes}</span>
              <span>{selectedDocument.wordCount.toLocaleString(language === "zh" ? "zh-CN" : "en-US")} {t.words}</span>
              <a href={`https://github.com/ErrDivine/PakPerk/blob/main/docs/${selectedDocument.path}`} target="_blank" rel="noreferrer">{t.source} ↗</a>
            </div>
          </header>

          {language === "zh" && (
            <aside className="translation-note">
              <span aria-hidden="true">译</span>
              <div><strong>{t.translationNote}</strong><p>{t.translationBody}</p></div>
            </aside>
          )}

          <div
            className="prose"
            aria-busy={content.id !== selectedDocument.id}
            dangerouslySetInnerHTML={{
              __html: content.id === selectedDocument.id
                ? (language === "zh" ? content.htmlZh : content.html)
                : `<p class="document-loading">${language === "zh" ? "正在加载文档…" : "Loading document…"}</p>`,
            }}
          />

          <nav className="page-turner" aria-label="Adjacent documents">
            {previousDocument ? (
              <button type="button" onClick={() => selectDocument(previousDocument.id)}>
                <small>← {t.previous}</small>
                <strong>{language === "zh" ? previousDocument.titleZh : previousDocument.title}</strong>
              </button>
            ) : <span />}
            {nextDocument ? (
              <button type="button" className="next" onClick={() => selectDocument(nextDocument.id)}>
                <small>{t.next} →</small>
                <strong>{language === "zh" ? nextDocument.titleZh : nextDocument.title}</strong>
              </button>
            ) : <span />}
          </nav>
        </article>

        <aside className="toc" aria-label={t.contents}>
          <span className="toc-label">{t.contents}</span>
          <ol>
            {toc.map((item) => (
              <li key={`${item.id}-${item.label}`} className={item.level === 3 ? "nested" : ""}>
                <a href={`#${item.id}`}>{item.label}</a>
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
