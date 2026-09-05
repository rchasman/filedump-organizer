# Invoice extract benchmark (2026-09-05)

**Setup:** 10 already-named `~/Downloads/Invoices/*.pdf` as ground truth (`vendor-dd-mon-yy`).  
**Text path:** anydoc Markdown → Ollama `/api/generate` (`format=json`, `temperature=0`) → bash formats `vendor-day-month-year`.  
**Caveat:** filenames are imperfect labels; few-shot examples still bias small models.

## Models pulled

| Model | Size | Role |
|---|---|---|
| `LiquidAI/lfm2.5-350m:q4_k_m` | 229 MB | General edge / extraction-capable |
| `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m` | 730 MB | Stronger text instruct |
| `hf.co/LiquidAI/LFM2.5-VL-1.6B-Extract-GGUF:q4_k_m` | 1.3 GB | Blog-lineage **Extract Nano** (vision) |

## Text-path scores (10 receipts)

| Model | Exact name | Valid format | Vendor OK | Avg latency |
|---|---:|---:|---:|---:|
| **lfm2.5-350m** | 1/10 | 9/10 | 2/10 | **~192 ms** |
| **lfm2.5-1.2b-instruct** | **4/10** | 9/10 | **4/10** | ~356 ms |
| **VL-1.6B-Extract (as text)** | 0/10 | 10/10 | 1/10 | ~2.2 s (17 s cold) |

**Winner for current organizer path (anydoc → rename):** `lfm2.5-1.2b-instruct` — best exact/vendor, still sub-second after warm.  
**Winner for speed / tiny footprint:** `lfm2.5-350m` — fine as a fallback, not accurate enough alone.  
**VL-as-text:** not the right way to use it (see below).

## VL vision smoke (1 receipt)

Rendered `vercel-04-aug-26.pdf` page → PNG → VL with `images: [...]`.

- Latency ~3 s warm
- Returned its **own** extract schema (not our `vendor/day/month/year`)
- Date `2026-08-04` matched the filename day (**good**)
- Vendor string polluted by prompt wording (“Kebab Merchant”) — needs a VL-native schema prompt, not the text-instruct template

So VL-Extract is the real Nano from the Liquid blog lineage, but it wants **image + schema-oriented prompting**, not “pretend you’re a text JSON renamer.”

## Recommendation for filedump-organizer

1. Default LFM text extractor: **`LiquidAI/lfm2.5-1.2b-instruct:q4_k_m`**
2. Keep **350m** as fast fallback if 1.2B missing
3. Treat **VL-Extract** as a separate path for scanned/screenshot receipts (render PDF page → image → VL schema → map fields in bash)
4. Gemini remains best for ambiguous full classification; LFM is for invoice naming

Raw CSV: `spikes/bench-results/summary.csv`


## Decision (2026-09-05 later)

**No regex/keyword hybrid** for receipt rename — permutations don't scale.

Production LFM path in `ai-organize.sh`:
- Default model: `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m` (fallback any non-VL Liquid tag)
- Tightened prompt/schema only (`vendor` / `day` / `month` / `year`)
- Output formatting only: kebab slug cleanup, numeric/full month → `mon`, 4-digit year → 2-digit
- Gemini remains the default classifier; LFM is opt-in via `USE_LFM_EXTRACT=1` / `INVOICE_EXTRACTOR=lfm`

Prompt-only accuracy on the 10-file set is still imperfect (bill-to vs issuer, delivery platform vs restaurant). Next levers are better prompts/schemas or a stronger model — not receipt regex.

Gateway LLM-only totals (for context, same JSON schema): see `summary-gateway.csv` (best exact among sampled: `alibaba/qwen3.5-flash` 7/10).


## Prompt A/B (lean vs rich schema, same 1.2b)

| Strategy | Exact | Vendor OK | Notes |
|---|---:|---:|---|
| **Lean current** (4 fields) | **5/10** | **6/10** | Best so far for Liquid 1.2b |
| Rich schema, use `vendor` | 3/10 | 4/10 | Often puts bill-to / line-item into vendor |
| Rich schema, prefer `issuer` | 4/10 | 6/10 | Fixes GitHub/Neon; breaks HF (issuer=Amex) |

Richer fields help the model *sometimes* separate bill-to vs issuer, but 1.2b still mis-fills them enough that discarding extras does not beat the lean prompt. Log: `prompt-ab.log`, `summary-prompt-ab.json`.


## Lean-prompt bakeoff (identical lean prompt, all models)

