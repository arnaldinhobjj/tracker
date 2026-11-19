// AI scheduling suggestions for DayLedger Pro, run on the server with DayLedger's own Anthropic key
// (users no longer paste their own). The app sends only the anonymised routine summary it already
// shows the user ("Preview what would be sent"); this module re-validates it against an allowlist,
// builds the prompt and calls Anthropic. Nothing is stored: neither the summary nor the answer.

import { HttpError } from "./http.ts";
import { optionalEnv, requireEnv } from "./env.ts";

export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_VERSION = "2026-10-21";
export const FALLBACK_BETA = "server-side-fallback-2026-07-01";
export const DEFAULT_MODEL = "claude-opus-5-5";
export const DEFAULT_DAILY_LIMIT = 20;
const UPSTREAM_TIMEOUT_MS = 110_000;
const MAX_SUMMARY_BYTES = 32_768;

export interface AIConfig {
  apiKey: string;
  model: string;
  dailyLimit: number;
}

export function aiConfigFromEnv(): AIConfig {
  const limit = Number(optionalEnv("AI_DAILY_LIMIT") ?? DEFAULT_DAILY_LIMIT);
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new Error("AI_DAILY_LIMIT must be a positive integer");
  }
  return {
    apiKey: requireEnv("ANTHROPIC_API_KEY"),
    model: optionalEnv("ANTHROPIC_MODEL") ?? DEFAULT_MODEL,
    dailyLimit: limit,
  };
}

export const SYSTEM_PROMPT =
  `You are the scheduling assistant inside DayLedger, a personal app that logs the places a person \
visits and what they spend. You receive an anonymised summary of their recent routine: the named \
places they visit with typical days and hours, average weekly spending by category, and the times \
they are already busy.

Suggest upcoming calendar events that fit the routine you can see, such as a weekly food shop at \
the usual supermarket and time, or a gym session at their usual hour. Only suggest events \
supported by a repeated pattern in the data (at least two visits), and say which pattern in \
\`reason\`, in one short sentence. Use the place name in the title where it helps \
(for example "Food shop at Tesco").

Rules:
- Every event must start after \`today\` and within \`planningWindowDays\` days.
- Never overlap a \`busy\` block.
- Use the user's time zone, given in \`timeZone\`; write \`start\` as ISO 8601 with a UTC offset.
- \`durationMinutes\` between 5 and 480, based on the typical visit duration.
- At most 8 proposals. Return an empty list if no pattern is strong enough; that is a fine answer.
- Use \`confidence\` "high" only for patterns seen most weeks.`;

/** Structured-output schema. Ranges are validated again on the device (`ProposalParser`). */
export const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    proposals: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          start: { type: "string", format: "date-time" },
          durationMinutes: { type: "integer" },
          reason: { type: "string" },
          confidence: { type: "string", enum: ["low", "medium", "high"] },
        },
        required: ["title", "start", "durationMinutes", "reason", "confidence"],
        additionalProperties: false,
      },
    },
  },
  required: ["proposals"],
  additionalProperties: false,
};

// ---------------------------------------------------------------------------------------------
// The summary: only the fields the app's RoutineSummary has, with bounded sizes. Anything else is
// dropped, so the endpoint can't be used as a general-purpose prompt proxy.
// ---------------------------------------------------------------------------------------------

export interface RoutineSummary {
  today: string;
  timeZone: string;
  periodDays: number;
  planningWindowDays: number;
  places: {
    name: string;
    category: string | null;
    visitsInPeriod: number;
    typicalDurationMinutes: number;
    typicalSlots: { weekday: string; hour: number; count: number }[];
  }[];
  spending: { category: string; weeklyAverageRoundedGBP: number }[];
  busy: { start: string; end: string }[];
}

function bad(field: string): never {
  throw new HttpError(400, "invalid_summary", `The routine summary has an invalid ${field}.`);
}

function str(value: unknown, field: string, max: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > max) bad(field);
  return value;
}

function int(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    bad(field);
  }
  return value;
}

function list(value: unknown, field: string, max: number): unknown[] {
  if (!Array.isArray(value) || value.length > max) bad(field);
  return value;
}

function obj(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) bad(field);
  return value as Record<string, unknown>;
}

