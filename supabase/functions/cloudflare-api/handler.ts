import { createClient } from "https://esm.sh/@supabase/supabase-js@2.50.5";
import {
  corsResponse,
  errorResponse,
  jsonResponse,
  requireAdmin,
} from "../_shared/supabase-client.ts";

interface CloudflareConfig {
  zoneId: string;
  accountId?: string;
  apiToken: string;
  baseUrl: string;
}

function getCloudflareConfig(): CloudflareConfig | null {
  const zoneId = Deno.env.get("CLOUDFLARE_ZONE_ID");
  const accountId = Deno.env.get("CLOUDFLARE_ACCOUNT_ID");
  const apiToken = Deno.env.get("CLOUDFLARE_API_TOKEN");

  if (!zoneId || !apiToken) return null;

  return {
    zoneId,
    accountId,
    apiToken,
    baseUrl: "https://api.cloudflare.com/client/v4",
  };
}

async function makeCloudflareRequest(
  endpoint: string,
  config: CloudflareConfig,
) {
  const response = await fetch(`${config.baseUrl}${endpoint}`, {
    headers: {
      "Authorization": `Bearer ${config.apiToken}`,
      "Content-Type": "application/json",
    },
  });

  const data = await response.json();
  if (!response.ok || data.success === false) {
    const detail = data.errors?.map((
      error: { code?: number; message: string },
    ) => `${error.code || ""} ${error.message}`).join("; ");
    throw new Error(
      `Cloudflare API error (${response.status}): ${
        detail || response.statusText
      }`,
    );
  }
  return data;
}

async function authorizeAdmin(req: Request): Promise<unknown> {
  // The runtime's legacy service JWT can lag behind key rotation. Use the
  // current generated secret key for Auth and role lookups when available.
  const keys = JSON.parse(
    Deno.env.get("SUPABASE_SECRET_KEYS") || "{}",
  ) as Record<string, string>;
  const key = keys.default || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return requireAdmin(req, supabase);
}

