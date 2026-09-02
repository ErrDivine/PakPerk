# Pakperk documentation site

This Sites project turns the repository's authoritative `docs/` tree into a
searchable developer reader. It is separate from `site/`, the curated public
policy, support, deletion, and mobile-association site shipped with the app.
Internal architecture and operations material in this project does not become
part of that public release image.

## Requirements

- Node.js 22.13 or newer;
- npm using the checked-in lockfile; and
- Pandoc 3.9 on `PATH` for reproducible Markdown rendering.

Ollama is optional. It is needed only to generate Simplified Chinese
translations, and defaults to the local `qwen3:8b` model.

## Work locally

Install dependencies and generate the reader from the current repository docs:

```bash
npm ci
npm run sync-docs
npm run dev
```

Run the complete site check before handoff:

```bash
npm run lint
npm run typecheck:app
npm test
```

`npm test` is deliberately read-only with respect to checked-in documentation.
The build first runs `npm run check-docs`, which renders into a temporary
directory and compares that result with the checked-in generated files. It
fails with an instruction to run `npm run sync-docs` when the source and output
differ. It does not hide an outdated generated tree by rewriting it during the
test. The remaining tests reject missing or orphaned document data, verify
translation status and safe English fallback behavior, exercise translation
structure rules, and server-render the result.

## Edit the right files

Edit English documentation in `../docs/`. Do not hand-edit:

- `app/generated/docs.ts`;
- `app/generated/default-doc.ts`; or
- `public/docs-data/*.json`.

`npm run sync-docs` first renders every document into a temporary staging tree.
Only a complete successful render replaces the three generated outputs, and a
failed replacement is rolled back. Given the same source files, translation
manifest, Node dependencies, and Pandoc 3.9, it recreates the same output and
removes orphaned document data.

The checked-in Chinese Markdown lives in `content/zh/`. Translation generation
records the exact English source digest, translated-file digest, and an effective
policy digest in `content/zh/.source-digests.json`. The policy digest covers the
prompt, glossary, normalizer, structure validator, and quality validator, so a
relevant pipeline change makes older records stale automatically:

```bash
npm run translate-docs
npm run sync-docs
```

Translation runs validate heading levels, list markers, table shape, fenced and
inline code, multiline and reference-link destinations, hard breaks, technical
numbers, exact protected-name counts, obligation strength, and high-confidence
terminology failures before writing a file or digest record. Added raw HTML,
autolinks, footnotes, or unsupported link nodes are rejected. A translation that
later fails those checks is not published;
the reader marks it invalid and uses English. The generator renders the exact
translated file covered by the digest and does not modify numbers afterward.

If a translation is missing, was edited independently, or belongs to an older
English source revision, the reader shows the authoritative English document
and says why. It never labels a stale translation as current. English remains
authoritative for engineering, compliance, and release decisions.

## Build and publish

Create the deployable build only after generated documentation is current:

```bash
npm run check-docs
npm run build
```

`npm run build` repeats the read-only freshness check before invoking Vinext.
This repository intentionally has no `npm publish` or direct deployment script.
The `.openai/hosting.json` file declares Sites resource requirements; it does
not name a deployment destination. After `npm test`, `npm run lint`, and
`npm run typecheck:app` pass, the Site-owning Codex task publishes this existing
`docs-site/` project through the Sites publishing flow.
