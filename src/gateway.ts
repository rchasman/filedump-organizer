import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  CATEGORIES,
  GATEWAY_MODEL,
  GATEWAY_URL,
  ORGANIZE_DIR,
  TEXT_CAP,
  type Category,
  isCategory,
} from "./config.ts";

export type ClassifyResult = {
  category: Category;
  name: string;
};

const CLASSIFY_PROMPT = `You organize one downloaded file. Reply with ONE JSON object only:
{"category":"<Category>","name":"<basename-without-extension>"}

Categories (pick exactly one):
- Invoices — receipts, invoices, bills, statements, subscription charges, tax payments (charge/total + merchant)
- Images — photos, screenshots, diagrams (actual image files / image-primary content — NOT a PDF receipt whose filename looks like a photo)
- Documents — non-payment PDFs/docs (specs, letters, reports, proposals). Also use Documents when it is a payment-related PDF but you cannot find a clear paid/issue date (do NOT invent dates).
- Data — spreadsheets, CSV, tabular exports
- Code — archives, installers, licenses, IDE/extension packages
- Media — video/audio
- Resumes — CV / resume
- Misc — only if nothing else fits

NAME rules (lowercase kebab, no extension, ≤60 chars):

Invoices → name MUST be vendor-dd-mon-yy:
- vendor = who ISSUED/CHARGED (header/From/support domain), 1–3 tokens
  Examples: github, vercel, google, neon, uber-eats, woolworths, comfort-suites, huggingface
  Short brand wins: "Google Cloud" → google (not google-cloud); "Woolworths Group Limited" → woolworths; "Hugging Face Inc" → huggingface
- NEVER Bill-to / Account billed / customer / email / person
- NEVER Amex/Visa/Mastercard as vendor
- Delivery apps: vendor = platform (uber-eats), ignore restaurant name
- Gift-card intermediaries (Prezzee etc.): vendor = the store brand (woolworths), not the intermediary
- Date selection (critical):
  - Prefer: Date paid, Payment date, Order completed, Transaction date, Invoice date
  - Hotel folios: use folio header "Date:" / print/issue date — NEVER Arrival Date or Departure Date
  - Statements: statement period END
  - NEVER invent a date. No clear paid/issue/folio date → category Documents + short kebab (not vendor-dd-mon-yy)
- month MUST be jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec (never digits or full month words in the name)
- day 01–31; year exactly 2 digits

Resumes → short kebab, prefer *-resume.
Other → short descriptive kebab from content; filename is a weak hint only.

FILENAME: __FILENAME__

FILE TEXT:
`;

function parseEnvFile(contents: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of contents.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    out[key] = val;
  }
  return out;
}

export async function loadGatewayApiKey(): Promise<string | null> {
  if (process.env.AI_GATEWAY_API_KEY?.trim()) {
    return process.env.AI_GATEWAY_API_KEY.trim();
  }
  const path = join(ORGANIZE_DIR, ".env.gateway");
  if (!existsSync(path)) return null;
  try {
    const env = parseEnvFile(await readFile(path, "utf8"));
    return env.AI_GATEWAY_API_KEY?.trim() || null;
  } catch {
    return null;
  }
}

function parseJsonLoose(raw: string): Record<string, unknown> {
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    const m = raw.match(/\{[\s\S]*\}/);
    if (m) {
      try {
        return JSON.parse(m[0]) as Record<string, unknown>;
      } catch {
        /* fall through */
      }
    }
    return {};
  }
}

function sanitizeName(raw: string): string {
  return String(raw || "")
    .toLowerCase()
    .replace(/\.[a-z0-9]{1,8}$/i, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 80);
}


/** Output formatting for known long/noisy vendor slugs (not receipt parsing). */
function normalizeVendorSlug(name: string, category: Category): string {
  if (category !== "Invoices") return name;
  const m = name.match(
    /^([a-z]+(?:-[a-z]+)*)-([0-9]{2})-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-([0-9]{2})$/,
  );
  if (!m) return name;
  let vendor = m[1]!;
  const aliases: Record<string, string> = {
    "google-cloud": "google",
    "google-cloud-platform": "google",
    "hugging-face": "huggingface",
    "woolworths-group": "woolworths",
    "comfort-suites-at-sabino-canyon": "comfort-suites",
    "comfort-suites-sabino-canyon": "comfort-suites",
  };
  vendor = aliases[vendor] ?? vendor;
  // Keep at most 3 kebab tokens in vendor
  const parts = vendor.split("-").filter(Boolean);
  if (parts.length > 3) vendor = parts.slice(0, 2).join("-");
  return `${vendor}-${m[2]}-${m[3]}-${m[4]}`;
}

/** One gateway chat/completions call → {category, name}. */
export async function classifyWithGateway(
  text: string,
  opts?: { model?: string; apiKey?: string; filename?: string },
): Promise<ClassifyResult> {
  const apiKey = opts?.apiKey ?? (await loadGatewayApiKey());
  if (!apiKey) {
    throw new Error("AI_GATEWAY_API_KEY missing (.env.gateway or env)");
  }
  const model = opts?.model ?? GATEWAY_MODEL;
  const body = {
    model,
    temperature: 0,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content:
          "You classify downloaded files. Reply with a single JSON object only.",
      },
      {
        role: "user",
        content:
          CLASSIFY_PROMPT.replace("__FILENAME__", opts?.filename ?? "(unknown)") +
          text.slice(0, TEXT_CAP),
      },
    ],
  };

  const res = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const detail = (await res.text().catch(() => "")).slice(0, 300);
    throw new Error(`Gateway HTTP ${res.status}: ${detail}`);
  }

  const data = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const raw = data.choices?.[0]?.message?.content ?? "{}";
  const obj = parseJsonLoose(raw);

  const categoryRaw = String(obj.category ?? "Misc");
  const category: Category = isCategory(categoryRaw) ? categoryRaw : "Misc";
  let name = sanitizeName(String(obj.name ?? "untitled")) || "untitled";
  name = normalizeVendorSlug(name, category);

  return { category, name };
}