export async function handleRequest(
  req: Request,
  authorize = authorizeAdmin,
): Promise<Response> {
  if (req.method === "OPTIONS") return corsResponse(req);
  if (req.method !== "POST") {
    return errorResponse("Method not allowed", 405, req);
  }

  try {
    const authResult = await authorize(req);
    if (authResult instanceof Response) return authResult;

    let body: Record<string, unknown> = {};
    try {
      const rawBody = await req.text();
      if (rawBody) body = JSON.parse(rawBody);
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        throw new Error("Invalid body");
      }
    } catch {
      return errorResponse("Invalid request body", 400, req);
    }

    const { action, params = {} } = body as {
      action?: string;
      params?: Record<string, string>;
    };
    if (!params || typeof params !== "object" || Array.isArray(params)) {
      return errorResponse("Invalid params", 400, req);
    }
    const config = getCloudflareConfig();

    if (!config) {
      return errorResponse(
        "Cloudflare API not configured. Set CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN in Supabase secrets.",
        503,
        req,
      );
    }

    let result: unknown;

    switch (action) {
      case "zone-info":
        result = await makeCloudflareRequest(`/zones/${config.zoneId}`, config);
        break;

      case "analytics": {
        const since = (params as Record<string, string>).since ||
          new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const until = (params as Record<string, string>).until ||
          new Date().toISOString();
        const response = await fetch(`${config.baseUrl}/graphql`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${config.apiToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            query: `query Dashboard($zone: string, $since: Time, $until: Time) {
              viewer { zones(filter: {zoneTag: $zone}) {
                httpRequests1hGroups(limit: 1, filter: {datetime_geq: $since, datetime_lt: $until}) {
                  sum { requests cachedRequests bytes cachedBytes threats pageViews }
                  uniq { uniques }
                }
              } }
            }`,
            variables: { zone: config.zoneId, since, until },
          }),
        });
        const data = await response.json();
        if (!response.ok || data.errors?.length) {
          throw new Error(
            `Cloudflare analytics unavailable: ${
              data.errors?.map((error: { message: string }) => error.message)
                .join("; ") || response.statusText
            }`,
          );
        }
        const groups = data.data?.viewer?.zones?.[0]?.httpRequests1hGroups;
        if (!Array.isArray(groups)) {
          throw new Error("Cloudflare analytics unavailable for this zone");
        }
        const totals = groups[0];
        const sum = totals?.sum ||
          {
            requests: 0,
            cachedRequests: 0,
            bytes: 0,
            cachedBytes: 0,
            threats: 0,
            pageViews: 0,
          };
        result = {
          success: true,
          result: {
            totals: {
              requests: {
                all: sum.requests,
                cached: sum.cachedRequests,
                uncached: sum.requests - sum.cachedRequests,
              },
              bandwidth: {
                all: sum.bytes,
                cached: sum.cachedBytes,
                uncached: sum.bytes - sum.cachedBytes,
              },
              threats: { all: sum.threats, type: {} },
              pageviews: { all: sum.pageViews, search_engines: {} },
              uniques: { all: totals?.uniq?.uniques || 0 },
            },
            timeseries: [],
            since,
            until,
          },
        };

        break;
      }

      case "dns-records":
        result = await makeCloudflareRequest(
          `/zones/${config.zoneId}/dns_records`,
          config,
        );
        break;

      case "page-rules":
        result = await makeCloudflareRequest(
          `/zones/${config.zoneId}/pagerules`,
          config,
        );
        break;

      case "cache-stats":
        result = await makeCloudflareRequest(
          `/zones/${config.zoneId}/analytics/colos?since=${
            new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
          }`,
          config,
        );
        break;

      case "security-settings": {
        const securitySettings = await Promise.all([
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/security_level`,
            config,
          ),
          makeCloudflareRequest(`/zones/${config.zoneId}/settings/ssl`, config),
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/always_use_https`,
            config,
          ),
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/min_tls_version`,
            config,
          ),
        ]);
        result = {
          success: true,
          result: {
            security_level: securitySettings[0].result,
            ssl: securitySettings[1].result,
            always_use_https: securitySettings[2].result,
            min_tls_version: securitySettings[3].result,
          },
        };
        break;
      }

      case "performance-settings": {
        const performanceSettings = await Promise.all([
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/browser_cache_ttl`,
            config,
          ),
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/cache_level`,
            config,
          ),
          makeCloudflareRequest(
            `/zones/${config.zoneId}/settings/development_mode`,
            config,
          ),
        ]);
        result = {
          success: true,
          result: {
            browser_cache_ttl: performanceSettings[0].result,
            cache_level: performanceSettings[1].result,
            development_mode: performanceSettings[2].result,
          },
        };
        break;
      }

      case "bandwidth-stats": {
        const bandwidthSince = (params as Record<string, string>).since ||
          new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
        const bandwidthUntil = (params as Record<string, string>).until ||
          new Date().toISOString();
        result = await makeCloudflareRequest(
          `/zones/${config.zoneId}/analytics/dashboard?since=${bandwidthSince}&until=${bandwidthUntil}&continuous=false`,
          config,
        );
        break;
      }

      case "threat-analytics":
        return errorResponse(
          "Use GraphQL firewall analytics for security events; the legacy endpoint is unavailable.",
          503,
          req,
        );

      case "edge-certificates":
        result = await makeCloudflareRequest(
          `/zones/${config.zoneId}/ssl/certificate_packs`,
          config,
        );
        break;

      case "workers":
        if (!config.accountId) {
          return errorResponse(
            "CLOUDFLARE_ACCOUNT_ID is required for account data.",
            503,
            req,
          );
        }
        result = await makeCloudflareRequest(
          `/accounts/${config.accountId}/workers/scripts`,
          config,
        );
        break;

      case "account-info":
        if (!config.accountId) {
          return errorResponse(
            "CLOUDFLARE_ACCOUNT_ID is required for account data.",
            503,
            req,
          );
        }
        result = await makeCloudflareRequest(
          `/accounts/${config.accountId}`,
          config,
        );
        break;

      default:
        return errorResponse(
          "Invalid action. Available: zone-info, analytics, dns-records, page-rules, cache-stats, security-settings, performance-settings, bandwidth-stats, threat-analytics, edge-certificates, workers, account-info",
          400,
          req,
        );
    }

    return jsonResponse(result, 200, req);
  } catch (error) {
    console.error("Cloudflare API error:", error);
    return errorResponse(
      error instanceof Error ? error.message : "Cloudflare request failed",
      502,
      req,
    );
  }
}
