# Spike: LFM2.5 invoice naming (local)

Liquid **LFM2-Extract** is deprecated. Prefer **LFM2.5** vision/text extract models
(e.g. `LFM2.5-VL-1.6B-Extract`) for structured `{vendor, date}` from invoices.

This repo keeps **Gemini Flash** as the default classifier. Local LFM is optional.

## Status on this machine

- `ollama` is installed; no Liquid/LFM model is pulled by default.
- `llama-cli` / `llama-server` are not on PATH.
- Script behavior: `INVOICE_EXTRACTOR=lfm` or `USE_LFM_EXTRACT=1` tries
  `lfm_invoice_extract_name` → needs `ollama` + `LFM_OLLAMA_MODEL` (or any
  ollama tag matching `lfm|liquid`). On failure it logs
  `LFM not available … falling back` and uses heuristics / Gemini as usual.

## Manual test steps

1. Choose a local model path:

   **A. Ollama (text extract from lit/anydoc output)**

   ```bash
   export LFM_OLLAMA_MODEL=llama3.2:latest
   ```

   **B. llama.cpp GGUF (vision — recommended for LFM2.5-VL)**

   From Liquid docs (LFM2.5-VL-1.6B-Extract):

   ```bash
   llama-server -hf LiquidAI/LFM2.5-VL-1.6B-Extract-GGUF:Q4_K_M
   ```

2. Dry-run:

   ```bash
   cd ~/Downloads/.organize
   DRY_RUN=1 USE_LFM_EXTRACT=1 LFM_OLLAMA_MODEL=llama3.2:latest ./ai-organize.sh 0
   ```

3. Live LFM rename for heuristic invoice/receipt names (limit 0 = no Gemini):

   ```bash
   USE_LFM_EXTRACT=1 LFM_OLLAMA_MODEL=llama3.2:latest ./ai-organize.sh 0
   ```

4. Expected log lines:

   - Success: `Receipt-foo.pdf -> Invoices/vendor-dd-mon-yy.pdf (LFM)`
   - Missing runtime/model: `LFM not available … falling back` then heuristic move to `Invoices/`

## Prompt / schema used by the script

```json
{"vendor": "short-kebab-name", "date": "dd-mon-yy"}
```

Bash then formats `vendor-dd-mon-yy` and validates against `INVOICE_NAME_RE`.

## Gemini remains default

```bash
./ai-organize.sh 15
INVOICE_EXTRACTOR=gemini ./ai-organize.sh 10
INVOICE_EXTRACTOR=off ./ai-organize.sh 0
```

## anydoc note

Global CLI package: `@firecrawl/anydoc` (see https://github.com/firecrawl/anydoc).

## Spike result (2026-09-05)

- Ran dry-run with `LFM_OLLAMA_MODEL=llama3.2:latest` on a Vercel receipt.
- Path works end-to-end (anydoc text → ollama JSON → validate).
- `llama3.2` is a stand-in, not LFM2.5: first attempt returned bill-to + bad date
  (`levonsangels-appmakerexternal-jan-2026`); prompt tightened to prefer merchant + `dd-mon-yy`.
- For production-quality extract, pull Liquid LFM2.5 Extract (GGUF / LEAP) when available.
