# Pakperk documentation site

This standalone Sites project publishes the repository's `docs/` tree as a
searchable, rustdoc-inspired reader. It deliberately lives beside the curated
public policy site in `site/`; internal architecture, release evidence, and
runbooks do not become part of that public release image.

The checked-in generated library contains both the English source and a local
Simplified Chinese translation. English remains authoritative for engineering,
compliance, and release decisions.

## Work locally

```bash
npm run translate-docs  # refresh Chinese files with the local Ollama model
npm run sync-docs       # render docs into app/generated/docs.ts with Pandoc
npm run dev
npm test
```

`npm run sync-docs` falls back to English for a document whose Chinese source
has not been generated yet, so UI work never depends on translation progress.
