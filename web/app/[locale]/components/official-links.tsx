import { useTranslations } from "next-intl";

function CommunityLink({
  href,
  icon,
  name,
  action,
  description,
}: {
  href: string;
  icon: React.ReactNode;
  name: string;
  action: string;
  description: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="group flex items-start gap-4 rounded-lg border border-border p-5 hover:bg-code-bg transition-colors"
    >
      <div className="shrink-0 mt-0.5 text-muted group-hover:text-foreground transition-colors">
        {icon}
      </div>
      <div className="min-w-0">
        <div className="font-medium text-[15px]">{name}</div>
        <div className="text-sm text-muted mt-0.5">{description}</div>
        <div className="text-xs font-medium text-muted mt-2 group-hover:text-foreground transition-colors">
          {action} &rarr;
        </div>
      </div>
    </a>
  );
}

/**
 * The official amux links rendered as a
 * responsive card grid. Shared between the Community page and the download
 * confirmation page so both stay in sync. Reads copy from the `community`
 * message namespace. Pass `heading={false}` to omit the section title.
 */
export function OfficialLinks({ heading = true }: { heading?: boolean }) {
  const t = useTranslations("community");

  return (
    <section className="mb-10">
      {heading && (
        <h2 className="mb-4 text-xs font-medium tracking-tight text-muted">
          {t("officialLinksTitle")}
        </h2>
      )}
      <div className="grid gap-4 sm:grid-cols-2">
        <CommunityLink
          href="https://github.com/Open330/amux"
          name="GitHub"
          action={t("githubAction")}
          description={t("githubDesc")}
          icon={
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
            </svg>
          }
        />

      </div>
    </section>
  );
}
