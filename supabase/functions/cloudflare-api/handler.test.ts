import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handleRequest } from "./handler.ts";

const authorized = async () => ({ userId: "admin", isServiceRole: false });
const req = (action: string) =>
  new Request("https://example.test", {
    method: "POST",
    headers: { Origin: "https://queer.guide" },
    body: JSON.stringify({ action }),
  });
Deno.env.set("CLOUDFLARE_ZONE_ID", "test-zone");
Deno.env.set("CLOUDFLARE_API_TOKEN", "test-token");
Deno.env.delete("CLOUDFLARE_ACCOUNT_ID");

Deno.test("rejects unauthenticated calls before contacting Cloudflare", async () => {
  const response = await handleRequest(
    req("zone-info"),
    async () => new Response("denied", { status: 403 }),
  );
  assertEquals(response.status, 403);
});

Deno.test("zone requests do not require an account ID; upstream errors stay visible", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () =>
    Response.json({
      success: false,
      errors: [{ code: 10000, message: "Authentication error" }],
    }, { status: 403 });
  try {
    const response = await handleRequest(req("zone-info"), authorized);
    assertEquals(response.status, 502);
    assertStringIncludes(
      (await response.json()).error,
      "10000 Authentication error",
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("GraphQL failures do not produce successful zero analytics", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () =>
    Response.json({
      errors: [{ message: "Analytics read permission required" }],
      data: null,
    });
  try {
    const response = await handleRequest(req("analytics"), authorized);
    assertEquals(response.status, 502);
    assertStringIncludes(
      (await response.json()).error,
      "Analytics read permission required",
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("normalizes GraphQL totals without double counting unique visitors", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (_input, init) => {
    const body = JSON.parse(String((init as RequestInit | undefined)?.body));
    assertStringIncludes(body.query, "httpRequests1hGroups(limit: 1");
    assertEquals(body.variables.zone, "test-zone");
    return Response.json({
      data: {
        viewer: {
          zones: [{
            httpRequests1hGroups: [{
              sum: {
                requests: 100,
                cachedRequests: 30,
                bytes: 1000,
                cachedBytes: 200,
                threats: 2,
                pageViews: 20,
              },
              uniq: { uniques: 7 },
            }],
          }],
        },
      },
    });
  };
  try {
    const response = await handleRequest(req("analytics"), authorized);
    assertEquals(response.status, 200);
    const data = await response.json();
    assertEquals(data.result.totals.requests, {
      all: 100,
      cached: 30,
      uncached: 70,
    });
    assertEquals(data.result.totals.uniques.all, 7);
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("performance does not request deprecated Auto Minify", async () => {
  const original = globalThis.fetch;
  const urls: string[] = [];
  globalThis.fetch = async (url) => {
    urls.push(String(url));
    return Response.json({ success: true, result: { value: "on" } });
  };
  try {
    assertEquals(
      (await handleRequest(req("performance-settings"), authorized)).status,
      200,
    );
    assertEquals(urls.length, 3);
    assertEquals(urls.some((url) => url.includes("/minify")), false);
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("admin authentication uses the current runtime secret key after legacy key rotation", async () => {
  const original = globalThis.fetch;
  Deno.env.set("SUPABASE_URL", "https://supabase.example.test");
  Deno.env.set(
    "SUPABASE_SECRET_KEYS",
    JSON.stringify({ default: "sb_secret_current" }),
  );
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "legacy-stale");
  const calls: string[] = [];
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    if (url.includes("/auth/v1/user")) {
      assertEquals(
        new Headers((init as RequestInit | undefined)?.headers).get("apikey"),
        "sb_secret_current",
      );
      return Response.json({
        id: "11111111-1111-4111-8111-111111111111",
        aud: "authenticated",
        role: "authenticated",
      });
    }
    if (url.includes("/rest/v1/user_roles")) {
      assertEquals(
        new Headers((init as RequestInit | undefined)?.headers).get("apikey"),
        "sb_secret_current",
      );
      return Response.json({ role: "admin" });
    }
    return Response.json({ success: true, result: { name: "queer.guide" } });
  };
  try {
    const request = new Request("https://example.test", {
      method: "POST",
      headers: { Authorization: "Bearer user-session" },
      body: JSON.stringify({ action: "zone-info" }),
    });
    assertEquals((await handleRequest(request)).status, 200);
    assertEquals(
      calls.some((url) => url.includes("/rest/v1/user_roles")),
      true,
    );
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("SUPABASE_SECRET_KEYS");
  }
});
