/**
 * Spike round 2: fix truncated body parse; confirm native PDF works for classify.
 */
import { existsSync } from "node:fs";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  GATEWAY_MODEL,
  GATEWAY_URL,
  ORGANIZE_DIR,
  TEXT_CAP,
} from "../src/config.ts";
import {
  classifyWithGateway,
  loadGatewayApiKey,
  type ClassifyResult,
} from "../src/gateway.ts";
import { extractText } from "../src/extract.ts";
import {
  cleanupTempImage,
  needsVision,
  refineHotelFolioResult,
  renderPdfPage1,
} from "../src/vision.ts";

const INVOICE_DIR = join(process.env.HOME!, "Downloads/Invoices");
const SAMPLES = [
  {
    file: "comfort-suites-03-aug-26.pdf",
    expected: "comfort-suites-03-aug-26",
    vendor: "comfort-suites",
  },
  {
    file: "woolworths-01-jun-25.pdf",
    expected: "woolworths-01-jun-25",
    vendor: "woolworths",
  },
  {
    file: "vercel-04-aug-26.pdf",
    expected: "vercel-04-aug-26",
    vendor: "vercel",
  },
] as const;

type BuildPart = (b64: string, fn: string) => unknown;

const VARIANTS: { id: string; build: BuildPart }[] = [
  {
    id: "file.file_data_dataurl",
    build: (b64, fn) => ({
      type: "file",
      file: {
        filename: fn,
        file_data: `data:application/pdf;base64,${b64}`,
      },
    }),
  },
  {
    id: "file.data_media_type",
    build: (b64, fn) => ({
      type: "file",
      file: {
        filename: fn,
        data: b64,
        media_type: "application/pdf",
      },
    }),
  },
];

async function gatewayChat(
  apiKey: string,
  userContent: unknown,
): Promise<{ ok: boolean; status: number; content: string; err?: string; ms: number; rawSnippet: string }> {
  const t0 = performance.now();
  const res = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: GATEWAY_MODEL,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            "You classify downloaded files. Reply with a single JSON object only.",
        },
        { role: "user", content: userContent },
      ],
    }),
  });
  const ms = Math.round(performance.now() - t0);
  const body = await res.text();
  if (!res.ok) {
    return {
      ok: false,
      status: res.status,
      content: "",
      err: body.slice(0, 300),
      ms,
      rawSnippet: body.slice(0, 200),
    };
  }
  try {
    const data = JSON.parse(body) as {
      choices?: Array<{ message?: { content?: string } }>;
      error?: { message?: string };
    };
    if (data.error) {
      return {
        ok: false,
        status: res.status,
        content: "",
        err: data.error.message ?? JSON.stringify(data.error),
        ms,
        rawSnippet: body.slice(0, 200),
      };
    }
    const content = data.choices?.[0]?.message?.content ?? "";
    return { ok: true, status: res.status, content, ms, rawSnippet: content.slice(0, 200) };
  } catch (e) {
    return {
      ok: false,
      status: res.status,
      content: "",
      err: `json parse: ${e}`,
      ms,
      rawSnippet: body.slice(0, 200),
    };
  }
}

function parseClassify(raw: string): ClassifyResult {
  let s = raw.trim();
  if (s.startsWith("```")) {
    s = s.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  }
  let obj: Record<string, unknown> = {};
  try {
    obj = JSON.parse(s) as Record<string, unknown>;
  } catch {
    const m = s.match(/\{[\s\S]*\}/);
    if (m) {
      try {
        obj = JSON.parse(m[0]) as Record<string, unknown>;
      } catch {
        /* */
      }
    }
  }
  const category = String(obj.category ?? "Misc");
  const name =
    String(obj.name ?? "untitled")
      .toLowerCase()
      .replace(/\.[a-z0-9]{1,8}$/i, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 80) || "untitled";
  return { category: category as ClassifyResult["category"], name };
}

