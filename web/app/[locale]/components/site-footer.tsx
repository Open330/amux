import { getTranslations } from "next-intl/server";
import { Link } from "../../../i18n/navigation";
import { LanguageSwitcher } from "./language-switcher";
import { GITHUB_ISSUES_URL, GITHUB_REPOSITORY_URL } from "../../lib/product";

function isExternal(href: string) {
  return href.startsWith("http") || href.startsWith("mailto:");
}

export async function SiteFooter() {
  const t = await getTranslations("footer");
  const year = new Date().getFullYear();

  const columns = [
    {
      heading: t("product"),
      links: [
        { label: t("assets"), href: "/assets" },
        { label: t("github"), href: GITHUB_REPOSITORY_URL },
      ],
    },
    {
      heading: t("resources"),
      links: [
        { label: t("docs"), href: "/docs/getting-started" },
        { label: t("guides"), href: "/guides" },
        { label: t("compare"), href: "/compare" },
        { label: t("changelog"), href: "/docs/changelog" },
      ],
    },
    {
      heading: t("legal"),
      links: [
        { label: t("openSource"), href: `${GITHUB_REPOSITORY_URL}/blob/main/LICENSE` },
      ],
    },
    {
      heading: t("social"),
      links: [
        { label: t("contact"), href: GITHUB_ISSUES_URL },
      ],
    },
  ];

  return (
    <footer className="mt-16">
      <div className="max-w-2xl mx-auto px-6 py-12">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-8">
          {columns.map((col) => (
            <div key={col.heading}>
              <h3 className="text-xs font-medium text-muted tracking-tight mb-3">
                {col.heading}
              </h3>
              <ul className="space-y-2">
                {col.links.map((link) => {
                  const item = (
                    <li key={link.href}>
                      {isExternal(link.href) ? (
                        <a
                          href={link.href}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </a>
                      ) : (
                        <Link
                          href={link.href}
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </Link>
                      )}
                    </li>
                  );
                  return item;
                })}
              </ul>
            </div>
          ))}
        </div>
        <div className="flex items-center justify-between mt-10">
          <p className="text-xs text-muted">
            {t("copyright", { year })}
            <span aria-hidden className="mx-2">
              ·
            </span>
            <a
              href={GITHUB_REPOSITORY_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="hover:text-foreground transition-colors"
            >
              {t("openSource")}
            </a>
          </p>
          <LanguageSwitcher />
        </div>
      </div>
    </footer>
  );
}
