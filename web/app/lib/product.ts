export const PRODUCT_NAME = "amux";
export const GITHUB_REPOSITORY = "Open330/amux";
export const GITHUB_REPOSITORY_URL = `https://github.com/${GITHUB_REPOSITORY}`;
export const GITHUB_ISSUES_URL = `${GITHUB_REPOSITORY_URL}/issues`;
export const GITHUB_RELEASES_URL = `${GITHUB_REPOSITORY_URL}/releases`;

const configuredSiteURL = process.env.NEXT_PUBLIC_AMUX_SITE_URL?.trim().replace(/\/$/, "");
const defaultSiteURL = "https://open330.github.io/amux";

// Public product pages are deployed from site/ to Open330's GitHub Pages
// origin. Preview deployments may override this without inheriting cmux.com.
export const PUBLIC_SITE_URL = configuredSiteURL || defaultSiteURL;
export const HAS_CONFIGURED_PUBLIC_SITE = true;