_Generated 2026-09-05 16:03 UTC_

| Rank | Model | Source | Exact | Vendor OK | Valid | Avg ms |
|---:|---|---|---:|---:|---:|---:|
| 1 | `meta/llama-4-scout` | gateway | 8/10 | 8/10 | 9/10 | 664 |
| 2 | `mistral/mistral-small` | gateway | 7/10 | 9/10 | 10/10 | 861 |
| 3 | `anthropic/claude-haiku-4.5` | gateway | 7/10 | 9/10 | 10/10 | 1230 |
| 4 | `llama3.2:latest` | local | 7/10 | 8/10 | 10/10 | 1214 |
| 5 | `openai/gpt-4o-mini` | gateway | 7/10 | 8/10 | 10/10 | 1742 |
| 6 | `spacexai/grok-4.1-fast-non-reasoning` | gateway | 7/10 | 8/10 | 9/10 | 857 |
| 7 | `gemma4:latest` | local | 7/10 | 8/10 | 9/10 | 2013 |
| 8 | `gemma2:9b` | local | 7/10 | 8/10 | 9/10 | 2348 |
| 9 | `google/gemini-2.5-flash` | gateway | 7/10 | 7/10 | 9/10 | 3076 |
| 10 | `google/gemini-2.5-flash-lite` | gateway | 6/10 | 7/10 | 10/10 | 1028 |
| 11 | `openai/gpt-4o` | gateway | 6/10 | 7/10 | 10/10 | 1385 |
| 12 | `alibaba/qwen3.5-flash` | gateway | 6/10 | 7/10 | 9/10 | 16340 |
| 13 | `mistral:latest` | local | 6/10 | 6/10 | 10/10 | 1837 |
| 14 | `gemini-2.5-flash (direct)` | gemini | 6/10 | 6/10 | 9/10 | 3109 |
| 15 | `deepseek-coder:latest` | local | 5/10 | 7/10 | 10/10 | 641 |
| 16 | `LiquidAI/lfm2.5-1.2b-instruct:q4_k_m` | local | 5/10 | 6/10 | 10/10 | 171 |
| 17 | `google/gemini-2.5-pro` | gateway | 5/10 | 6/10 | 9/10 | 4353 |
| 18 | `LiquidAI/lfm2.5-350m:q4_k_m` | local | 0/10 | 0/10 | 4/10 | 221 |

**Winner:** `gateway:meta/llama-4-scout` — **8/10 exact**, vendor 8/10, avg 664 ms.


Worst misses (top contenders):

- `meta/llama-4-scout`: woolworths-01-jun-25: got=woolworths--- expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfortsuites-18-jun-26 expected=comfort-suites-03-aug-26
- `mistral/mistral-small`: google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-24 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-18-jun-26 expected=comfort-suites-03-aug-26
- `anthropic/claude-haiku-4.5`: google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-00 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-18-jun-26 expected=comfort-suites-03-aug-26
- `llama3.2:latest`: google-30-jun-26: got=google-cloud-01-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-22 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-at-sabino-canyon-08-jun-26 expected=comfort-suites-03-aug-26
- `openai/gpt-4o-mini`: google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; uber-eats-18-jun-26: got=uber-18-jun-26 expected=uber-eats-18-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-23 expected=woolworths-01-jun-25

Artifacts: `summary-lean-bakeoff.csv`, `summary-lean-bakeoff.json`, `lean-bakeoff.log`.



## Round 2: flash/Kimi/Qwen/GLM

_Generated 2026-09-05 16:29 UTC_ — same lean prompt + postprocess + 10 samples.

