/**
 * Spike: Nova 2 Lite native PDF document parts via Vercel AI Gateway.
 * Never prints API key. Logs latency + classify results.
 */
import { existsSync } from "node:fs";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
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
    note: "hotel folio — exact date critical",
  },
  {
    file: "woolworths-01-jun-25.pdf",
    expected: "woolworths-01-jun-25",
    vendor: "woolworths",
    note: "gift card — Documents / leave-alone OK; no junk invoice date",
  },
  {
    file: "vercel-04-aug-26.pdf",
    expected: "vercel-04-aug-26",
    vendor: "vercel",
    note: "control — text-only should already win",
  },
] as const;

type PartVariant = {
  id: string;
  build: (pdfB64: string, filename: string) => unknown;
};

const PROBE_VARIANTS: PartVariant[] = [
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
  {
    id: "file.file_data_raw",
    build: (b64, fn) => ({
      type: "file",
      file: {
        filename: fn,
        file_data: b64,
      },
    }),
  },
  {
    id: "input_file",
    build: (b64, fn) => ({
      type: "input_file",
      filename: fn,
      file_data: `data:application/pdf;base64,${b64}`,
    }),
  },
  {
    id: "document_anthropic",
    build: (b64) => ({
      type: "document",
      source: {
        type: "base64",
        media_type: "application/pdf",
        data: b64,
      },
    }),
  },
  {
    id: "file_url_dataurl",
    build: (b64) => ({
      type: "file_url",
      file_url: { url: `data:application/pdf;base64,${b64}` },
    }),
  },
];

async function rawGateway(
  apiKey: string,
  userContent: unknown,
  model = GATEWAY_MODEL,
): Promise<{ ok: boolean; status: number; body: string; ms: number }> {
  const t0 = performance.now();
  const res = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
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
  return { ok: res.ok, status: res.status, body: body.slice(0, 800), ms };
}

function parseClassify(raw: string): ClassifyResult {
  let obj: Record<string, unknown> = {};
  try {
    obj = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    const m = raw.match(/\{[\s\S]*\}/);
    if (m) {
      try {
        obj = JSON.parse(m[0]) as Record<string, unknown>;
      } catch {
        /* */
      }
    }
  }
  // If gateway wrapped choices
  if (!obj.category && typeof obj === "object") {
    try {
      const wrap = JSON.parse(raw) as {
        choices?: Array<{ message?: { content?: string } }>;
      };
      const c = wrap.choices?.[0]?.message?.content;
      if (c) return parseClassify(c);
    } catch {
      /* */
    }
  }
  const category = String(obj.category ?? "Misc");
  const name = String(obj.name ?? "untitled")
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
  sampleNote: string,
): { exact: boolean; vendorOk: boolean; woolOk: boolean; label: string } {
  const gotVendor = result.name.replace(
    /-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/,
    "",
  );
  const exact = result.category === "Invoices" && result.name === expected;
  const vendorOk =
    (result.category === "Invoices" && gotVendor === vendor) ||
    (vendor === "woolworths" &&
      (result.category === "Documents" ||
        result.name.startsWith("woolworths")));
  // woolworths: inventing a junk invoice date is BAD
  const junkDate =
    vendor === "woolworths" &&
    result.category === "Invoices" &&
    /-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/.test(
      result.name,
    ) &&
    result.name !== expected;
  const woolOk = vendor !== "woolworths" || !junkDate;
  return {
    exact,
    vendorOk,
    woolOk,
    label: `${result.category}/${result.name}`,
  };
}

