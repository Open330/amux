"use client";

import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import { GITHUB_REPOSITORY_URL } from "../../lib/product";

export function NavLinks() {
  const t = useTranslations("nav");
  return (
    <>
      <Link
        href="/docs/getting-started"
        className="hover:text-foreground transition-colors"
      >
        {t("docs")}
      </Link>
      <Link
        href="/docs/changelog"
        className="hover:text-foreground transition-colors"
      >
        {t("changelog")}
      </Link>
      <a
        href={GITHUB_REPOSITORY_URL}
        target="_blank"
        rel="noopener noreferrer"
        className="hover:text-foreground transition-colors"
      >
        {t("github")}
      </a>
    </>
  );
}
