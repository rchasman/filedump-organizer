import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, extname } from "node:path";
import {
  ANYDOC_CLI_CANDIDATES,
  BUN_CANDIDATES,
  EXTRACT_LINE_CAP,
  TEXT_CAP,
} from "./config.ts";

function resolveBun(): string | null {
  for (const candidate of BUN_CANDIDATES) {
    if (candidate === "bun") return "bun";
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function resolveAnydocCli(): string | null {
  if (process.env.ANYDOC_BIN && existsSync(process.env.ANYDOC_BIN)) {
    return process.env.ANYDOC_BIN;
  }
  for (const candidate of ANYDOC_CLI_CANDIDATES) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

async function runAnydoc(filepath: string): Promise<string> {
  const bunBin = resolveBun();
  const cli = resolveAnydocCli();
  if (!bunBin || !cli) return "";

  const proc = Bun.spawn([bunBin, cli, filepath], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) return "";
  return stdout
    .split("\n")
    .slice(0, EXTRACT_LINE_CAP)
    .join("\n")
    .trim();
}

async function fallbackTextRead(filepath: string, ext: string): Promise<string> {
  const textExts = new Set(["txt", "md", "csv", "json", "log", "tsv"]);
  if (!textExts.has(ext)) return "";
  try {
    const raw = await readFile(filepath, "utf8");
    return raw.slice(0, TEXT_CAP * 2);
  } catch {
    return "";
  }
}

/** Extract document text via anydoc; fall back to plain text read. Cap length. */
export async function extractText(filepath: string): Promise<string> {
  const ext = extname(filepath).slice(1).toLowerCase();
  let text = "";

  try {
    text = await runAnydoc(filepath);
  } catch {
    text = "";
  }

  if (!text) {
    text = await fallbackTextRead(filepath, ext);
  }

  if (!text) {
    // Last resort: basename only context for the model
    return `Filename: ${basename(filepath)}`;
  }

  return text.length > TEXT_CAP ? text.slice(0, TEXT_CAP) : text;
}
