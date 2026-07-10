export const PRODUCT_NAME = "amux";
export const GITHUB_REPOSITORY = "Open330/amux";
export const GITHUB_REPOSITORY_URL = `https://github.com/${GITHUB_REPOSITORY}`;
export const GITHUB_ISSUES_URL = `${GITHUB_REPOSITORY_URL}/issues`;
export const GITHUB_RELEASES_URL = `${GITHUB_REPOSITORY_URL}/releases`;

const configuredSiteURL = process.env.NEXT_PUBLIC_AMUX_SITE_URL?.trim().replace(/\/$/, "");

// amux has no inherited right to publish under cmux.com. Until Open330
// configures a web origin, canonical discovery points at the repository.
export const PUBLIC_SITE_URL = configuredSiteURL || GITHUB_REPOSITORY_URL;
export const HAS_CONFIGURED_PUBLIC_SITE = Boolean(configuredSiteURL);