export function parseSummary(body: Record<string, unknown>): RoutineSummary {
  if (JSON.stringify(body).length > MAX_SUMMARY_BYTES) {
    throw new HttpError(413, "summary_too_large", "The routine summary is too large.");
  }
  const s = obj(body.summary, "summary");
  return {
    today: str(s.today, "today", 40),
    timeZone: str(s.timeZone, "timeZone", 64),
    periodDays: int(s.periodDays, "periodDays", 1, 366),
    planningWindowDays: int(s.planningWindowDays, "planningWindowDays", 1, 60),
    places: list(s.places, "places", 30).map((raw) => {
      const p = obj(raw, "place");
      return {
        name: str(p.name, "place name", 120),
        category: p.category === null || p.category === undefined
          ? null
          : str(p.category, "place category", 80),
        visitsInPeriod: int(p.visitsInPeriod, "visitsInPeriod", 0, 10_000),
        typicalDurationMinutes: int(p.typicalDurationMinutes, "typicalDurationMinutes", 0, 1_440),
        typicalSlots: list(p.typicalSlots, "typicalSlots", 10).map((rawSlot) => {
          const slot = obj(rawSlot, "slot");
          return {
            weekday: str(slot.weekday, "weekday", 12),
            hour: int(slot.hour, "hour", 0, 23),
            count: int(slot.count, "slot count", 0, 10_000),
          };
        }),
      };
    }),
    spending: list(s.spending, "spending", 20).map((raw) => {
      const item = obj(raw, "spending item");
      return {
        category: str(item.category, "spending category", 60),
        weeklyAverageRoundedGBP: int(item.weeklyAverageRoundedGBP, "weekly average", 0, 1_000_000),
      };
    }),
    busy: list(s.busy, "busy", 300).map((raw) => {
      const block = obj(raw, "busy block");
      return { start: str(block.start, "busy start", 40), end: str(block.end, "busy end", 40) };
    }),
  };
}

/** JSON with sorted keys and two-space indentation (what the app's preview shows). */
export function stableStringify(value: unknown): string {
  const sort = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(sort);
    if (v && typeof v === "object") {
      return Object.fromEntries(
        Object.keys(v as Record<string, unknown>).sort().map((
          k,
        ) => [k, sort((v as Record<string, unknown>)[k])]),
      );
    }
    return v;
  };
  return JSON.stringify(sort(value), null, 2);
}

export function userMessage(summary: RoutineSummary): string {
  return `Here is my routine summary. Suggest events for the planning window.\n\n${
    stableStringify(summary)
  }`;
}

export function anthropicRequest(summary: RoutineSummary, config: AIConfig): RequestInit {
  return {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": config.apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
      "anthropic-beta": FALLBACK_BETA,
    },
    body: JSON.stringify({
      model: config.model,
      max_tokens: 16_000,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: userMessage(summary) }],
      output_config: { effort: "medium", format: { type: "json_schema", schema: RESPONSE_SCHEMA } },
      // If a safety classifier declines, Anthropic retries on a fallback model in the same call.
      fallbacks: "default",
    }),
  };
}

/** Maps Anthropic's answer to the JSON text for the app, or an error the app understands. */
export function interpretAnthropicResponse(status: number, payload: unknown): string {
  if (status === 429) {
    throw new HttpError(503, "provider_busy", "The AI service is busy. Try again shortly.");
  }
  if (status === 529 || status === 503) {
    throw new HttpError(503, "provider_busy", "The AI service is overloaded. Try again shortly.");
  }
  if (status < 200 || status >= 300) {
    // Includes 401/403 (our key): never reported to the app as a sign-in problem.
    throw new HttpError(
      502,
      "provider_error",
      "The AI service returned an error. Try again later.",
    );
  }
  const body = payload as { content?: { type?: string; text?: string }[]; stop_reason?: string };
  if (body?.stop_reason === "refusal") {
    throw new HttpError(422, "refused", "The AI declined this request.");
  }
  if (body?.stop_reason === "max_tokens") {
    throw new HttpError(502, "truncated", "The AI's answer was incomplete. Try again.");
  }
  // Thinking and fallback blocks are skipped; the JSON is in the text block(s).
  const text = (body?.content ?? []).filter((block) => block?.type === "text")
    .map((block) => block.text ?? "").join("");
  if (!text) {
    throw new HttpError(502, "provider_invalid", "The AI service returned no text.");
  }
  return text;
}

export interface SuggestDeps {
  isEntitled(userId: string): Promise<boolean>;
  /** Counts one request for today; false when the daily limit is already reached. */
  consumeQuota(userId: string, limit: number): Promise<boolean>;
  fetch: typeof fetch;
}

/** The whole request: entitlement, quota, then the model. Returns the model's JSON text. */
export async function suggest(
  userId: string,
  body: Record<string, unknown>,
  config: AIConfig,
  deps: SuggestDeps,
): Promise<string> {
  const summary = parseSummary(body);
  if (!(await deps.isEntitled(userId))) {
    throw new HttpError(403, "not_entitled", "AI suggestions are part of DayLedger Pro.");
  }
  if (!(await deps.consumeQuota(userId, config.dailyLimit))) {
    throw new HttpError(
      429,
      "daily_limit",
      `You've reached today's limit of ${config.dailyLimit} suggestion requests. Try again tomorrow.`,
    );
  }
  let response: Response;
  try {
    response = await deps.fetch(ANTHROPIC_URL, {
      ...anthropicRequest(summary, config),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch {
    throw new HttpError(503, "provider_busy", "Couldn't reach the AI service. Try again shortly.");
  }
  let payload: unknown = undefined;
  try {
    payload = await response.json();
  } catch {
    // Handled by interpretAnthropicResponse.
  }
  return interpretAnthropicResponse(response.status, payload);
}
