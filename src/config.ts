import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/** Repo root (ORGANIZE_DIR): parent of src/ */
export const ORGANIZE_DIR = join(here, "..");

export const DOWNLOADS_DIR = join(homedir(), "Downloads");
export const TRASH_DIR = join(homedir(), ".Trash");
export const LOG_FILE = join(ORGANIZE_DIR, "ai-organize.log");

export const CATEGORIES = [
  "Invoices",
  "Images",
  "Documents",
  "Data",
  "Code",
  "Media",
  "Resumes",
  "Misc",
] as const;

export type Category = (typeof CATEGORIES)[number];

export const INVOICE_NAME_RE =
  /^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$/;

export const GATEWAY_URL =
  process.env.GATEWAY_URL ?? "https://ai-gateway.vercel.sh/v1/chat/completions";

export const GATEWAY_MODEL =
  process.env.GATEWAY_MODEL ??
  process.env.GATEWAY_INVOICE_MODEL ??
  "amazon/nova-2-lite";

/** Max chars of extracted text sent to the gateway */
export const TEXT_CAP = 5500;

/** Max lines kept from anydoc / text extract */
export const EXTRACT_LINE_CAP = 150;

export const ANYDOC_CLI_CANDIDATES = [
  join(homedir(), ".bun/install/global/node_modules/@firecrawl/anydoc/cli.js"),
  join(homedir(), ".bun/bin/../install/global/node_modules/@firecrawl/anydoc/cli.js"),
];

export const BUN_CANDIDATES = [
  process.env.ANYDOC_BUN,
  join(homedir(), ".bun/bin/bun"),
  "bun",
].filter(Boolean) as string[];

export const SKIP_PREFIXES = [".", "~$"] as const;
export const SKIP_SUFFIXES = [".crdownload", ".part", ".download"] as const;

export const EXT_CATEGORY: Record<string, Category> = {
  png: "Images",
  jpg: "Images",
  jpeg: "Images",
  webp: "Images",
  gif: "Images",
  svg: "Images",
  heic: "Images",
  mp4: "Media",
  mov: "Media",
  mp3: "Media",
  wav: "Media",
  m4a: "Media",
  mkv: "Media",
  avi: "Media",
  csv: "Data",
  xlsx: "Data",
  xls: "Data",
  json: "Data",
  zip: "Code",
  lic: "Code",
  vsix: "Code",
  exe: "Code",
  dmg: "Code",
  pkg: "Code",
  tar: "Code",
  gz: "Code",
  pdf: "Documents",
  docx: "Documents",
  doc: "Documents",
  pptx: "Documents",
  ppt: "Documents",
  txt: "Documents",
  md: "Documents",
  rtf: "Documents",
};

export function extensionCategory(ext: string): Category {
  return EXT_CATEGORY[ext.toLowerCase()] ?? "Misc";
}

export function isCategory(value: string): value is Category {
  return (CATEGORIES as readonly string[]).includes(value);
}
