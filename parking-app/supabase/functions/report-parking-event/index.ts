const defaultOrigins = "https://zakariatabout.github.io";

export interface EdgeRuntime {
  getEnv(name: string): string | undefined;
  fetch(input: string | URL | Request, init?: RequestInit): Promise<Response>;
}

const defaultRuntime: EdgeRuntime = {
  getEnv: (name) => Deno.env.get(name),
  fetch: (input, init) => fetch(input, init),
};

export function allowedOrigin(
  origin: string | null,
  configuredOrigins = defaultOrigins,
): string | null {
  if (origin === null) return null; // client mobile natif
  const configured = new Set(
    configuredOrigins
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
  if (configured.has(origin)) return origin;
  try {
    const url = new URL(origin);
    if (
      url.protocol === "http:" &&
      (url.hostname === "localhost" || url.hostname === "127.0.0.1")
    ) {
      return origin;
    }
  } catch {
    return null;
  }
  return null;
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  origin: string | null,
  configuredOrigins: string,
): Response {
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  });
  const acceptedOrigin = allowedOrigin(origin, configuredOrigins);
  if (acceptedOrigin !== null) {
    headers.set("Access-Control-Allow-Origin", acceptedOrigin);
    headers.set(
      "Access-Control-Allow-Headers",
      "apikey, authorization, content-type",
    );
    headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  }
  return new Response(JSON.stringify(body), { status, headers });
}

export function requesterIp(request: Request): string | null {
  // Supabase documente X-Forwarded-For comme source de l'IP cliente. Les
  // autres en-têtes ne servent que pour les runtimes locaux/compatibles.
  const value = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip");
  return value && value.length <= 128 ? value : null;
}

export async function hmacSha256(
  value: string,
  secret: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(value),
  );
  return [...new Uint8Array(signature)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  if (leftBytes.length !== rightBytes.length) return false;
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index++) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

