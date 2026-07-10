"use client";

import { Link } from "@/i18n/navigation";

// The event prop remains source-compatible with upstream callers, but amux does
// not initialize or send data to the inherited analytics project.
export function TrackedLink({
  href,
  className,
  children,
}: {
  href: string;
  event: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <Link href={href} className={className}>
      {children}
    </Link>
  );
}
