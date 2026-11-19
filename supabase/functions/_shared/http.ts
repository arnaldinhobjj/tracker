// JSON, CORS and error helpers shared by every Edge Function.
// Error bodies follow the contract: {"error": "<code>", "message": "<human text>"}.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-dayledger-attest-key, x-dayledger-attest-assertion",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

export function errorResponse(status: number, code: string, message: string): Response {
  return json({ error: code, message }, status);
}

/** Parses a JSON object body or throws a 400. */
export async function readJsonObject(req: Request): Promise<Record<string, unknown>> {
  return (await readJsonObjectWithRaw(req)).body;
}

/** Like `readJsonObject`, also returning the exact bytes (App Attest signs those). */
export async function readJsonObjectWithRaw(
  req: Request,
): Promise<{ body: Record<string, unknown>; raw: Uint8Array }> {
  const raw = new Uint8Array(await req.arrayBuffer());
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new HttpError(400, "invalid_json", "Request body must be a JSON object.");
  }
  return { body: body as Record<string, unknown>, raw };
}

/** Returns the raw bearer token from the Authorization header, or throws a 401. */
export function bearerToken(req: Request): string {
  const header = req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) {
    throw new HttpError(401, "unauthorized", "Missing bearer token.");
  }
  return match[1];
}

/**
 * Wraps a handler with CORS preflight handling, a method check and uniform error responses.
 * Unexpected errors are logged and returned as 500 without internal details.
 */
export function handler(
  methods: string[],
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }
    if (!methods.includes(req.method)) {
      return errorResponse(405, "method_not_allowed", `Use ${methods.join(" or ")}.`);
    }
    try {
      return await fn(req);
    } catch (error) {
      if (error instanceof HttpError) {
        return errorResponse(error.status, error.code, error.message);
      }
      console.error("Unhandled error", error);
      return errorResponse(500, "internal_error", "Something went wrong. Please try again.");
    }
  };
}
