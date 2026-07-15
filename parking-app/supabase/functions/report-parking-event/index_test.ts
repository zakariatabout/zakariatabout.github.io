import {
  allowedOrigin,
  createHandler,
  type EdgeRuntime,
  requesterIp,
} from "./index.ts";

const productionOrigin = "https://zakariatabout.github.io";
const validToken = "a".repeat(32);
const baseEnv: Record<string, string> = {
  ALLOWED_ORIGINS: productionOrigin,
  REPORTER_HASH_SALT: "s".repeat(32),
  SUPABASE_URL: "https://project.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-test",
  PARKRADAR_PUBLISHABLE_KEY: "publishable-key-test-value",
  HEALTHCHECK_TOKEN: "health-check-secret-value".repeat(2),
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function responseCode(response: Response): Promise<string | undefined> {
  const payload = await response.json() as Record<string, unknown>;
  return payload.code as string | undefined;
}

function runtime(
  fetcher: EdgeRuntime["fetch"],
  env: Record<string, string> = baseEnv,
): EdgeRuntime {
  return {
    getEnv: (name) => env[name],
    fetch: fetcher,
  };
}

function reportRequest(
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://edge.test/report-parking-event", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: baseEnv.PARKRADAR_PUBLISHABLE_KEY,
      origin: productionOrigin,
      "x-forwarded-for": "198.51.100.24, 10.0.0.1",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

Deno.test("CORS accepte exactement GitHub Pages et le localhost", async () => {
  assert(allowedOrigin(productionOrigin) === productionOrigin, "origine prod");
  assert(
    allowedOrigin("https://zakariatabout.github.io.evil.test") === null,
    "un suffixe hostile ne doit pas passer",
  );
  assert(
    allowedOrigin("http://localhost:8080") === "http://localhost:8080",
    "localhost doit rester testable",
  );

  const handler = createHandler(
    runtime(() => Promise.reject(new Error("aucun appel attendu"))),
  );
  const response = await handler(
    new Request("https://edge.test/report-parking-event", {
      method: "OPTIONS",
      headers: { origin: productionOrigin },
    }),
  );
  assert(response.status === 200, "le preflight doit réussir");
  assert(
    response.headers.get("access-control-allow-origin") === productionOrigin,
    "ACAO doit refléter uniquement l'origine autorisée",
  );
  assert(
    response.headers.get("access-control-allow-headers")?.includes("apikey"),
    "le preflight doit autoriser apikey",
  );
});

Deno.test("une origine non autorisée est refusée avant le traitement", async () => {
  let fetched = false;
  const handler = createHandler(
    runtime(() => {
      fetched = true;
      return Promise.resolve(new Response("true"));
    }),
  );
  const response = await handler(
    reportRequest(
      {
        event_type: "parked",
        lat: 48.856,
        lon: 2.352,
        client_token: validToken,
      },
      { origin: "https://evil.test" },
    ),
  );
  assert(response.status === 403, "l'origine doit être refusée");
  assert(await responseCode(response) === "origin_not_allowed", "code CORS");
  assert(!fetched, "aucun appel amont ne doit partir");
});

Deno.test("une requête sans clé publishable configurée est refusée", async () => {
  const handler = createHandler(
    runtime(() => Promise.reject(new Error("aucun appel attendu"))),
  );
  const response = await handler(
    reportRequest(
      {
        event_type: "parked",
        lat: 48.856,
        lon: 2.352,
        client_token: validToken,
      },
      { apikey: "wrong-key" },
    ),
  );
  assert(response.status === 401, "la clé incorrecte doit être refusée");
  assert(await responseCode(response) === "invalid_api_key", "code API key");
});

Deno.test("la validation refuse type, coordonnées et jeton invalides", async () => {
  const handler = createHandler(
    runtime(() => Promise.reject(new Error("aucun appel attendu"))),
  );
  const cases: Array<[Record<string, unknown>, string]> = [
    [
      {
        event_type: "unknown",
        lat: 48.856,
        lon: 2.352,
        client_token: validToken,
      },
      "invalid_event_type",
    ],
    [
      { event_type: "parked", lat: 48.7, lon: 2.352, client_token: validToken },
      "invalid_coordinates",
    ],
    [
      { event_type: "parked", lat: 48.856, lon: 2.352, client_token: "court" },
      "invalid_client_token",
    ],
  ];
  for (const [body, code] of cases) {
    const response = await handler(reportRequest(body));
    assert(response.status === 400, `${code} doit répondre 400`);
    assert(await responseCode(response) === code, `code ${code} attendu`);
  }
});

Deno.test("l IP issue de X-Forwarded-For est hachée et jamais transmise en clair", async () => {
  let upstreamBody: Record<string, unknown> | undefined;
  let upstreamSignal: AbortSignal | null | undefined;
  const handler = createHandler(
    runtime((_input, init) => {
      upstreamBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      upstreamSignal = init?.signal;
      return Promise.resolve(new Response("true", { status: 200 }));
    }),
  );
  const response = await handler(
    reportRequest({
      event_type: "freed",
      lat: 48.856,
      lon: 2.352,
      client_token: validToken,
    }),
  );

  assert(response.status === 200, "le rapport valide doit réussir");
  assert(upstreamBody !== undefined, "la RPC doit être appelée");
  assert(
    /^[0-9a-f]{64}$/.test(String(upstreamBody.p_ip_hash)),
    "le HMAC doit contenir 64 caractères hexadécimaux",
  );
  assert(
    !JSON.stringify(upstreamBody).includes("198.51.100.24"),
    "l'IP brute ne doit pas atteindre PostgREST",
  );
  assert(upstreamBody.p_client_token === validToken, "jeton transmis à la RPC");
  assert(
    upstreamBody.p_dry_run === false,
    "une écriture réelle n'est pas sèche",
  );
  assert(upstreamSignal !== undefined, "l'appel amont doit être annulable");
});

Deno.test("la priorité X-Forwarded-For empêche x-real-ip de la remplacer", () => {
  const request = new Request("https://edge.test", {
    headers: {
      "x-forwarded-for": "198.51.100.24, 10.0.0.1",
      "x-real-ip": "203.0.113.99",
    },
  });
  assert(requesterIp(request) === "198.51.100.24", "première IP du relais");
});

Deno.test("les secrets ou l IP absents échouent avant la RPC", async () => {
  let fetched = false;
  const handler = createHandler(
    runtime(
      () => {
        fetched = true;
        return Promise.resolve(new Response("true"));
      },
      { ...baseEnv, REPORTER_HASH_SALT: "court" },
    ),
  );
  const response = await handler(
    reportRequest({
      event_type: "parked",
      lat: 48.856,
      lon: 2.352,
      client_token: validToken,
    }),
  );
  assert(response.status === 503, "secret invalide => indisponible");
  assert(!fetched, "aucune RPC ne doit être appelée");
});

Deno.test("les erreurs RPC sont traduites sans divulguer leur corps", async () => {
  for (
    const [body, expectedStatus, expectedCode] of [
      ["rate_limit_short", 429, "rate_limited"],
      ["database unavailable", 502, "upstream_unavailable"],
    ] as const
  ) {
    const handler = createHandler(
      runtime(() => Promise.resolve(new Response(body, { status: 400 }))),
    );
    const response = await handler(
      reportRequest({
        event_type: "parked",
        lat: 48.856,
        lon: 2.352,
        client_token: validToken,
      }),
    );
    assert(response.status === expectedStatus, `statut ${expectedStatus}`);
    assert(await responseCode(response) === expectedCode, expectedCode);
  }
});

Deno.test("la santé Edge exige le contrat complet du backend", async () => {
  const requestedUrls: string[] = [];
  let writeProbe: Record<string, unknown> | undefined;
  const handler = createHandler(
    runtime((input, init) => {
      requestedUrls.push(String(input));
      if (String(input).endsWith("/rpc/report_parking_event")) {
        writeProbe = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return Promise.resolve(new Response("true", { status: 200 }));
      }
      return Promise.resolve(
        Response.json({
          schema_version: "2026-07-p0-v4",
          purge_job_active: true,
          purge_last_run_at: "2026-07-15T12:00:00Z",
          purge_last_run_succeeded: true,
          anon_table_access: false,
          authenticated_table_access: false,
          anon_report_execute: false,
          authenticated_report_execute: false,
          service_report_execute: true,
        }),
      );
    }),
  );
  const response = await handler(
    new Request("https://edge.test/report-parking-event", {
      headers: {
        origin: productionOrigin,
        apikey: baseEnv.PARKRADAR_PUBLISHABLE_KEY,
        "x-parkradar-health-token": baseEnv.HEALTHCHECK_TOKEN,
        "x-forwarded-for": "198.51.100.24",
      },
    }),
  );
  assert(response.status === 200, "la santé complète doit réussir");
  assert(
    requestedUrls.some((url) => url.endsWith("/rpc/report_parking_event")),
    "sonde sèche du chemin d'écriture",
  );
  assert(
    requestedUrls.some((url) => url.endsWith("/rpc/community_edge_health")),
    "sonde privée service_role",
  );
  assert(writeProbe?.p_dry_run === true, "la sonde doit être transactionnelle");
  assert(
    writeProbe?.p_lat === 48.801 && writeProbe?.p_lon === 2.221,
    "la sonde doit utiliser la cellule sentinelle",
  );
});

Deno.test("la clé publique seule ne peut pas déclencher la sonde d'écriture", async () => {
  let fetched = false;
  const handler = createHandler(
    runtime(() => {
      fetched = true;
      return Promise.resolve(new Response("true"));
    }),
  );
  const response = await handler(
    new Request("https://edge.test/report-parking-event", {
      headers: {
        apikey: baseEnv.PARKRADAR_PUBLISHABLE_KEY,
        "x-forwarded-for": "198.51.100.24",
      },
    }),
  );
  assert(response.status === 401, "le secret de santé doit être obligatoire");
  assert(
    await responseCode(response) === "health_unauthorized",
    "code de refus santé",
  );
  assert(!fetched, "aucune transaction ne doit partir sans secret de santé");
});
