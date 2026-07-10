import { afterEach, describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";

const originalSiteURL = process.env.NEXT_PUBLIC_AMUX_SITE_URL;

afterEach(() => {
  if (originalSiteURL === undefined) {
    delete process.env.NEXT_PUBLIC_AMUX_SITE_URL;
  } else {
    process.env.NEXT_PUBLIC_AMUX_SITE_URL = originalSiteURL;
  }
});

describe("amux hosted-service boundary", () => {
  test("rejects inherited hosted APIs", () => {
    const response = middleware(
      new NextRequest("https://preview.example/api/billing/checkout"),
    );
    expect(response.status).toBe(410);
  });

  test("leaves the Open330 GitHub stars API routable", () => {
    const response = middleware(
      new NextRequest("https://preview.example/api/github-stars"),
    );
    expect(response.headers.get("x-middleware-next")).toBe("1");
  });

  test("rejects direct access to the internal agent-page renderer", () => {
    const response = middleware(
      new NextRequest(
        "https://attacker.example/agent-page-variant?path=/en/docs/getting-started.md",
      ),
    );
    expect(response.status).toBe(410);
  });

  test("redirects inherited auth handlers and pricing pages", () => {
    const handler = middleware(
      new NextRequest("https://preview.example/handler/after-sign-in"),
    );
    expect(handler.status).toBe(307);
    expect(handler.headers.get("location")).toBe("https://github.com/Open330/amux");

    const pricing = middleware(
      new NextRequest("https://preview.example/ja/pricing"),
    );
    expect(pricing.status).toBe(307);
    expect(pricing.headers.get("location")).toBe("https://github.com/Open330/amux");
  });

  test("disallows indexing until Open330 configures a public origin", async () => {
    delete process.env.NEXT_PUBLIC_AMUX_SITE_URL;
    const { default: robots } = await import(`../app/robots?unset=${Date.now()}`);
    expect(robots()).toEqual({ rules: { userAgent: "*", disallow: "/" } });
  });
});
