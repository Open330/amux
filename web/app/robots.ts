import type { MetadataRoute } from "next";
import { HAS_CONFIGURED_PUBLIC_SITE, PUBLIC_SITE_URL } from "./lib/product";

export default function robots(): MetadataRoute.Robots {
  if (!HAS_CONFIGURED_PUBLIC_SITE) {
    return { rules: { userAgent: "*", disallow: "/" } };
  }
  return {
    rules: { userAgent: "*", allow: "/", disallow: "/_next/" },
    sitemap: `${PUBLIC_SITE_URL}/sitemap.xml`,
  };
}
