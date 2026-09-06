/**
 * Resolve browser URL state without retaining a document or language from a
 * newer history entry when the older entry omits those query parameters.
 *
 * @param {string} search
 * @param {string | null} storedLanguage
 * @param {string} defaultDocumentId
 * @param {ReadonlySet<string>} validDocumentIds
 * @returns {{ language: "en" | "zh"; selectedId: string; section: string | null }}
 */
export function resolveDocsLocation(search, storedLanguage, defaultDocumentId, validDocumentIds) {
  const params = new URLSearchParams(search);
  const requestedLanguage = params.get("lang");
  const requestedDocumentId = params.get("doc");
  const language = requestedLanguage === "zh" || (!requestedLanguage && storedLanguage === "zh")
    ? "zh"
    : "en";
  const selectedId = requestedDocumentId && validDocumentIds.has(requestedDocumentId)
    ? requestedDocumentId
    : defaultDocumentId;
  return { language, selectedId, section: params.get("section") };
}
