export const comparePages = [
  {
    slug: "best-terminal-for-ai-coding-agents",
    key: "bestTerminalForAgents",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-alacritty",
    key: "cmuxVsAlacritty",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-conductor",
    key: "cmuxVsConductor",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-cursor",
    key: "cmuxVsCursor",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-devin",
    key: "cmuxVsDevin",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-ghostty",
    key: "cmuxVsGhostty",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-herdr",
    key: "cmuxVsHerdr",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-iterm2",
    key: "cmuxVsIterm2",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-kitty",
    key: "cmuxVsKitty",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-opencode",
    key: "cmuxVsOpencode",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-superset",
    key: "cmuxVsSuperset",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-tmux",
    key: "cmuxVsTmux",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-vscode",
    key: "cmuxVsVscode",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-warp",
    key: "cmuxVsWarp",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-wezterm",
    key: "cmuxVsWezterm",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-windsurf",
    key: "cmuxVsWindsurf",
    lastModified: "2026-07-04",
  },
  {
    slug: "amux-vs-zed",
    key: "cmuxVsZed",
    lastModified: "2026-07-04",
  },
  {
    slug: "multiple-claude-code-agents-parallel",
    key: "multipleClaudeAgents",
    lastModified: "2026-07-04",
  },
] as const;

export type ComparePage = (typeof comparePages)[number];
export type ComparePageKey = ComparePage["key"];

export function comparePath(slug: string) {
  return `/compare/${slug}`;
}

export function comparePageForSlug(slug: string): ComparePage | undefined {
  return comparePages.find((page) => page.slug === slug);
}
