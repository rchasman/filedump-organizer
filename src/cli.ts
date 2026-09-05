#!/usr/bin/env bun
/**
 * Thin Downloads organizer CLI.
 * Flow: scan top-level → hash dedupe → anydoc extract → one gateway call → move.
 */
import { readdir } from "node:fs/promises";
import { basename, join } from "node:path";
import {
  DOWNLOADS_DIR,
  GATEWAY_MODEL,
  SKIP_PREFIXES,
  SKIP_SUFFIXES,
} from "./config.ts";
import { extractText } from "./extract.ts";
import { classifyWithGateway, loadGatewayApiKey } from "./gateway.ts";
import {
  dedupeByHash,
  ensureCategoryFolders,
  log,
  moveClassified,
} from "./move.ts";

function parseArgs(argv: string[]): { dryRun: boolean; limit: number; help: boolean } {
  let dryRun = process.env.DRY_RUN === "1";
  let limit = 50;
  let help = false;
  let sawLimit = false;

  for (const arg of argv) {
    if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "-h" || arg === "--help") {
      help = true;
    } else if (/^\d+$/.test(arg)) {
      limit = Number(arg);
      sawLimit = true;
    } else {
      console.error(`Unknown argument: ${arg} (try --help)`);
      process.exit(1);
    }
  }

  // Folder Action style: bare number is AI call budget (same as old script)
  if (!sawLimit && process.env.AI_LIMIT) {
    limit = Number(process.env.AI_LIMIT) || limit;
  }

  return { dryRun, limit, help };
}

function shouldSkip(filename: string): boolean {
  if (SKIP_PREFIXES.some((p) => filename.startsWith(p))) return true;
  const lower = filename.toLowerCase();
  if (SKIP_SUFFIXES.some((s) => lower.endsWith(s))) return true;
  return false;
}

async function listTopLevelFiles(): Promise<string[]> {
  const entries = await readdir(DOWNLOADS_DIR, { withFileTypes: true });
  const files: string[] = [];
  for (const ent of entries) {
    if (!ent.isFile()) continue;
    if (shouldSkip(ent.name)) continue;
    files.push(join(DOWNLOADS_DIR, ent.name));
  }
  return files;
}

async function main(): Promise<void> {
  const { dryRun, limit, help } = parseArgs(process.argv.slice(2));

  if (help) {
    console.log(`Usage: bun run organize [--dry-run] [limit]

  --dry-run   Log planned moves/trash without changing files (also DRY_RUN=1)
  limit       Max gateway classify calls (default: 50)

Env:
  AI_GATEWAY_API_KEY   or .env.gateway in ORGANIZE_DIR
  GATEWAY_MODEL        default amazon/nova-2-lite
  DRY_RUN=1            same as --dry-run
`);
    return;
  }

  await ensureCategoryFolders();
  await log(
    `Start organize dryRun=${dryRun} limit=${limit} model=${GATEWAY_MODEL}`,
    dryRun,
  );

  let files = await listTopLevelFiles();
  await log(`Found ${files.length} top-level file(s)`, dryRun);

  files = await dedupeByHash(files, { dryRun });
  await log(`${files.length} file(s) after dedupe`, dryRun);

  const apiKey = await loadGatewayApiKey();
  if (!apiKey) {
    await log("No AI_GATEWAY_API_KEY — leaving files alone", dryRun);
    await log(`Done. gateway_calls=0 moved=0 dryRun=${dryRun}`, dryRun);
    return;
  }

  let calls = 0;
  let moved = 0;
  let skipped = 0;

  for (const filepath of files) {
    const filename = basename(filepath);

    if (calls >= limit) {
      await log(`Limit reached; leaving ${filename}`, dryRun);
      skipped++;
      continue;
    }

    try {
      const text = await extractText(filepath);
      const result = await classifyWithGateway(text, { apiKey, filename });
      calls++;
      await log(
        `Classified ${filename} → ${result.category}/${result.name} (call ${calls}/${limit})`,
        dryRun,
      );
      const dest = await moveClassified(
        filepath,
        result.category,
        result.name,
        { dryRun },
      );
      if (dest) moved++;
      else skipped++;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await log(`Gateway failed for ${filename}: ${msg}; leaving alone`, dryRun);
      skipped++;
    }
  }

  await log(
    `Done. gateway_calls=${calls} moved=${moved} skipped=${skipped} dryRun=${dryRun}`,
    dryRun,
  );
}

main().catch(async (err) => {
  console.error(err);
  process.exit(1);
});
