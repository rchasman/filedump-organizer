import { existsSync } from "node:fs";
import { mkdir, rm, unlink } from "node:fs/promises";
import { basename, join } from "node:path";
import { ORGANIZE_DIR, TEXT_CAP } from "./config.ts";

const TMP_DIR = join(ORGANIZE_DIR, ".extract_tmp");

/** Reasonable date-like tokens in extract text (first TEXT_CAP chars). */
const DATE_LIKE_RE =
  /\b(?:(?:0?[1-9]|[12]\d|3[01])[\/\-.](?:0?[1-9]|1[0-2])[\/\-.](?:(?:19|20)?\d{2}|\d{2})|(?:0?[1-9]|1[0-2])[\/\-.](?:0?[1-9]|[12]\d|3[01])[\/\-.](?:(?:19|20)?\d{2}|\d{2})|(?:19|20)\d{2}[\/\-.](?:0?[1-9]|1[0-2])[\/\-.](?:0?[1-9]|[12]\d|3[01])|(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2},?\s+(?:19|20)?\d{2}|\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+(?:19|20)?\d{2}|(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01]))\b/i;

const HOTEL_SIGNALS = [
  /arrival\s+date/i,
  /departure\s+date/i,
  /\bfolio\b/i,
  /check[\s-]?in/i,
  /check[\s-]?out/i,
];

const GIFT_SIGNALS = [/gift\s*card/i, /\begift\b/i, /\bprezzee\b/i, /\bvoucher\b/i];

const CLEAR_PAID_DATE = [/date\s+paid/i, /payment\s+date/i, /order\s+completed/i];

const INVOICE_LIKE = [/\btotal\b/i, /\bamount\b/i, /\bpaid\b/i, /\breceipt\b/i];

function hasRoomNearDate(text: string): boolean {
  // "Room:" label near a date-like token (hotel folio field row)
  const re = /room\s*:/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const start = Math.max(0, m.index - 100);
    const end = Math.min(text.length, m.index + m[0].length + 100);
    if (DATE_LIKE_RE.test(text.slice(start, end))) return true;
  }
  return false;
}

/**
 * Detect ambiguous extracts that benefit from a page-1 vision peek.
 * Uses TEXT markers only — no filename heuristics for category routing.
 */
export function needsVision(text: string): boolean {
  const slice = text.slice(0, TEXT_CAP);
  if (!slice.trim()) return false;

  if (HOTEL_SIGNALS.some((re) => re.test(slice)) || hasRoomNearDate(slice)) {
    return true;
  }

  const gift = GIFT_SIGNALS.some((re) => re.test(slice));
  if (gift && !CLEAR_PAID_DATE.some((re) => re.test(slice))) {
    return true;
  }

  const invoiceLike = INVOICE_LIKE.some((re) => re.test(slice));
  if (invoiceLike && !DATE_LIKE_RE.test(slice)) {
    return true;
  }

  return false;
}

function resolvePdftoppm(): string | null {
  for (const c of [
    process.env.PDFTOPPM_BIN,
    "/opt/homebrew/bin/pdftoppm",
    "/usr/local/bin/pdftoppm",
    "pdftoppm",
  ]) {
    if (!c) continue;
    if (c === "pdftoppm") return c;
    if (existsSync(c)) return c;
  }
  return null;
}

