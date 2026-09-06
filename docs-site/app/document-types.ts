export type TranslationStatus =
  | "translated"
  | "missing"
  | "unverified"
  | "stale"
  | "invalid"
  | "source";

export type DocumentCategory =
  | "guides"
  | "product"
  | "architecture"
  | "operations"
  | "delivery"
  | "policy";

export interface DocumentTocItem {
  readonly level: number;
  readonly id: string;
  readonly label: string;
}

export interface DocumentMetadata {
  readonly id: string;
  readonly path: string;
  readonly sourceSha256: string;
  readonly translationStatus: TranslationStatus;
  readonly category: DocumentCategory;
  readonly categoryLabel: { readonly en: string; readonly zh: string };
  readonly title: string;
  readonly titleZh: string;
  readonly summary: string;
  readonly summaryZh: string;
  readonly dataUrl: string;
  readonly wordCount: number;
  readonly readingMinutes: number;
  readonly toc: readonly DocumentTocItem[];
  readonly tocZh: readonly DocumentTocItem[];
}
