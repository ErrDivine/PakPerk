import assert from "node:assert/strict";
import test from "node:test";
import { resolveDocsLocation } from "../app/navigation-state.mjs";

const documentIds = new Set(["developer-guide", "backend-deployment"]);

test("restores the default document when an older history entry has no doc parameter", () => {
  assert.deepEqual(
    resolveDocsLocation("", "en", "developer-guide", documentIds),
    { language: "en", selectedId: "developer-guide", section: null },
  );
});

test("uses the stored language when the URL does not override it", () => {
  assert.deepEqual(
    resolveDocsLocation("?doc=backend-deployment", "zh", "developer-guide", documentIds),
    { language: "zh", selectedId: "backend-deployment", section: null },
  );
});

test("honors explicit language and section state and rejects an unknown document", () => {
  assert.deepEqual(
    resolveDocsLocation("?doc=unknown&lang=en&section=verify", "zh", "developer-guide", documentIds),
    { language: "en", selectedId: "developer-guide", section: "verify" },
  );
});