/** Render PDF page 1 → PNG under .extract_tmp/. Cap ~1280px wide. Returns path or null. */
export async function renderPdfPage1(pdfPath: string): Promise<string | null> {
  const pdftoppm = resolvePdftoppm();
  if (!pdftoppm) return null;

  await mkdir(TMP_DIR, { recursive: true });
  const stem = `page1-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const outPrefix = join(TMP_DIR, stem);
  const expected = `${outPrefix}.png`;

  try {
    const proc = Bun.spawn(
      [
        pdftoppm,
        "-png",
        "-f",
        "1",
        "-l",
        "1",
        "-singlefile",
        "-scale-to-x",
        "1280",
        "-scale-to-y",
        "-1",
        pdfPath,
        outPrefix,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const code = await proc.exited;
    if (code !== 0 || !existsSync(expected)) {
      // Fallback without scale flags (older poppler)
      const proc2 = Bun.spawn(
        [pdftoppm, "-png", "-f", "1", "-l", "1", "-singlefile", "-r", "120", pdfPath, outPrefix],
        { stdout: "pipe", stderr: "pipe" },
      );
      const code2 = await proc2.exited;
      if (code2 !== 0 || !existsSync(expected)) return null;
    }

    // Optional sips width cap if somehow wider
    if (existsSync("/usr/bin/sips")) {
      const sips = Bun.spawn(
        ["/usr/bin/sips", "--resampleWidth", "1280", expected],
        { stdout: "pipe", stderr: "pipe" },
      );
      await sips.exited;
    }

    return expected;
  } catch {
    return null;
  }
}

export async function cleanupTempImage(imagePath: string | null | undefined): Promise<void> {
  if (!imagePath) return;
  try {
    if (existsSync(imagePath)) await unlink(imagePath);
  } catch {
    /* ignore */
  }
}

export async function ensureExtractTmp(): Promise<string> {
  await mkdir(TMP_DIR, { recursive: true });
  return TMP_DIR;
}

/** Best-effort wipe of stale temp PNGs (optional). */
export async function wipeExtractTmp(): Promise<void> {
  try {
    if (existsSync(TMP_DIR)) await rm(TMP_DIR, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
}

export { TMP_DIR };

const MONS = [
  "jan",
  "feb",
  "mar",
  "apr",
  "may",
  "jun",
  "jul",
  "aug",
  "sep",
  "oct",
  "nov",
  "dec",
] as const;

/** Parse US M/D/YY folio header Date from extract (not Arrival/Departure). */
export function parseFolioHeaderDate(
  text: string,
): { day: string; mon: string; year: string } | null {
  const slice = text.slice(0, 1200);
  if (
    !HOTEL_SIGNALS.some((re) => re.test(slice)) &&
    !hasRoomNearDate(slice)
  ) {
    return null;
  }

  // Common anydoc jam: "Date: Room: Arrival Date: ...|8/3/26 308 5/25/26 ..."
  // Prefer first M/D/YY after a Date: label cluster and before Arrival values dominate.
  let m =
    slice.match(
      /Date:\s*Room:[\s\S]{0,160}?(\d{1,2})\/(\d{1,2})\/(\d{2,4})\b/i,
    ) ??
    slice.match(
      /(?:^|[\s|])Date:\s*[^\d]{0,40}?(\d{1,2})\/(\d{1,2})\/(\d{2,4})\b/i,
    );

  // Fallback: first M/D/YY in header window when Arrival/Departure labels present
  if (!m && /arrival\s+date/i.test(slice)) {
    m = slice.match(/\b(\d{1,2})\/(\d{1,2})\/(\d{2,4})\b/);
  }
  if (!m) return null;

  const a = Number(m[1]);
  const b = Number(m[2]);
  let year = m[3]!;
  if (year.length === 4) year = year.slice(2);
  // US hotel folios: M/D/YY (month first when month<=12)
  let month = a;
  let day = b;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const mon = MONS[month - 1];
  if (!mon) return null;
  return {
    day: String(day).padStart(2, "0"),
    mon,
    year,
  };
}

export type NameCategory = { category: string; name: string };

/**
 * When hotel folio text has a clear header Date, rewrite invoice name date
 * to that value (fixes M/D vs D/M misreads from vision/text models).
 */
export function refineHotelFolioResult<T extends NameCategory>(
  text: string,
  result: T,
): T {
  if (result.category !== "Invoices") return result;
  const folio = parseFolioHeaderDate(text);
  if (!folio) return result;

  const dateRe =
    /^([a-z]+(?:-[a-z]+)*)-([0-9]{2})-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-([0-9]{2})$/;
  const m = result.name.match(dateRe);
  if (m) {
    const next = `${m[1]}-${folio.day}-${folio.mon}-${folio.year}`;
    if (next !== result.name) return { ...result, name: next };
    return result;
  }
  // Model returned vendor without usable date — attach folio date
  const vendor = result.name
    .replace(
      /-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/,
      "",
    )
    .replace(/-+$/g, "");
  if (vendor && /^[a-z]+(?:-[a-z]+)*$/.test(vendor)) {
    return {
      ...result,
      name: `${vendor}-${folio.day}-${folio.mon}-${folio.year}`,
    };
  }
  return result;
}