export function createHandler(runtime: EdgeRuntime = defaultRuntime) {
  return async (request: Request): Promise<Response> => {
    const configuredOrigins = runtime.getEnv("ALLOWED_ORIGINS") ??
      defaultOrigins;
    const respond = (
      body: Record<string, unknown>,
      status: number,
      origin: string | null,
    ) => jsonResponse(body, status, origin, configuredOrigins);
    const fetchUpstream: EdgeRuntime["fetch"] = (input, init) =>
      runtime.fetch(input, {
        ...init,
        signal: AbortSignal.timeout(5_000),
      });
    const origin = request.headers.get("origin");
    if (origin !== null && allowedOrigin(origin, configuredOrigins) === null) {
      return respond({ code: "origin_not_allowed" }, 403, null);
    }
    if (request.method === "OPTIONS") {
      return respond({ ok: true }, 200, origin);
    }
    const expectedApiKey = runtime.getEnv("PARKRADAR_PUBLISHABLE_KEY");
    if (
      !expectedApiKey ||
      expectedApiKey.length < 20 ||
      request.headers.get("apikey") !== expectedApiKey
    ) {
      return respond({ code: "invalid_api_key" }, 401, origin);
    }
    if (request.method === "GET") {
      // La clé publishable est, par définition, publique. La sonde GET
      // traverse une vraie transaction d'écriture et exige donc un second
      // secret réservé au monitoring/CI, jamais compilé dans Flutter.
      const expectedHealthToken = runtime.getEnv("HEALTHCHECK_TOKEN");
      const providedHealthToken = request.headers.get(
        "x-parkradar-health-token",
      );
      if (!expectedHealthToken || expectedHealthToken.length < 32) {
        return respond({ code: "service_unavailable" }, 503, origin);
      }
      if (
        !providedHealthToken ||
        !constantTimeEqual(providedHealthToken, expectedHealthToken)
      ) {
        return respond({ code: "health_unauthorized" }, 401, origin);
      }
      const ip = requesterIp(request);
      const salt = runtime.getEnv("REPORTER_HASH_SALT");
      const supabaseUrl = runtime.getEnv("SUPABASE_URL");
      const serviceRoleKey = runtime.getEnv("SUPABASE_SERVICE_ROLE_KEY");
      if (
        ip === null ||
        !salt ||
        salt.length < 32 ||
        !supabaseUrl ||
        !serviceRoleKey
      ) {
        return respond({ code: "service_unavailable" }, 503, origin);
      }
      try {
        const ipHash = await hmacSha256(ip, salt);
        const reportProbe = await fetchUpstream(
          `${supabaseUrl.replace(/\/$/, "")}/rest/v1/rpc/report_parking_event`,
          {
            method: "POST",
            headers: {
              apikey: serviceRoleKey,
              Authorization: `Bearer ${serviceRoleKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              p_event_type: "parked",
              // Cellule sentinelle à la lisière de la zone couverte, pour ne
              // pas verrouiller une cellule de circulation réelle au centre.
              p_lat: 48.801,
              p_lon: 2.221,
              p_client_token: `health-probe-${"0".repeat(32)}`,
              p_ip_hash: ipHash,
              p_dry_run: true,
            }),
          },
        );
        const reportProbePayload = await reportProbe.json();
        if (!reportProbe.ok || reportProbePayload !== true) {
          return respond({ code: "upstream_unavailable" }, 503, origin);
        }
        const health = await fetchUpstream(
          `${supabaseUrl.replace(/\/$/, "")}/rest/v1/rpc/community_edge_health`,
          {
            method: "POST",
            headers: {
              apikey: serviceRoleKey,
              Authorization: `Bearer ${serviceRoleKey}`,
              "Content-Type": "application/json",
            },
            body: "{}",
          },
        );
        const payload = await health.json() as Record<string, unknown>;
        if (
          !health.ok ||
          payload.schema_version !== "2026-07-p0-v4" ||
          payload.purge_job_active !== true ||
          payload.purge_last_run_succeeded !== true ||
          payload.anon_table_access !== false ||
          payload.authenticated_table_access !== false ||
          payload.anon_report_execute !== false ||
          payload.authenticated_report_execute !== false ||
          payload.service_report_execute !== true
        ) {
          return respond({ code: "upstream_unavailable" }, 503, origin);
        }
        return respond(
          { ok: true, schema_version: payload.schema_version },
          200,
          origin,
        );
      } catch {
        return respond({ code: "upstream_unavailable" }, 503, origin);
      }
    }
    if (request.method !== "POST") {
      return respond({ code: "method_not_allowed" }, 405, origin);
    }

    let body: Record<string, unknown>;
    try {
      const parsed = await request.json();
      if (
        typeof parsed !== "object" || parsed === null || Array.isArray(parsed)
      ) {
        return respond({ code: "invalid_json" }, 400, origin);
      }
      body = parsed as Record<string, unknown>;
    } catch {
      return respond({ code: "invalid_json" }, 400, origin);
    }

    const eventType = body.event_type;
    const latitude = body.lat;
    const longitude = body.lon;
    const clientToken = body.client_token;
    if (eventType !== "parked" && eventType !== "freed") {
      return respond({ code: "invalid_event_type" }, 400, origin);
    }
    if (
      typeof latitude !== "number" ||
      typeof longitude !== "number" ||
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      latitude < 48.80 ||
      latitude > 48.91 ||
      longitude < 2.22 ||
      longitude > 2.47
    ) {
      return respond({ code: "invalid_coordinates" }, 400, origin);
    }
    if (
      typeof clientToken !== "string" ||
      clientToken.length < 32 ||
      clientToken.length > 128
    ) {
      return respond({ code: "invalid_client_token" }, 400, origin);
    }

    const ip = requesterIp(request);
    const salt = runtime.getEnv("REPORTER_HASH_SALT");
    const supabaseUrl = runtime.getEnv("SUPABASE_URL");
    const serviceRoleKey = runtime.getEnv("SUPABASE_SERVICE_ROLE_KEY");
    if (
      ip === null ||
      !salt ||
      salt.length < 32 ||
      !supabaseUrl ||
      !serviceRoleKey
    ) {
      return respond({ code: "service_unavailable" }, 503, origin);
    }

    const ipHash = await hmacSha256(ip, salt);
    let rpcResponse: Response;
    try {
      rpcResponse = await fetchUpstream(
        `${supabaseUrl.replace(/\/$/, "")}/rest/v1/rpc/report_parking_event`,
        {
          method: "POST",
          headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            p_event_type: eventType,
            p_lat: latitude,
            p_lon: longitude,
            p_client_token: clientToken,
            p_ip_hash: ipHash,
            p_dry_run: false,
          }),
        },
      );
    } catch {
      return respond({ code: "upstream_unavailable" }, 502, origin);
    }

    if (!rpcResponse.ok) {
      const error = (await rpcResponse.text()).toLowerCase();
      if (error.includes("rate_limit")) {
        return respond({ code: "rate_limited" }, 429, origin);
      }
      if (error.includes("invalid_")) {
        return respond({ code: "invalid_report" }, 400, origin);
      }
      return respond({ code: "upstream_unavailable" }, 502, origin);
    }

    return respond({ ok: true }, 200, origin);
  };
}

if (import.meta.main) {
  Deno.serve(createHandler());
}
