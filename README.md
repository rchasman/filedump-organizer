# Downloads Organizer

AI-powered file organization for macOS. Deduplicates, categorizes, and renames
files in `~/Downloads` using **Google Gemini Flash** (default), with local
filename heuristics and optional extraction spikes.

`~/Downloads/.organize` is a symlink to this repo.

## Features

- **Zip extraction** — Unzips archives into Downloads (before organizing)
- **Deduplication** — Trashes identical md5 hashes (keeps newest)
- **Heuristics first** — `Receipt*` / `invoice*` / `payment*` → `Invoices/`;
  `resume` / `cv` / `curriculum` → `Resumes/`; well-formatted
  `vendor-dd-mon-yy` and `*-resume` names skip AI
- **Gemini Flash classification** — Ambiguous leftovers only, up to a call budget
- **Soft invoice naming** — Invalid AI invoice formats are kebab-salvaged;
  category stays `Invoices`
- **Dry-run** — `DRY_RUN=1` or `--dry-run` logs planned actions without moving
- **Skips** — Dotfiles, browser partials, Office lock temps (`~$…`)
- **Optional anydoc** — Firecrawl CLI extraction if installed (else `lit` / `textutil`)
- **Optional LFM spike** — Local invoice `{vendor,date}` naming via ollama (see `spikes/`)

## Folder structure

```
~/Downloads/
├── Invoices/    # receipts, invoices, payment confirmations
├── Images/      # png, jpg, jpeg, webp, gif, svg, heic
├── Documents/   # pdf, docx, pptx, txt, md (non-invoice)
├── Data/        # csv, xlsx, xls, json
├── Code/        # zip, dmg, pkg, exe, vsix, …
├── Media/       # mp4, mov, mp3, wav, …
├── Resumes/     # resume / cv filenames or AI match
└── Misc/        # everything else
```

## Requirements

- macOS
- `jq`, `curl`
- [Gemini API key](https://aistudio.google.com/apikey) in `~/Downloads/.organize/.env`:
  ```bash
  GEMINI_API_KEY=your_key_here
  ```
- [liteparse](https://github.com/run-llama/liteparse) (PDF/doc text):
  `brew tap run-llama/liteparse && brew install llamaindex-liteparse`
- Optional: [anydoc](https://github.com/firecrawl/anydoc) — see below
- Optional: [Ollama](https://ollama.ai) for the LFM invoice spike

Default model: `gemini-3-flash-preview` (override with `GEMINI_MODEL`).

## Usage

```bash
cd ~/Downloads/.organize   # or: cd ~/git/filedump-organizer

# Default: up to 10 Gemini calls for ambiguous files (heuristics always run)
./ai-organize.sh

# Folder Action shape (Gemini budget = 15)
./ai-organize.sh 15

# Heuristics / extension only (no Gemini)
./ai-organize.sh 0

# Dry-run (no moves, trash, or zip extracts)
DRY_RUN=1 ./ai-organize.sh 0
./ai-organize.sh --dry-run 5
```

**Bulk dumps:** run manually with a higher limit, e.g. `./ai-organize.sh 50`.
The Folder Action uses a modest budget so background runs stay cheap.

### Env / spike flags

| Variable | Meaning |
|----------|---------|
| `DRY_RUN=1` | Log only; no filesystem changes |
| `USE_ANYDOC=1` / `0` / `auto` | Prefer `anydoc` when present (`auto` default) |
| `USE_LFM_EXTRACT=1` | Set invoice extractor to `lfm` |
| `INVOICE_EXTRACTOR=gemini|lfm|off` | Default `gemini` |
| `LFM_OLLAMA_MODEL=…` | Ollama model for local `{vendor,date}` JSON |
| `MAX_PARALLEL=5` | Concurrent Gemini jobs |
| `GEMINI_MODEL=…` | Override Flash model id |

## Workflow order

1. **Extract zips** (skipped in dry-run except logging)
2. **Deduplicate**
3. **Heuristic / already-classified fast moves** (all matching files, no AI budget)
4. **Gemini** on remaining ambiguous classifiable types, up to `limit`
5. **Extension fallback** for anything left

## Optional: anydoc extraction

See https://github.com/firecrawl/anydoc. Installed here via Bun:

```bash
bun install -g @firecrawl/anydoc
```

The organizer runs extraction as `bun …/@firecrawl/anydoc/cli.js <file>` (no Node shebang, no per-run `bunx` resolve). It looks for Bun at `~/.bun/bin/bun` and the CLI under Bun’s global install. Overrides: `ANYDOC_BUN`, `ANYDOC_BIN` (path to `cli.js`). Use `USE_ANYDOC=0` to force liteparse.

Fallback order: anydoc → lit → textutil.

## Optional: LFM2.5 invoice spike

See spikes/lfm-invoice-extract.md. Quick try:

    DRY_RUN=1 USE_LFM_EXTRACT=1 LFM_OLLAMA_MODEL=llama3.2:latest ./ai-organize.sh 0

## Auto-run setup (Folder Action)

1. Compile (re-run after editing the `.applescript`):
   ```bash
   mkdir -p ~/Library/Scripts/Folder\ Action\ Scripts
   osacompile -o ~/Library/Scripts/Folder\ Action\ Scripts/organize-downloads.scpt \
     organize-downloads.applescript
   ```
2. Open **Folder Actions Setup** (Spotlight)
3. Enable Folder Actions
4. Add the **Downloads** folder
5. Attach **organize-downloads.scpt**

Enable via CLI:

```bash
osascript -e 'tell application "System Events" to set folder actions enabled to true'
```

The compiled script runs `~/Downloads/.organize/ai-organize.sh 15`. After changing
the AppleScript default, **recompile** so the folder action picks up the new budget.
