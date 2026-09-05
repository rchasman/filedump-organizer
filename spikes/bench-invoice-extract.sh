#!/bin/bash
# Benchmark Liquid invoice extract models on well-named Invoice PDFs.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$PATH"

ORG_DIR="${ORG_DIR:-$HOME/git/filedump-organizer}"
INV_DIR="${INV_DIR:-$HOME/Downloads/Invoices}"
OUT_DIR="${OUT_DIR:-$ORG_DIR/spikes/bench-results}"
BUN="${BUN:-$HOME/.bun/bin/bun}"
CLI="${CLI:-$HOME/.bun/install/global/node_modules/@firecrawl/anydoc/cli.js}"
mkdir -p "$OUT_DIR"

# Ground-truth set: filenames already vendor-dd-mon-yy.pdf
SAMPLES=(
  "github-21-jul-26.pdf"
  "google-30-jun-26.pdf"
  "huggingface-01-aug-26.pdf"
  "inngest-01-sep-26.pdf"
  "linear-27-aug-26.pdf"
  "neon-01-sep-26.pdf"
  "vercel-04-aug-26.pdf"
  "uber-eats-18-jun-26.pdf"
  "woolworths-01-jun-25.pdf"
  "comfort-suites-03-aug-26.pdf"
)

MODELS=(
  "LiquidAI/lfm2.5-350m:q4_k_m"
  "LiquidAI/lfm2.5-1.2b-instruct:q4_k_m"
  "hf.co/LiquidAI/LFM2.5-VL-1.6B-Extract-GGUF:q4_k_m"
)

# Also pick up any alternate VL tag casing from ollama list
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  for existing in "${MODELS[@]}"; do
    [[ "$(echo "$existing" | tr "[:upper:]" "[:lower:]")" == "$(echo "$m" | tr "[:upper:]" "[:lower:]")" ]] && continue 2
  done
  MODELS+=("$m")
done < <(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -iE 'extract|LFM2.5-VL' || true)

PROMPT_SYS='Extract merchant/issuer and payment/issue date from the receipt.
Merchant = who charged (vercel, stripe, aws, github) — NEVER the bill-to customer.
Return ONLY JSON with keys: vendor, day, month, year.
- vendor: lowercase kebab, 1-3 words
- day: two digits 01-31
- month: exactly one of jan feb mar apr may jun jul aug sep oct nov dec
- year: two digits (26 for 2026)
Examples:
{"vendor":"stripe","day":"03","month":"mar","year":"25"}
{"vendor":"aws","day":"15","month":"dec","year":"24"}'

INVOICE_RE='^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$'

extract_text() {
  local pdf="$1" out="$2"
  if [[ -f "$out" ]]; then return 0; fi
  if [[ -x "$BUN" && -f "$CLI" ]]; then
    "$BUN" "$CLI" "$pdf" > "$out" 2>/dev/null || true
  fi
  if [[ ! -s "$out" ]] && command -v lit >/dev/null; then
    lit parse "$pdf" --target-pages "1-2" -q > "$out" 2>/dev/null || true
  fi
}

