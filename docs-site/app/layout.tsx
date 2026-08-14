import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

const description =
  "The complete Pakperk documentation library, with English source and Simplified Chinese translations.";

export const metadata: Metadata = {
  title: { default: "Pakperk Docs", template: "%s — Pakperk Docs" },
  description,
};

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") || requestHeaders.get("host") || "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") || (host.startsWith("localhost") ? "http" : "https");
  const socialImage = `${protocol}://${host}/og.png`;

  return (
    <html lang="en">
      <head>
        <meta property="og:type" content="website" />
        <meta property="og:title" content="Pakperk Docs" />
        <meta property="og:description" content={description} />
        <meta property="og:image" content={socialImage} />
        <meta property="og:image:width" content="1536" />
        <meta property="og:image:height" content="1024" />
        <meta property="og:image:alt" content="Pakperk Docs — Build, operate, and ship with context." />
        <meta name="twitter:card" content="summary_large_image" />
        <meta name="twitter:title" content="Pakperk Docs" />
        <meta name="twitter:description" content={description} />
        <meta name="twitter:image" content={socialImage} />
      </head>
      <body>{children}</body>
    </html>
  );
}
