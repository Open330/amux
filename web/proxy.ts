import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";
import { isAgentPageVariantPath } from "./app/lib/agent-page-paths";
import {
  featureWorkflowContentLocales,
  featureWorkflowDocRequestForPathname,
} from "./i18n/locale-availability";
import { buildAlternateLinkHeader } from "./i18n/seo";
import { GITHUB_RELEASES_URL, GITHUB_REPOSITORY_URL } from "./app/lib/product";

const intlMiddleware = createMiddleware(routing);

export default function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  if (pathname === "/api/github-stars") {
    return NextResponse.next();
  }
  if (pathname === "/agent-page-variant") {
    return NextResponse.json(
      { error: "This internal renderer is unavailable as a public endpoint." },
      { status: 410 },
    );
  }
  if (pathname.startsWith("/api/")) {
    return NextResponse.json(
      { error: "This inherited hosted service is unavailable in amux." },
      { status: 410 },
    );
  }
  if (pathname === "/handler" || pathname.startsWith("/handler/")) {
    return NextResponse.redirect(GITHUB_REPOSITORY_URL, 307);
  }

  const localizedProductPath = pathname.replace(/^\/[a-z]{2}(?:-[A-Z]{2})?(?=\/|$)/, "") || "/";
  const productPath = localizedProductPath.replace(/\.(?:md|txt)$/, "");
  if (productPath.startsWith("/compare/cmux-vs-")) {
    const url = request.nextUrl.clone();
    url.pathname = pathname.replace("/compare/cmux-vs-", "/compare/amux-vs-");
    return NextResponse.redirect(url, 301);
  }
  const unavailablePrefixes = [
    "/app-pricing",
    "/billing",
    "/blog",
    "/community",
    "/dashboard",
    "/enterprise",
    "/ios",
    "/pricing",
    "/privacy-policy",
    "/terms-of-service",
    "/wall-of-love",
    "/eula",
    "/docs/ios",
    "/docs/vault",
  ];
  if (unavailablePrefixes.some((prefix) => productPath === prefix || productPath.startsWith(`${prefix}/`))) {
    return NextResponse.redirect(GITHUB_REPOSITORY_URL, 307);
  }
  if (productPath === "/nightly" || productPath.startsWith("/nightly/")) {
    return NextResponse.redirect(GITHUB_RELEASES_URL, 307);
  }

  // Temporary redirect: /changelog → /docs/changelog, preserving any locale prefix.
  const changelogMatch = pathname.match(/^(\/[a-z]{2}(?:-[A-Z]{2})?)?\/changelog\/?$/);
  if (changelogMatch) {
    const url = request.nextUrl.clone();
    url.pathname = `${changelogMatch[1] ?? ""}/docs/changelog`;
    return NextResponse.redirect(url, 307);
  }

  if (isAgentPageVariantPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = "/agent-page-variant";
    url.searchParams.set("path", pathname);
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set("x-cmux-agent-page-path", pathname);
    return NextResponse.rewrite(url, {
      request: { headers: requestHeaders },
    });
  }

  if (pathname.includes(".")) {
    return NextResponse.next();
  }

  const featureWorkflowDocRequest =
    featureWorkflowDocRequestForPathname(pathname);
  if (featureWorkflowDocRequest && !featureWorkflowDocRequest.locale) {
    const url = request.nextUrl.clone();
    url.pathname = `/en${featureWorkflowDocRequest.path}`;
    const response = NextResponse.rewrite(url);
    setFeatureWorkflowDocLinkHeader(
      response,
      request,
      featureWorkflowDocRequest.path,
    );
    return response;
  }

  // Legal pages are English-only. Redirect /<locale>/legal-page to /legal-page,
  // and skip next-intl for /legal-page so locale detection can't redirect back.
  const englishOnlyPages = new Set([
    "/privacy-policy",
    "/terms-of-service",
    "/eula",
  ]);
  if (englishOnlyPages.has(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = `/en${pathname}`;
    return NextResponse.rewrite(url);
  }
  const secondSlash = pathname.indexOf("/", 1);
  if (secondSlash !== -1) {
    const rest = pathname.slice(secondSlash);
    if (englishOnlyPages.has(rest)) {
      const url = request.nextUrl.clone();
      url.pathname = rest;
      return NextResponse.redirect(url, 301);
    }
  }

  const response = intlMiddleware(request);
  if (featureWorkflowDocRequest) {
    setFeatureWorkflowDocLinkHeader(
      response,
      request,
      featureWorkflowDocRequest.path,
    );
  }

  return response;
}

function setFeatureWorkflowDocLinkHeader(
  response: NextResponse,
  request: NextRequest,
  path: string,
) {
  response.headers.set(
    "Link",
    buildAlternateLinkHeader(
      requestOrigin(request),
      path,
      featureWorkflowContentLocales,
    ),
  );
}

function requestOrigin(request: NextRequest) {
  return request.nextUrl.origin;
}

export const config = {
  matcher: ["/((?!_next|_vercel).*)"],
};