normalize_candidate() {
  local json="$1"
  local vendor day month year
  vendor=$(echo "$json" | jq -r '.vendor // empty' 2>/dev/null)
  day=$(echo "$json" | jq -r '.day // empty' 2>/dev/null)
  month=$(echo "$json" | jq -r '.month // empty' 2>/dev/null)
  year=$(echo "$json" | jq -r '.year // empty' 2>/dev/null)
  vendor=$(echo "$vendor" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g' | cut -c1-40)
  if [[ -n "$day" ]]; then
    day=$(printf '%02d' "$((10#$day))" 2>/dev/null || echo "")
  fi
  month=$(echo "$month" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]//g' | cut -c1-3)
  year=$(echo "$year" | sed 's/[^0-9]//g')
  [[ ${#year} -eq 4 ]] && year="${year: -2}"
  echo "${vendor}-${day}-${month}-${year}"
}

run_model() {
  local model="$1" text="$2"
  local prompt content raw
  content=$(head -c 6000 "$text")
  prompt="$PROMPT_SYS

Text:
$content"
  raw=$(curl -sS --max-time 90 http://127.0.0.1:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" --arg prompt "$prompt" \
      '{model:$model, prompt:$prompt, stream:false, format:"json", options:{temperature:0, top_p:0.1}}')" \
    2>/dev/null | jq -r '.response // empty' 2>/dev/null) || true
  echo "$raw"
}

echo "Models: ${MODELS[*]}"
echo "Samples: ${#SAMPLES[@]}"
echo "Results -> $OUT_DIR"
echo

# Pre-extract texts
for s in "${SAMPLES[@]}"; do
  pdf="$INV_DIR/$s"
  [[ -f "$pdf" ]] || { echo "MISSING $pdf"; continue; }
  extract_text "$pdf" "$OUT_DIR/${s%.pdf}.md"
  echo "extracted $s ($(wc -c < "$OUT_DIR/${s%.pdf}.md") bytes)"
done

SUMMARY="$OUT_DIR/summary.csv"
echo "model,sample,expected,got,exact,valid_format,vendor_ok,ms" > "$SUMMARY"

for model in "${MODELS[@]}"; do
  echo
  echo "======== $model ========"
  exact=0; valid=0; vendor_ok=0; n=0; total_ms=0
  for s in "${SAMPLES[@]}"; do
    pdf="$INV_DIR/$s"
    [[ -f "$pdf" ]] || continue
    expected="${s%.pdf}"
    # strip trailing -2/-3 dedupe suffixes for expected base match? keep full stem
    # vendor expected = everything before last three date parts
    exp_vendor=$(echo "$expected" | sed -E 's/-[0-9]{2}-[a-z]{3}-[0-9]{2}(-[0-9]+)?$//')
    text="$OUT_DIR/${s%.pdf}.md"
    [[ -s "$text" ]] || { echo "skip $s (no text)"; continue; }

    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    raw=$(run_model "$model" "$text")
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    ms=$((end - start))
    total_ms=$((total_ms + ms))
    n=$((n + 1))

    json=$(echo "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null || true)
    if [[ -z "$json" ]]; then
      json=$(echo "$raw" | jq -c '.' 2>/dev/null || true)
    fi
    got=$(normalize_candidate "${json:-{}}")
    is_exact=0; is_valid=0; is_vendor=0
    [[ "$got" == "$expected" || "$got" == "${expected%-2}" || "$got" == "${expected%-3}" || "$got" == "${expected%-4}" ]] && is_exact=1
    [[ "$got" =~ $INVOICE_RE ]] && is_valid=1
    got_vendor=$(echo "$got" | sed -E 's/-[0-9]{2}-[a-z]{3}-[0-9]{2}$//')
    [[ "$got_vendor" == "$exp_vendor" ]] && is_vendor=1

    exact=$((exact + is_exact))
    valid=$((valid + is_valid))
    vendor_ok=$((vendor_ok + is_vendor))

    printf '  %-28s expect=%-28s got=%-28s exact=%s valid=%s vendor=%s %sms\n' \
      "$s" "$expected" "$got" "$is_exact" "$is_valid" "$is_vendor" "$ms"
    echo "\"$model\",$s,$expected,$got,$is_exact,$is_valid,$is_vendor,$ms" >> "$SUMMARY"
  done
  if [[ $n -gt 0 ]]; then
    avg=$((total_ms / n))
    echo "SCORE $model: exact=$exact/$n valid=$valid/$n vendor=$vendor_ok/$n avg_ms=$avg"
    echo "\"$model\",TOTAL,,,$exact,$valid,$vendor_ok,$avg" >> "$SUMMARY"
  fi
done

echo
echo "Wrote $SUMMARY"
