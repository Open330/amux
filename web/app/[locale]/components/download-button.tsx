"use client";

import { useTranslations } from "next-intl";
import { Link, usePathname } from "../../../i18n/navigation";
import {
  DOWNLOAD_CONFIRMATION_HREF,
  DOWNLOAD_CONFIRMATION_PATH,
  DOWNLOAD_URL,
} from "../../lib/download";
import { AppleMark } from "./apple-mark";
import { ctaButtonStyle } from "./cta-styles";

export function DownloadButton({
  size = "default",
  location = "hero",
  className,
}: {
  size?: "default" | "sm";
  location?: string;
  className?: string;
}) {
  const t = useTranslations("common");
  const pathname = usePathname();
  const onConfirmationPage = pathname === DOWNLOAD_CONFIRMATION_PATH;
  const href = onConfirmationPage ? DOWNLOAD_URL : DOWNLOAD_CONFIRMATION_HREF;
  const classes = `inline-flex items-center whitespace-nowrap rounded-full bg-foreground font-medium ${
    size === "sm" ? "gap-2 px-3 py-1.5 text-xs" : "gap-2.5 px-5 py-2.5 text-[15px]"
  } ${className ?? ""}`;
  const content = (
    <>
      <AppleMark size={size === "sm" ? 14 : 19} />
      {t("downloadForMac")}
    </>
  );

  if (onConfirmationPage) {
    return (
      <a href={href} className={classes} style={ctaButtonStyle} data-location={location}>
        {content}
      </a>
    );
  }

  return (
    <Link href={href} className={classes} style={ctaButtonStyle} data-location={location}>
      {content}
    </Link>
  );
}
