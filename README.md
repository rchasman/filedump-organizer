# Downloads Organizer

Thin **Bun / TypeScript** organizer for macOS. Folder Action → CLI → **anydoc**
extract → **one** Vercel AI Gateway call (`amazon/nova-2-lite`) →
`{category, name}` → content-hash dedupe → move.

No Gemini. No Liquid/LFM. No filename keyword heuristics.

`~/Downloads/.organize` is a symlink to this repo.

## Flow

1. Scan **top-level files only** in `~/Downloads` (skip dots, partials, `~$…`)
2. **Content-hash dedupe** — identical files → Trash (keep newest)
3. **Extract** text with anydoc (`bun` + `@firecrawl/anydoc` cli.js); plain-text fallback
4. **One gateway** `chat/completions` call per file (up to `limit`) → `{category, name}`
5. **Move** into category folders; invoice names must match `vendor-dd-mon-yy`

## Folder structure

```
~/Downloads/
├── Invoices/    # receipts / invoices (vendor-dd-mon-yy)
├── Images/
├── Documents/
├── Data/
├── Code/
├── Media/
├── Resumes/
└── Misc/
```

## Requirements

- macOS + [Bun](https://bun.sh)
- Vercel AI Gateway key in `.env.gateway` (gitignored):

  ```bash
  AI_GATEWAY_API_KEY=your_key_here
  ```

  Optional: `GATEWAY_MODEL=amazon/nova-2-lite` (default)

- Optional: [anydoc](https://github.com/firecrawl/anydoc) for PDF/doc extract:

  ```bash
  bun install -g @firecrawl/anydoc
  ```

  The CLI is invoked as `bun …/@firecrawl/anydoc/cli.js <file>` (no Node shebang).
  Overrides: `ANYDOC_BUN`, `ANYDOC_BIN`.

Gemini is **not** required.

## Usage

```bash
cd ~/Downloads/.organize   # or: cd ~/git/filedump-organizer

bun run organize           # up to 50 gateway calls
bun run organize 15        # Folder Action budget shape
DRY_RUN=1 bun run organize # or: bun run organize --dry-run

# Legacy shim (prints deprecation, then execs the same CLI)
./ai-organize.sh --dry-run 5
```

| Variable | Meaning |
|----------|---------|
| `DRY_RUN=1` / `--dry-run` | Log only; no moves or trash |
| `AI_GATEWAY_API_KEY` | Gateway bearer token (or `.env.gateway`) |
| `GATEWAY_MODEL` | Default `amazon/nova-2-lite` |
| `ANYDOC_BUN` / `ANYDOC_BIN` | Override bun / anydoc cli.js paths |

Missing gateway key → extension-based category + kebab basename only (no AI).

## Invoice naming

Gateway returns `name` as `vendor-dd-mon-yy` when `category` is `Invoices`:

- **vendor** = issuer/charged party (not Bill-to; uber-eats not the restaurant)
- **date** = date paid / issued (not due / arrival)
- **month** = `jan`…`dec`

Validated in `src/move.ts` against `INVOICE_NAME_RE`.

## Auto-run (Folder Action)

1. Compile (re-run after editing the `.applescript`):

   ```bash
   mkdir -p ~/Library/Scripts/Folder\ Action\ Scripts
   osacompile -o ~/Library/Scripts/Folder\ Action\ Scripts/organize-downloads.scpt \
     organize-downloads.applescript
   ```

2. **Folder Actions Setup** → enable → add **Downloads** → attach **organize-downloads.scpt**

CLI enable:

```bash
osascript -e 'tell application "System Events" to set folder actions enabled to true'
```

The compiled script runs:

`cd ~/Downloads/.organize && bun run organize 15`

with PATH including Homebrew + `~/.bun/bin`.

## Layout

```
src/cli.ts       # --dry-run, limit, scan, orchestrate
src/extract.ts   # anydoc + text fallback
src/gateway.ts   # .env.gateway + chat/completions → {category, name}
src/move.ts      # folders, invoice regex, unique paths, hash dedupe, dry-run
src/config.ts    # paths, categories, regex
```
