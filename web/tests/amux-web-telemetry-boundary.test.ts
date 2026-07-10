import { afterEach, describe, expect, mock, test } from "bun:test";

const registerOTel = mock(() => undefined);
const sentryInit = mock(() => undefined);

mock.module("@vercel/otel", () => ({ registerOTel }));
mock.module("@sentry/nextjs", () => ({
  init: sentryInit,
  captureRequestError: mock(() => undefined),
}));

const originalEnv = { ...process.env };

afterEach(() => {
  process.env = { ...originalEnv };
  registerOTel.mockClear();
  sentryInit.mockClear();
});

describe("amux web telemetry boundary", () => {
  test("ignores inherited generic telemetry environment variables", async () => {
    process.env.NEXT_RUNTIME = "nodejs";
    process.env.OTEL_SERVICE_NAME = "upstream-service";
    process.env.SENTRY_DSN = "https://public@example.invalid/1";
    delete process.env.AMUX_ENABLE_WEB_TELEMETRY;

    const instrumentation = await import(
      `../instrumentation?inherited=${Date.now()}`
    );
    await instrumentation.register();

    expect(registerOTel).toHaveBeenCalledTimes(0);
    expect(sentryInit).toHaveBeenCalledTimes(0);
  });
});
