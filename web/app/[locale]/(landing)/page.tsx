import { useTranslations } from "next-intl";
import Image from "next/image";
import { HeroScreenshot } from "@/app/[locale]/components/hero-screenshot";
import { DownloadButton } from "@/app/[locale]/components/download-button";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import { Link } from "@/i18n/navigation";

export default function Home() {
  return <HomeContent />;
}

function HomeContent() {
  const t = useTranslations("home");
  const tc = useTranslations("common");

  const linkClass =
    "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

  // FAQPage structured data, built from the same FAQ copy rendered below so the
  // Q&As are eligible for Google rich results and AI answer engines.
  const faqKeys = [
    "Ghostty", "Platform", "Agents", "Orchestration", "Remote",
    "Notifications", "Scriptable", "Browser", "Skills", "Shortcuts",
    "Customize", "Sessions", "Tmux", "Free",
  ];
  const stripTags = (s: string) => s.replace(/<\/?[a-zA-Z]+>/g, "");
  const faqJsonLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: faqKeys.map((k) => ({
      "@type": "Question",
      name: stripTags(t.raw(`faq${k}Q`) as string),
      acceptedAnswer: {
        "@type": "Answer",
        text: stripTags(t.raw(`faq${k}A`) as string),
      },
    })),
  };
  const faqJsonLdScript = JSON.stringify(faqJsonLd).replace(/</g, "\\u003c");

  return (
    <div className="min-h-screen">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: faqJsonLdScript }}
      />
      <SiteHeader />

      <main className="w-full">
        <section className="relative h-[calc(84svh-3rem)] min-h-[560px] max-h-[820px] overflow-hidden border-y border-border bg-black text-white">
          <HeroScreenshot alt={t("taglineStatic")} background />
          <div className="absolute inset-0 bg-black/70" aria-hidden="true" />
          <div className="relative mx-auto flex h-full w-full max-w-6xl flex-col justify-center px-6 pb-14">
            <div className="mb-6 flex items-center gap-3">
              <BrandLogoLink className="shrink-0">
                <Image src="/logo.png" alt="amux" width={42} height={42} className="rounded-md" />
              </BrandLogoLink>
              <span className="font-mono text-xs text-emerald-300">agent mux / macOS 14+</span>
            </div>
            <h1 className="text-7xl font-semibold leading-none sm:text-8xl">amux</h1>
            <p className="mt-7 max-w-3xl text-2xl leading-tight text-balance sm:text-3xl">
              {t("taglineStatic")}
            </p>
            <p className="mt-5 max-w-2xl text-base leading-7 text-white/75">
              {t.rich("subtitle", {
                cliLink: (chunks) => (
                  <Link href="/docs/api" className="underline underline-offset-4">
                    {chunks}
                  </Link>
                ),
              })}
            </p>
            <div className="mt-7 flex flex-wrap items-center gap-3">
              <DownloadButton location="hero" />
              <div className="[&_a]:border-white/50 [&_a]:text-white [&_a:hover]:bg-white/10">
                <GitHubButton />
              </div>
            </div>
            <div className="mt-7 flex flex-wrap gap-x-7 gap-y-2 font-mono text-xs text-white/70">
              <span>tmux 3.7b</span>
              <span>muxa</span>
              <span>Ghostty</span>
              <span>GPL-3.0</span>
            </div>
          </div>
        </section>

        <section className="border-b border-border">
          <div className="mx-auto grid w-full max-w-6xl gap-12 px-6 py-20 lg:grid-cols-[0.8fr_1.2fr] lg:items-center lg:py-28">
            <div>
              <div className="mb-5 flex items-center gap-3">
                <kbd className="rounded-md border border-border bg-code-bg px-2.5 py-1.5 font-mono text-sm">⌘K</kbd>
                <span className="text-xs font-medium uppercase text-muted">muxa watch</span>
              </div>
              <h2 className="text-3xl font-semibold leading-tight sm:text-4xl">
                {t("feature.keyboardShortcuts")}
              </h2>
              <p className="mt-5 max-w-xl text-base leading-7 text-muted">
                {t.rich("feature.keyboardShortcutsDesc", {
                  link: (chunks) => (
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
              <div className="mt-6 flex flex-wrap gap-3 font-mono text-xs text-muted">
                <span>⌘⇧J</span>
                <span>prefix + d</span>
                <span>amux ssh</span>
              </div>
            </div>

            <div className="overflow-hidden rounded-md border border-border bg-background shadow-2xl">
              <div className="flex h-12 items-center justify-between border-b border-border px-4">
                <span className="text-sm font-medium">{t("feature.keyboardShortcuts")}</span>
                <kbd className="rounded border border-border bg-code-bg px-2 py-1 font-mono text-xs text-muted">⌘K</kbd>
              </div>
              <div className="divide-y divide-border">
                <div className="flex min-h-16 items-center justify-between gap-4 px-4 py-3">
                  <div className="min-w-0"><strong className="block truncate text-sm">Claude Code · callabo-native</strong><span className="text-xs text-muted">{t("feature.notificationRings")}</span></div>
                  <span className="shrink-0 rounded border border-amber-500/40 bg-amber-500/10 px-2 py-1 text-xs text-amber-600 dark:text-amber-300">muxa</span>
                </div>
                <div className="flex min-h-16 items-center justify-between gap-4 px-4 py-3">
                  <div className="min-w-0"><strong className="block truncate text-sm">amux · localhost</strong><span className="text-xs text-muted">{t("feature.verticalTabs")}</span></div>
                  <span className="shrink-0 rounded border border-emerald-500/40 bg-emerald-500/10 px-2 py-1 text-xs text-emerald-700 dark:text-emerald-300">tmux</span>
                </div>
                <div className="flex min-h-16 items-center justify-between gap-4 px-4 py-3">
                  <div className="min-w-0"><strong className="block truncate text-sm">jiun-mini · SSH</strong><span className="text-xs text-muted">{t("faqRemoteQ")}</span></div>
                  <span className="shrink-0 rounded border border-sky-500/40 bg-sky-500/10 px-2 py-1 text-xs text-sky-700 dark:text-sky-300">SSH</span>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="border-b border-border">
          <div className="mx-auto w-full max-w-6xl px-6 py-20 lg:py-28">
            <p className="mb-4 text-xs font-medium uppercase text-muted">{t("features")}</p>
            <h2 className="max-w-3xl text-3xl font-semibold leading-tight sm:text-4xl">{t("taglineStatic")}</h2>
            <div className="mt-12 grid border-t border-border md:grid-cols-2 lg:grid-cols-3">
              {(
                [
                  ["verticalTabs", "verticalTabsDesc"],
                  ["notificationRings", "notificationRingsDesc"],
                  ["splitPanes", "splitPanesDesc"],
                  ["scriptable", "scriptableDesc"],
                  ["inAppBrowser", "inAppBrowserDesc"],
                  ["gpuAccelerated", "gpuAcceleratedDesc"],
                ] as const
              ).map(([title, desc]) => (
                <article key={title} className="min-w-0 border-b border-border py-7 pr-7">
                  <h3 className="text-sm leading-6">
                    <strong className="font-medium">{t(`feature.${title}`)}</strong>
                    <span className="font-normal text-muted">{t(`feature.${desc}`)}</span>
                  </h3>
                </article>
              ))}
            </div>
            <div data-dev="screenshot" className="mt-16 overflow-hidden rounded-md border border-border">
              <HeroScreenshot alt={t("taglineStatic")} />
            </div>
          </div>
        </section>

        <div className="mx-auto w-full max-w-2xl px-6 py-16 sm:py-24">

        {/* FAQ */}
        <div data-dev="faq-top-spacer" style={{ height: 32 }} />
        <section data-dev="faq" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("faq")}
          </h2>
          <div
            className="space-y-5 text-[15px]"
            style={{ lineHeight: 1.5 }}
          >
            <div>
              <p className="font-medium mb-1">{t("faqGhosttyQ")}</p>
              <p className="text-muted">
                {t.rich("faqGhosttyA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/ghostty-org/ghostty"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqPlatformQ")}</p>
              <p className="text-muted">{t("faqPlatformA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqAgentsQ")}</p>
              <p className="text-muted">{t("faqAgentsA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqOrchestrationQ")}</p>
              <p className="text-muted">
                {t.rich("faqOrchestrationA", {
                  teamsLink: (chunks) => (
                    <Link
                      href="/docs/agent-integrations/claude-code-teams"
                      className={linkClass}
                    >
                      {chunks}
                    </Link>
                  ),
                  omoLink: (chunks) => (
                    <Link
                      href="/docs/agent-integrations/oh-my-opencode"
                      className={linkClass}
                    >
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqRemoteQ")}</p>
              <p className="text-muted">
                {t.rich("faqRemoteA", {
                  link: (chunks) => (
                    <Link href="/docs/ssh" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqNotificationsQ")}</p>
              <p className="text-muted">
                {t.rich("faqNotificationsA", {
                  cliLink: (chunks) => (
                    <Link href="/docs/notifications#cli-usage" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  hooksLink: (chunks) => (
                    <Link href="/docs/notifications#integration-examples" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqScriptableQ")}</p>
              <p className="text-muted">
                {t.rich("faqScriptableA", {
                  cliLink: (chunks) => (
                    <Link href="/docs/api" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  browserLink: (chunks) => (
                    <Link href="/docs/browser-automation" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqBrowserQ")}</p>
              <p className="text-muted">
                {t.rich("faqBrowserA", {
                  link: (chunks) => (
                    <Link href="/docs/browser-automation" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqSkillsQ")}</p>
              <p className="text-muted">
                {t.rich("faqSkillsA", {
                  skillsLink: (chunks) => (
                    <a
                      href="https://github.com/Open330/amux/tree/main/skills"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/skills" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqShortcutsQ")}</p>
              <p className="text-muted">
                {t.rich("faqShortcutsA", {
                  configPath: (chunks) => (
                    <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
                      {chunks}
                    </code>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqCustomizeQ")}</p>
              <p className="text-muted">
                {t.rich("faqCustomizeA", {
                  path: (chunks) => (
                    <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
                      {chunks}
                    </code>
                  ),
                  shortcutsLink: (chunks) => (
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/configuration" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqSessionsQ")}</p>
              <p className="text-muted">
                {t.rich("faqSessionsA", {
                  link: (chunks) => (
                    <Link href="/docs/session-restore" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqTmuxQ")}</p>
              <p className="text-muted">
                {t.rich("faqTmuxA", {
                  link: (chunks) => (
                    <Link href="/docs/remote-tmux" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqFreeQ")}</p>
              <p className="text-muted">
                {t.rich("faqFreeA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/Open330/amux"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
          </div>
        </section>

        {/* Bottom CTA */}
        <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
          <DownloadButton location="bottom" />
          <GitHubButton />
        </div>
        <div className="flex justify-center gap-4 mt-6">
          <Link
            href="/docs"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-link-underline hover:decoration-foreground"
          >
            {tc("readTheDocs")}
          </Link>
          <Link
            href="/docs/changelog"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-link-underline hover:decoration-foreground"
          >
            {tc("viewChangelog")}
          </Link>
        </div>
        </div>
      </main>
    </div>
  );
}
