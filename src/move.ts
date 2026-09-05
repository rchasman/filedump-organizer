import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { appendFile, mkdir, rename, stat } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import {
  CATEGORIES,
  DOWNLOADS_DIR,
  INVOICE_NAME_RE,
  LOG_FILE,
  TRASH_DIR,
  type Category,
} from "./config.ts";

export type MoveOptions = {
  dryRun: boolean;
};

function stamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export async function log(msg: string, dryRun: boolean): Promise<void> {
  const line = `[${stamp()}] ${dryRun ? "[DRY-RUN] " : ""}${msg}\n`;
  process.stdout.write(line);
  await appendFile(LOG_FILE, line);
}

export async function ensureCategoryFolders(): Promise<void> {
  for (const folder of CATEGORIES) {
    await mkdir(join(DOWNLOADS_DIR, folder), { recursive: true });
  }
}

/** Validate invoice name; salvage to kebab+date-ish or return null if unusable. */
export function validateInvoiceName(name: string): string | null {
  const cleaned = name
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  const candidate = INVOICE_NAME_RE.test(cleaned)
    ? cleaned
    : (() => {
        const salvage = cleaned
          .replace(/_+/g, "-")
          .replace(/-+/g, "-")
          .replace(/^-|-$/g, "");
        return INVOICE_NAME_RE.test(salvage) ? salvage : null;
      })();
  if (!candidate) return null;
  // Reject nonsense years (model invention sentinel)
  if (candidate.endsWith("-00")) return null;
  return candidate;
}

export function getUniquePath(dir: string, base: string, ext: string): string {
  const withExt = ext ? `${base}.${ext}` : base;
  let target = join(dir, withExt);
  if (!existsSync(target)) return target;

  let counter = 2;
  while (true) {
    const candidate = ext
      ? join(dir, `${base}-${counter}.${ext}`)
      : join(dir, `${base}-${counter}`);
    if (!existsSync(candidate)) return candidate;
    counter++;
  }
}

export async function contentHash(filepath: string): Promise<string> {
  const buf = await Bun.file(filepath).arrayBuffer();
  return createHash("sha256").update(new Uint8Array(buf)).digest("hex");
}

type FileEntry = { path: string; hash: string; mtimeMs: number };

/** Content-hash dedupe among top-level candidates; trash older dupes (keep newest). */
export async function dedupeByHash(
  files: string[],
  opts: MoveOptions,
): Promise<string[]> {
  const entries: FileEntry[] = [];
  for (const path of files) {
    try {
      const [hash, st] = await Promise.all([contentHash(path), stat(path)]);
      entries.push({ path, hash, mtimeMs: st.mtimeMs });
    } catch {
      /* skip unreadable */
    }
  }

  const byHash = new Map<string, FileEntry[]>();
  for (const e of entries) {
    const list = byHash.get(e.hash) ?? [];
    list.push(e);
    byHash.set(e.hash, list);
  }

  const survivors = new Set<string>();
  for (const group of byHash.values()) {
    group.sort((a, b) => b.mtimeMs - a.mtimeMs);
    survivors.add(group[0]!.path);
    for (const dupe of group.slice(1)) {
      await log(`Would trash dupe: ${basename(dupe.path)}`, opts.dryRun);
      if (!opts.dryRun) {
        const dest = join(TRASH_DIR, basename(dupe.path));
        const unique = existsSync(dest)
          ? join(TRASH_DIR, `${Date.now()}-${basename(dupe.path)}`)
          : dest;
        await rename(dupe.path, unique);
        await log(`Trashed dupe: ${basename(dupe.path)}`, false);
      }
    }
  }

  return files.filter((f) => survivors.has(f) && existsSync(f));
}

export async function moveClassified(
  filepath: string,
  category: Category,
  name: string,
  opts: MoveOptions,
): Promise<string | null> {
  const ext = extname(filepath).slice(1).toLowerCase();
  let finalName = name;

  if (category === "Invoices") {
    const valid = validateInvoiceName(name);
    if (!valid) {
      await log(
        `Invoice name invalid (${name}); leaving ${basename(filepath)} alone`,
        opts.dryRun,
      );
      return null;
    }
    finalName = valid;
  }

  const destDir = join(DOWNLOADS_DIR, category);
  if (!opts.dryRun) {
    await mkdir(destDir, { recursive: true });
  }

  const target = getUniquePath(destDir, finalName, ext);
  const rel = `${category}/${basename(target)}`;

  if (opts.dryRun) {
    await log(`Would move: ${basename(filepath)} -> ${rel}`, true);
    return target;
  }

  await rename(filepath, target);
  await log(`Moved: ${basename(filepath)} -> ${rel}`, false);
  return target;
}
