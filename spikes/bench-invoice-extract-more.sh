#!/bin/bash
# Round-2 benchmark: additional local models + optional Gemini Flash.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$PATH"

ORG_DIR="${ORG_DIR:-$HOME/git/filedump-organizer}"
INV_DIR="${INV_DIR:-$HOME/Downloads/Invoices}"
OUT_DIR="${OUT_DIR:-$ORG_DIR/spikes/bench-results}"
mkdir -p "$OUT_DIR"

# shellcheck disable=SC1091
if [[ -f "$ORG_DIR/.env" ]]; then
  # only export GEMINI key lines safely
  set -a
  # shellcheck disable=SC1090
  source "$ORG_DIR/.env"
  set +a
fi

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

# Models to bench this round (already-pulled locals + gemini sentinel)
MODELS=(
  "llama3.2:latest"
  "mistral:latest"
  "gemma2:9b"
  "deepseek-coder:latest"
  "gemini-flash"
)

PROMPT_SYS='Extract merchant/issuer and payment/issue date from the receipt.
Merchant = who charged (e.g. github, google, neon) — NEVER the bill-to customer.
Return ONLY JSON with keys: vendor, day, month, year.
- vendor: lowercase kebab, 1-3 words
- day: two digits 01-31
- month: exactly one of jan feb mar apr may jun jul aug sep oct nov dec
- year: two digits (26 for 2026)
Examples:
{"vendor":"stripe","day":"03","month":"mar","year":"25"}
{"vendor":"aws","day":"15","month":"dec","year":"24"}'

INVOICE_RE='^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$'

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

run_ollama() {
  local model="$1" textfile="$2"
  local content prompt raw
  content=$(head -c 6000 "$textfile")
  prompt="$PROMPT_SYS

Text:
$content"
  raw=$(curl -sS --max-time 120 http://127.0.0.1:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" --arg prompt "$prompt" \
      '{model:$model, prompt:$prompt, stream:false, format:"json", options:{temperature:0, top_p:0.1}}')" \
    2>/dev/null | jq -r '.response // empty' 2>/dev/null) || true
  echo "$raw"
}

run_gemini() {
  local textfile="$1"
  local content prompt model key
  content=$(head -c 6000 "$textfile")
  model="${GEMINI_MODEL:-gemini-3-flash-preview}"
  key="${GEMINI_API_KEY:-}"
  [[ -n "$key" ]] || { echo ""; return 0; }
  prompt="$PROMPT_SYS

Text:
$content"
  raw=$(curl -sS --max-time 60 \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg prompt "$prompt" \
      '{contents:[{parts:[{text:$prompt}]}], generationConfig:{temperature:0, responseMimeType:"application/json", responseSchema:{type:"OBJECT", properties:{vendor:{type:"STRING"}, day:{type:"STRING"}, month:{type:"STRING"}, year:{type:"STRING"}}, required:["vendor","day","month","year"]}}}')" \
    2>/dev/null | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null) || true
  echo "$raw"
}

SUMMARY="$OUT_DIR/summary-round2.csv"
echo "model,sample,expected,got,exact,valid_format,vendor_ok,ms" > "$SUMMARY"

echo "Round-2 models: ${MODELS[*]}"
echo "Samples: ${#SAMPLES[@]}"

for model in "${MODELS[@]}"; do
  echo
  echo "======== $model ========"
  exact=0; valid=0; vendor_ok=0; n=0; total_ms=0
  for s in "${SAMPLES[@]}"; do
    pdf="$INV_DIR/$s"
    text="$OUT_DIR/${s%.pdf}.md"
    [[ -f "$pdf" && -s "$text" ]] || { echo "skip $s"; continue; }
    expected="${s%.pdf}"
    exp_vendor=$(echo "$expected" | sed -E 's/-[0-9]{2}-[a-z]{3}-[0-9]{2}(-[0-9]+)?$//')

    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    if [[ "$model" == "gemini-flash" ]]; then
      raw=$(run_gemini "$text")
    else
      raw=$(run_ollama "$model" "$text")
    fi
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    ms=$((end - start))
    total_ms=$((total_ms + ms))
    n=$((n + 1))

    json=$(echo "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null || true)
    if [[ -z "$json" ]]; then
      json=$(echo "$raw" | jq -c '.' 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
      json=$(echo "$raw" | grep -o '{[^}]*}' | head -1 || true)
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

    printf '  %-28s expect=%-28s got=%-32s e=%s v=%s ven=%s %sms\n' \
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