function score(
  result: ClassifyResult,
  expected: string,
  vendor: string,
): { exact: boolean; vendorOk: boolean; woolOk: boolean; label: string } {
  const gotVendor = result.name.replace(
    /-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/,
    "",
  );
  const exact = result.category === "Invoices" && result.name === expected;
  const vendorOk =
    (result.category === "Invoices" && gotVendor === vendor) ||
    (vendor === "woolworths" &&
      (result.category === "Documents" || result.name.startsWith("woolworths")));
  const junkDate =
    vendor === "woolworths" &&
    result.category === "Invoices" &&
    /-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/.test(
      result.name,
    ) &&
    result.name !== expected;
  return {
    exact,
    vendorOk,
    woolOk: vendor !== "woolworths" || !junkDate,
    label: `${result.category}/${result.name}`,
  };
}

function classifyPrompt(filename: string, text: string, mode: "pdf" | "image"): string {
  return (
    `You organize one downloaded file. Reply with ONE JSON object only:
{"category":"<Category>","name":"<basename-without-extension>"}

Categories (pick exactly one):
- Invoices — receipts, invoices, bills, statements, subscription charges, tax payments (charge/total + merchant)
- Images — photos, screenshots, diagrams
- Documents — non-payment PDFs/docs. Also use Documents when payment-related but no clear paid/issue date (do NOT invent dates).
- Data — spreadsheets, CSV
- Code — archives, installers
- Media — video/audio
- Resumes — CV / resume
- Misc — only if nothing else fits

NAME rules (lowercase kebab, no extension, ≤60 chars):
Invoices → name MUST be vendor-dd-mon-yy:
- vendor = who ISSUED/CHARGED, 1–3 tokens (github, vercel, woolworths, comfort-suites)
- NEVER Bill-to / customer / Amex
- Prefer Date paid / Payment date / Invoice date / folio header Date — NEVER Arrival/Departure
- NEVER invent a date → Documents + short kebab
- month MUST be jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec
- Hotel folios: header Date uses M/D/YY (8/3/26 = 03-aug-26)
- Gift card / Prezzee / eGift with no clear paid date → Documents + short kebab (e.g. woolworths-egift)

FILENAME: ${filename}

FILE TEXT:
` +
    text.slice(0, TEXT_CAP) +
    (mode === "pdf"
      ? "\n\nPDF DOCUMENT: the full PDF is attached. Prefer dates/vendor visible in the PDF when text is ambiguous.\n"
      : "\n\nPAGE IMAGE: page 1 attached. Prefer dates/vendor in the image when text is ambiguous.\n")
  );
}