async function classifyNativePdf(
  apiKey: string,
  text: string,
  filename: string,
  pdfPath: string,
  partBuilder: PartVariant["build"],
): Promise<{ result: ClassifyResult; ms: number; err?: string }> {
  const buf = await readFile(pdfPath);
  const b64 = buf.toString("base64");
  const promptText =
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
` + text.slice(0, TEXT_CAP) +
    "\n\nPDF DOCUMENT: the full PDF is attached as a document/file part. Prefer dates/vendor visible in the PDF when text is ambiguous.\n";

  const content = [
    { type: "text", text: promptText },
    partBuilder(b64, filename),
  ];

  const t0 = performance.now();
  const res = await rawGateway(apiKey, content);
  const ms = res.ms;
  if (!res.ok) {
    return {
      result: { category: "Misc", name: "error" },
      ms,
      err: `HTTP ${res.status}: ${res.body.slice(0, 200)}`,
    };
  }
  let contentStr = res.body;
  try {
    const data = JSON.parse(res.body) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    contentStr = data.choices?.[0]?.message?.content ?? res.body;
  } catch {
    /* */
  }
  return { result: parseClassify(contentStr), ms };
}

async function main() {
  const apiKey = await loadGatewayApiKey();
  if (!apiKey) throw new Error("no AI_GATEWAY_API_KEY");

  console.log(`model=${GATEWAY_MODEL} url=${GATEWAY_URL}`);
  console.log("--- PROBE: which PDF part formats does gateway+nova accept? ---");

  const probePdf = join(INVOICE_DIR, "vercel-04-aug-26.pdf");
  const probeBuf = await readFile(probePdf);
  const probeB64 = probeBuf.toString("base64");
  const workingVariants: string[] = [];

  for (const v of PROBE_VARIANTS) {
    const content = [
      {
        type: "text",
        text: 'Reply JSON only: {"category":"Invoices","name":"vercel-04-aug-26"}',
      },
      v.build(probeB64, "vercel-04-aug-26.pdf"),
    ];
    const r = await rawGateway(apiKey, content);
    const okish =
      r.ok &&
      !/not supported|unsupported|invalid|unknown type|cannot process/i.test(
        r.body,
      );
    // Check if model actually used PDF somehow — at least HTTP 200 with JSON
    let parsed: string | null = null;
    if (r.ok) {
      try {
        const data = JSON.parse(r.body) as {
          choices?: Array<{ message?: { content?: string } }>;
          error?: unknown;
        };
        if (data.error) {
          console.log(
            `PROBE ${v.id.padEnd(24)} FAIL ${r.ms}ms status=${r.status} err=${JSON.stringify(data.error).slice(0, 160)}`,
          );
          continue;
        }
        parsed = data.choices?.[0]?.message?.content ?? null;
      } catch {
        /* */
      }
    }
    if (r.ok && parsed) {
      workingVariants.push(v.id);
      console.log(
        `PROBE ${v.id.padEnd(24)} OK   ${r.ms}ms → ${parsed.slice(0, 120)}`,
      );
    } else {
      console.log(
        `PROBE ${v.id.padEnd(24)} FAIL ${r.ms}ms status=${r.status} body=${r.body.slice(0, 180).replace(/\n/g, " ")}`,
      );
    }
  }

  console.log(`\nWorking variants: ${workingVariants.join(", ") || "(none)"}`);

  // Pick preferred variant for smoke
  const preferredId =
    workingVariants.find((x) => x === "file.file_data_dataurl") ??
    workingVariants.find((x) => x === "file.data_media_type") ??
    workingVariants[0];
  const preferred = PROBE_VARIANTS.find((v) => v.id === preferredId);

  const rows: Array<Record<string, string | number | boolean>> = [];

  console.log("\n--- SMOKE: text-only vs image vision vs native PDF ---");

  for (const s of SAMPLES) {
    const pdfPath = join(INVOICE_DIR, s.file);
    if (!existsSync(pdfPath)) {
      console.log(`MISSING ${s.file}`);
      continue;
    }
    const text = await extractText(pdfPath);
    const nv = needsVision(text);
    console.log(
      `\n### ${s.file} needsVision=${nv} textLen=${text.length} (${s.note})`,
    );

    // 1) text-only
    {
      const t0 = performance.now();
      let result = await classifyWithGateway(text, {
        apiKey,
        filename: s.file,
      });
      result = refineHotelFolioResult(text, result);
      const ms = Math.round(performance.now() - t0);
      const sc = score(result, s.expected, s.vendor, s.note);
      console.log(
        `  text-only   ${ms}ms  ${sc.label}  exact=${sc.exact} vendor=${sc.vendorOk} woolOk=${sc.woolOk}`,
      );
      rows.push({
        sample: s.file,
        mode: "text-only",
        ms,
        result: sc.label,
        exact: sc.exact,
        vendorOk: sc.vendorOk,
        woolOk: sc.woolOk,
      });
    }

    // 2) image vision
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
        const sc = score(result, s.expected, s.vendor, s.note);
        console.log(
          `  image-png   ${ms}ms  ${sc.label}  exact=${sc.exact} vendor=${sc.vendorOk} woolOk=${sc.woolOk} png=${imagePath ? "yes" : "no"}`,
        );
        rows.push({
          sample: s.file,
          mode: "image-png",
          ms,
          result: sc.label,
          exact: sc.exact,
          vendorOk: sc.vendorOk,
          woolOk: sc.woolOk,
        });
      } finally {
        await cleanupTempImage(imagePath);
      }
    }

    // 3) native PDF (if any variant works)
    if (preferred) {
      const { result: rawResult, ms, err } = await classifyNativePdf(
        apiKey,
        text,
        s.file,
        pdfPath,
        preferred.build,
      );
      if (err) {
        console.log(`  native-pdf  ${ms}ms  ERR ${err}`);
        rows.push({
          sample: s.file,
          mode: `native-pdf:${preferred.id}`,
          ms,
          result: `ERR:${err.slice(0, 80)}`,
          exact: false,
          vendorOk: false,
          woolOk: false,
        });
      } else {
        const result = refineHotelFolioResult(text, rawResult);
        const sc = score(result, s.expected, s.vendor, s.note);
        console.log(
          `  native-pdf  ${ms}ms  ${sc.label}  exact=${sc.exact} vendor=${sc.vendorOk} woolOk=${sc.woolOk} variant=${preferred.id}`,
        );
        rows.push({
          sample: s.file,
          mode: `native-pdf:${preferred.id}`,
          ms,
          result: sc.label,
          exact: sc.exact,
          vendorOk: sc.vendorOk,
          woolOk: sc.woolOk,
        });
      }
    } else {
      console.log(`  native-pdf  SKIP (no working variant)`);
      rows.push({
        sample: s.file,
        mode: "native-pdf",
        ms: 0,
        result: "SKIP:no-variant",
        exact: false,
        vendorOk: false,
        woolOk: false,
      });
    }
  }

  const outDir = join(ORGANIZE_DIR, "spikes/bench-results");
  await mkdir(outDir, { recursive: true });
  const outPath = join(outDir, "nova-pdf-native.json");
  await writeFile(
    outPath,
    JSON.stringify(
      {
        model: GATEWAY_MODEL,
        workingVariants,
        preferredId: preferredId ?? null,
        rows,
        at: new Date().toISOString(),
      },
      null,
      2,
    ),
  );
  console.log(`\nWrote ${outPath}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
