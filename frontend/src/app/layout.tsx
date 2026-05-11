import type { Metadata } from "next";
import localFont from "next/font/local";
import Script from "next/script";
import "./globals.css";

const ibmPlexSans = localFont({
  variable: "--font-ibm-plex-sans",
  display: "swap",
  src: [
    { path: "../../public/fonts/IBMPlexSans-Light.woff2", weight: "300", style: "normal" },
    { path: "../../public/fonts/IBMPlexSans-Regular.woff2", weight: "400", style: "normal" },
    { path: "../../public/fonts/IBMPlexSans-Medium.woff2", weight: "500", style: "normal" },
    { path: "../../public/fonts/IBMPlexSans-SemiBold.woff2", weight: "600", style: "normal" },
  ],
});

const ibmPlexMono = localFont({
  variable: "--font-ibm-plex-mono",
  display: "swap",
  src: [
    { path: "../../public/fonts/IBMPlexMono-Regular.woff2", weight: "400", style: "normal" },
    { path: "../../public/fonts/IBMPlexMono-Medium.woff2", weight: "500", style: "normal" },
  ],
});

export const metadata: Metadata = {
  title: "BookLLM",
  description: "Privacy-first local AI document translator. Supports PDF, EPUB, TXT and image formats.",
};


const apiUrl = process.env.API_URL ?? "http://localhost:3001";

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="zh-CN"
      className={`${ibmPlexSans.variable} ${ibmPlexMono.variable}`}
      suppressHydrationWarning
    >
      <head>
        {}
        <script
          dangerouslySetInnerHTML={{
            __html: `window.__OB_API_URL__=${JSON.stringify(apiUrl)}`,
          }}
        />
      </head>
      <body className="min-h-screen bg-background text-foreground antialiased">
        <Script
          id="theme-init"
          strategy="beforeInteractive"
        >{`(function(){var t=localStorage.getItem('bookllm:theme')||'dark';var d=document.documentElement;d.classList.remove('dark','light');d.classList.add(t);})();`}</Script>
        {children}
      </body>
    </html>
  );
}
