"use client";

// Compatibility wrapper retained for imports in downstream forks. The amux
// website does not initialize or send data to the inherited cmux telemetry
// project.
export function PostHogProvider({ children }: { children: React.ReactNode }) {
  return <>{children}</>;
}
