import type { Metadata } from "next";
import { defaultDocument } from "./generated/default-doc";
import { DocsExplorer } from "./docs-explorer";

export const metadata: Metadata = {
  title: { absolute: "Pakperk Docs — Develop, test on phones, and deploy" },
  description:
    "Implementation-linked Pakperk guides for local development, physical phone testing, backend deployment, architecture, and operations, with source-matched Simplified Chinese translations when available.",
};

export default async function Home({ searchParams }: PageProps<"/">) {
  const requestedLanguage = (await searchParams).lang;
  const initialLanguage = (Array.isArray(requestedLanguage) ? requestedLanguage[0] : requestedLanguage) === "zh"
    ? "zh"
    : "en";

  return <DocsExplorer initialContent={defaultDocument} initialLanguage={initialLanguage} />;
}
