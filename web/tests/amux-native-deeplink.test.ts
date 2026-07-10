import { describe, expect, test } from "bun:test";
import { buildNativeDeeplink } from "../app/lib/native-deeplink";

describe("amux native deeplinks", () => {
  test("uses the canonical amux URL scheme", () => {
    const query = new URLSearchParams({
      host: "dev.example.com",
      title: "GPU box",
    });

    expect(buildNativeDeeplink("ssh", query)).toBe(
      "amux://ssh?host=dev.example.com&title=GPU%20box",
    );
  });
});
