import { registerOTel } from "@vercel/otel";

function telemetryEnabled() {
  return process.env.AMUX_ENABLE_WEB_TELEMETRY === "1";
}

export async function register() {
  if (!telemetryEnabled()) return;

  const otelServiceName = process.env.AMUX_OTEL_SERVICE_NAME?.trim();
  if (otelServiceName) {
    registerOTel({ serviceName: otelServiceName });
  }

  const sentryDSN = process.env.AMUX_SENTRY_DSN?.trim();
  if (process.env.NEXT_RUNTIME === "nodejs" && sentryDSN) {
    const Sentry = await import("@sentry/nextjs");
    Sentry.init({
      dsn: sentryDSN,
    });
  }
}

export async function onRequestError(
  ...args: Parameters<typeof import("@sentry/nextjs").captureRequestError>
) {
  const sentryDSN = process.env.AMUX_SENTRY_DSN?.trim();
  if (!telemetryEnabled() || process.env.NEXT_RUNTIME !== "nodejs" || !sentryDSN) {
    return;
  }
  const Sentry = await import("@sentry/nextjs");
  return Sentry.captureRequestError(...args);
}
