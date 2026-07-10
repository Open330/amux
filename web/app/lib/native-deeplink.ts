export function buildNativeDeeplink(
  kind: string,
  query: URLSearchParams,
): string {
  const queryString = query.toString().replace(/\+/g, "%20");
  return `amux://${kind}${queryString ? `?${queryString}` : ""}`;
}
