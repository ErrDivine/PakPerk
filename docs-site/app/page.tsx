import type { Metadata } from "next";
import { defaultDocument } from "./generated/default-doc";
import { DocsExplorer } from "./docs-explorer";

export const metadata: Metadata = {
  title: { absolute: "Pakperk Docs — Build, operate, and ship with context" },
  description:
    "The complete Pakperk documentation library, with fast discovery and Simplified Chinese translations.",
};

export default function Home() {
  return <DocsExplorer initialContent={defaultDocument} />;
}