| Rank | Model | Exact | Vendor OK | Valid | Avg ms |
|---:|---|---:|---:|---:|---:|
| 1 | `amazon/nova-2-lite` | 8/10 | 9/10 | 10/10 | 856 |
| 2 | `meta/llama-4-scout` ← scout sanity | 8/10 | 8/10 | 9/10 | 743 |
| 3 | `zai/glm-5.3-flash` | 8/10 | 8/10 | 9/10 | 1419 |
| 4 | `zai/glm-5.3-fast` | 8/10 | 8/10 | 9/10 | 1576 |
| 5 | `moonshotai/kimi-k2.5` | 8/10 | 8/10 | 9/10 | 2183 |
| 6 | `zai/glm-4.7-flash` | 7/10 | 9/10 | 10/10 | 735 |
| 7 | `alibaba/qwen3.8-flash` | 7/10 | 9/10 | 10/10 | 10276 |
| 8 | `meta/llama-4-maverick` | 7/10 | 8/10 | 10/10 | 623 |
| 9 | `moonshotai/kimi-k3` | 7/10 | 8/10 | 9/10 | 2825 |
| 10 | `google/gemini-3-flash` | 7/10 | 8/10 | 9/10 | 15799 |
| 11 | `google/gemini-3.5-flash-lite` | 7/10 | 7/10 | 9/10 | 966 |
| 12 | `moonshotai/kimi-k3-fast` | 7/10 | 7/10 | 9/10 | 1841 |
| 13 | `google/gemini-3.5-flash` | 7/10 | 7/10 | 9/10 | 3141 |
| 14 | `deepseek/deepseek-v4-flash` | 7/10 | 7/10 | 9/10 | 16603 |
| 15 | `alibaba/qwen3.5-plus` | 7/10 | 7/10 | 8/10 | 64003 |
| 16 | `google/gemini-3.1-flash-lite` | 6/10 | 7/10 | 9/10 | 1146 |
| 17 | `openai/gpt-5-mini` | 6/10 | 7/10 | 9/10 | 3771 |
| 18 | `alibaba/qwen3.7-flash` | 5/10 | 6/10 | 10/10 | 11107 |
| 19 | `openai/gpt-4.1-mini` | 5/10 | 6/10 | 9/10 | 1688 |
| 20 | `moonshotai/kimi-k2` | 0/10 | 0/10 | 0/10 | 306 |
| 21 | `alibaba/qwen3.8-flash-next` | 0/10 | 0/10 | 0/10 | 338 |
| 22 | `zai/glm-4.5-air` | 0/10 | 0/10 | 0/10 | 351 |
| 23 | `stepfun/step-3.5-flash` | 0/10 | 0/10 | 0/10 | 493 |

**Beats round1 scout:** no (strict >8). Ties at 8/10: `amazon/nova-2-lite`, `zai/glm-5.3-flash`, `zai/glm-5.3-fast`, `moonshotai/kimi-k2.5`. Scout sanity: 8/10.


Worst misses (≥7 exact):

- `amazon/nova-2-lite` (8/10): google-30-jun-26: got=google-cloud-01-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-24 expected=woolworths-01-jun-25
- `meta/llama-4-scout` (8/10): woolworths-01-jun-25: got=woolworths--- expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfortsuites-18-jun-26 expected=comfort-suites-03-aug-26
- `zai/glm-5.3-flash` (8/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25
- `zai/glm-5.3-fast` (8/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25
- `moonshotai/kimi-k2.5` (8/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25
- `zai/glm-4.7-flash` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-24 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-18-jun-26 expected=comfort-suites-03-aug-26
- `alibaba/qwen3.8-flash` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=woolworths-01-jan-70 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-18-jun-26 expected=comfort-suites-03-aug-26
- `meta/llama-4-maverick` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=prezzee-01-jan-24 expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-25-may-26 expected=comfort-suites-03-aug-26
- `moonshotai/kimi-k3` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-17-jun-26 expected=comfort-suites-03-aug-26
- `google/gemini-3-flash` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=--- expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=comfort-suites-18-jun-26 expected=comfort-suites-03-aug-26
- `google/gemini-3.5-flash-lite` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; uber-eats-18-jun-26: got=uber-18-jun-26 expected=uber-eats-18-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25
- `moonshotai/kimi-k3-fast` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; uber-eats-18-jun-26: got=uber-18-jun-26 expected=uber-eats-18-jun-26; woolworths-01-jun-25: got=woolworths--- expected=woolworths-01-jun-25
- `google/gemini-3.5-flash` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; uber-eats-18-jun-26: got=uber-18-jun-26 expected=uber-eats-18-jun-26; woolworths-01-jun-25: got=prezzee--- expected=woolworths-01-jun-25
- `deepseek/deepseek-v4-flash` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; uber-eats-18-jun-26: got=bossabowls-18-jun-26 expected=uber-eats-18-jun-26; woolworths-01-jun-25: got=woolworths--- expected=woolworths-01-jun-25
- `alibaba/qwen3.5-plus` (7/10): google-30-jun-26: got=google-cloud-30-jun-26 expected=google-30-jun-26; woolworths-01-jun-25: got=--- expected=woolworths-01-jun-25; comfort-suites-03-aug-26: got=--- expected=comfort-suites-03-aug-26

Artifacts: `summary-lean-bakeoff-round2.csv`, `summary-lean-bakeoff-round2.json`, `lean-bakeoff-round2.log`.

