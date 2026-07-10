export function headersForCanonicalFetch({
  requestHeaders,
}: {
  requestHeaders: Headers;
  searchParams: URLSearchParams;
}): Headers {
  const headers = new Headers({
    accept: "text/html",
    "x-cmux-agent-page-variant": "canonical-html",
  });

  copyRequestHeader(requestHeaders, headers, "accept-language");

  return headers;
}

export function hasSensitiveCanonicalAccess(headers: Headers): boolean {
  return (
    headers.has("authorization") ||
    headers.has("cookie") ||
    headers.has("x-vercel-protection-bypass") ||
    headers.has("x-vercel-set-bypass-cookie")
  );
}

function copyRequestHeader(
  requestHeaders: Headers,
  headers: Headers,
  name: string,
) {
  const value = requestHeaders.get(name);
  if (value) {
    headers.set(name, value);
  }
}
