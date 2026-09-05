# Holistic upgrade notes (paused 2026-09-05)

Executor stopped mid-planning per parent steer: no more Gemini/gateway spaghetti
wiring until a redesign pass with the user.

## What this executor changed

**Nothing.** No edits to `ai-organize.sh`, README, or spike docs in this turn.
Only read/inspected the tree, then wrote this note.

No revert needed (no partial gateway patch to unwind).

## Pre-existing dirty tree (left alone)

Already modified before this turn (not committed):

| Path | State |
|------|--------|
| `.gitignore` | Adds `.env.gateway` (good; keep) |
| `ai-organize.sh` | LFM spike polish only (lean prompt, day/month/year JSON, ollama HTTP + month normalize, prefer lfm2.5-1.2b). Still production: Gemini classify + filename heuristics + optional LFM |
| `spikes/lfm-invoice-extract.md` | LFM spike docs updated |
| Untracked `spikes/bench-*`, `vl-vision-one.py`, `bench-results/` | Gateway/LFM bakeoff experiments |

Also present on disk (gitignored / local):

- Repo `.env.gateway` with `AI_GATEWAY_API_KEY` (len 60)
- `~/Downloads/.organize` → symlink to this repo (so one `.env.gateway` covers ORGANIZE_DIR)

## Current production architecture (as of paused HEAD worktree)

1. **Heuristics first** — `filename_heuristic_category` (Receipt/invoice/payment → Invoices; resume/cv → Resumes)
2. **Already-classified** — `vendor-dd-mon-yy` / `*-resume` → fast_move
3. **Optional LFM** — `INVOICE_EXTRACTOR=lfm` / `USE_LFM_EXTRACT=1` → `lfm_invoice_extract_name` via ollama
4. **Gemini Flash** — `classify_file` / `gemini_request` for ambiguous leftovers (requires `GEMINI_API_KEY` from `.env`)
5. **Extension fallback** — `extension_categorize`

Gateway (`https://ai-gateway.vercel.sh`) is **not** wired into `ai-organize.sh` yet.
Bench scripts under `spikes/` already exercised gateway extract / lean prompts.

## User decisions that prompted the rethink (not implemented)

Earlier ask:

- Invoice naming via gateway `amazon/nova-2-lite`
- Remove LFM production path
- Remove filename heuristics
- Keep Gemini for ambiguous classify
- Load `AI_GATEWAY_API_KEY` from `.env.gateway`

Then updated:

- **Drop Gemini entirely** — all AI (category + name) via Vercel AI Gateway, model default `amazon/nova-2-lite` (`GATEWAY_MODEL` / `GATEWAY_INVOICE_MODEL`)
- No LFM, no filename heuristics
- No key → skip AI → `extension_categorize` only
- One gateway call returning `{category, name}` with strong invoice `vendor-dd-mon-yy` rules
- Update help / README / spike notes accordingly
- Smoke on `~/Downloads/Invoices/vercel-04-aug-26.pdf` without moving organized invoices
- Do not commit

## Suggested redesign shape (for parent + user)

Replace the multi-path graph with roughly:

```
already_classified? → fast_move
else if AI_GATEWAY_API_KEY:
  extract_content (text) or note image limitation
  gateway chat/completions → {category, name}
  validate; Invoices name must match INVOICE_NAME_RE (or salvage)
else:
  extension_categorize → fast_move
```

Delete or stop calling: `filename_heuristic_category`, `lfm_invoice_extract_name`,
`gemini_request` / Gemini URL+key requirement for normal runs.

Open product questions before coding:

- Images/screenshots: nova-2-lite text-only vs multimodal / separate vision model?
- Large PDFs: always text-extract first (anydoc/lit) vs inline bytes?
- Budget semantics: rename `AI_LIMIT` from “Gemini calls” → “gateway calls”?
- Keep `INVOICE_EXTRACTOR` at all, or just `USE_AI=0` / missing key?

## Smoke target (when redesign lands)

`~/Downloads/Invoices/vercel-04-aug-26.pdf` — expect name `vercel-04-aug-26`;
invoke extract/classify in a subshell/dry harness; do not move user’s Invoices.