async function main() {
  const apiKey = await loadGatewayApiKey();
  if (!apiKey) throw new Error("no key");

  console.log(`model=${GATEWAY_MODEL}`);

  // Quick probe with FULL body parse
  const probePdf = join(INVOICE_DIR, "vercel-04-aug-26.pdf");
  const probeB64 = (await readFile(probePdf)).toString("base64");
  const working: typeof VARIANTS = [];

  console.log("--- PROBE (full body) ---");
  for (const v of VARIANTS) {
    const r = await gatewayChat(apiKey, [
      {
        type: "text",
        text: 'Reply JSON only: {"category":"Invoices","name":"vercel-04-aug-26"}',
      },
      v.build(probeB64, "vercel-04-aug-26.pdf"),
    ]);
    if (r.ok && r.content) {
      working.push(v);
      console.log(`PROBE ${v.id} OK ${r.ms}ms → ${r.content.slice(0, 160)}`);
    } else {
      console.log(`PROBE ${v.id} FAIL ${r.ms}ms status=${r.status} err=${r.err?.slice(0, 200)}`);
    }
  }

  // Also try PDF-only (no extract text) to prove the model READS the PDF
  console.log("\n--- PDF-ONLY (no extract text) — proves native read ---");
  if (working.length) {
    const v = working[0]!;
    for (const s of SAMPLES) {
      const pdfPath = join(INVOICE_DIR, s.file);
      const b64 = (await readFile(pdfPath)).toString("base64");
      const prompt =
        `You organize one downloaded PDF. Reply with ONE JSON object only:
{"category":"<Category>","name":"<basename-without-extension>"}
Invoices → vendor-dd-mon-yy (vendor who charged; month jan..dec; NEVER invent dates — use Documents).
Hotel: folio header Date M/D/YY, not Arrival/Departure.
Gift card without paid date → Documents.
FILENAME: ${s.file}
The PDF is attached — read it.`;
      const r = await gatewayChat(apiKey, [
        { type: "text", text: prompt },
        v.build(b64, s.file),
      ]);
      if (!r.ok) {
        console.log(`PDFONLY ${s.file} FAIL ${r.ms}ms ${r.err?.slice(0, 160)}`);
        continue;
      }
      const result = parseClassify(r.content);
      const sc = score(result, s.expected, s.vendor);
      console.log(
        `PDFONLY ${s.file.padEnd(32)} ${r.ms}ms ${sc.label} exact=${sc.exact} vendor=${sc.vendorOk} woolOk=${sc.woolOk}`,
      );
    }
  } else {
    console.log("No working variants — skip pdf-only");
  }

  const preferred = working[0] ?? null;
  const rows: Array<Record<string, unknown>> = [];

  console.log("\n--- COMPARE text / image / native (with extract text) ---");
  for (const s of SAMPLES) {
    const pdfPath = join(INVOICE_DIR, s.file);
    const text = await extractText(pdfPath);
    console.log(`\n### ${s.file} needsVision=${needsVision(text)} textLen=${text.length}`);

    // text
    {
      const t0 = performance.now();
      let result = await classifyWithGateway(text, { apiKey, filename: s.file });
      result = refineHotelFolioResult(text, result);
      const ms = Math.round(performance.now() - t0);
      const sc = score(result, s.expected, s.vendor);
      console.log(`  text-only   ${ms}ms ${sc.label} exact=${sc.exact} woolOk=${sc.woolOk}`);
      rows.push({ sample: s.file, mode: "text-only", ms, ...sc, result: sc.label });
    }

    // image
    {
      let imagePath: string | null = null;
      try {
        const t0 = performance.now();
        imagePath = await renderPdfPage1(pdfPath);
        let result = await classifyWithGateway(text, {
          apiKey,
          filename: s.file,
          imagePath: imagePath ?? undefined,
        });
        result = refineHotelFolioResult(text, result);
        const ms = Math.round(performance.now() - t0);
        const sc = score(result, s.expected, s.vendor);
        console.log(`  image-png   ${ms}ms ${sc.label} exact=${sc.exact} woolOk=${sc.woolOk}`);
        rows.push({ sample: s.file, mode: "image-png", ms, ...sc, result: sc.label });
      } finally {
        await cleanupTempImage(imagePath);
      }
    }

    // native
    if (preferred) {
      const b64 = (await readFile(pdfPath)).toString("base64");
      const content = [
        { type: "text", text: classifyPrompt(s.file, text, "pdf") },
        preferred.build(b64, s.file),
      ];
      const r = await gatewayChat(apiKey, content);
      if (!r.ok) {
        console.log(`  native-pdf  ${r.ms}ms ERR ${r.err?.slice(0, 120)}`);
        rows.push({ sample: s.file, mode: `native:${preferred.id}`, ms: r.ms, exact: false, woolOk: false, result: `ERR` });
      } else {
        let result = parseClassify(r.content);
        result = refineHotelFolioResult(text, result);
        const sc = score(result, s.expected, s.vendor);
        console.log(
          `  native-pdf  ${r.ms}ms ${sc.label} exact=${sc.exact} woolOk=${sc.woolOk} variant=${preferred.id}`,
        );
        rows.push({
          sample: s.file,
          mode: `native:${preferred.id}`,
          ms: r.ms,
          ...sc,
          result: sc.label,
        });
      }
    }
  }

  const out = join(ORGANIZE_DIR, "spikes/bench-results/nova-pdf-native2.json");
  await mkdir(join(ORGANIZE_DIR, "spikes/bench-results"), { recursive: true });
  await writeFile(
    out,
    JSON.stringify(
      {
        model: GATEWAY_MODEL,
        working: working.map((w) => w.id),
        preferred: preferred?.id ?? null,
        rows,
        at: new Date().toISOString(),
      },
      null,
      2,
    ),
  );
  console.log(`\nWrote ${out}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
