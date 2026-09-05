#!/usr/bin/env python3
"""Benchmark invoice naming via Vercel AI Gateway (OpenAI-compatible)."""
from __future__ import annotations

import json, re, time, urllib.error, urllib.request
from pathlib import Path

HOME = Path.home()
ORG = HOME / "git/filedump-organizer"
INV = HOME / "Downloads/Invoices"
OUT = ORG / "spikes/bench-results"
OUT.mkdir(parents=True, exist_ok=True)

SAMPLES = [
    "github-21-jul-26.pdf",
    "google-30-jun-26.pdf",
    "huggingface-01-aug-26.pdf",
    "inngest-01-sep-26.pdf",
    "linear-27-aug-26.pdf",
    "neon-01-sep-26.pdf",
    "vercel-04-aug-26.pdf",
    "uber-eats-18-jun-26.pdf",
    "woolworths-01-jun-25.pdf",
    "comfort-suites-03-aug-26.pdf",
]

MODELS = [
    "google/gemini-2.5-flash",
    "google/gemini-2.5-flash-lite",
    "openai/gpt-4o-mini",
    "openai/gpt-5-nano",
    "anthropic/claude-haiku-4.5",
    "meta/llama-4-scout",
    "mistral/mistral-small",
    "deepseek/deepseek-v3.2",
    "alibaba/qwen3.5-flash",
    "spacexai/grok-4.1-fast-non-reasoning",
]

PROMPT = """Extract merchant/issuer and payment/issue date from the receipt.
Merchant = who charged (e.g. github, google, neon) — NEVER the bill-to customer.
Return ONLY JSON with keys: vendor, day, month, year.
- vendor: lowercase kebab, 1-3 words
- day: two digits 01-31
- month: exactly one of jan feb mar apr may jun jul aug sep oct nov dec
- year: two digits (26 for 2026)
Examples:
{"vendor":"stripe","day":"03","month":"mar","year":"25"}
{"vendor":"aws","day":"15","month":"dec","year":"24"}

Text:
"""

INVOICE_RE = re.compile(
    r"^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$"
)

def load_key() -> str:
    # Prefer organizer-local symlink/copy if present; else known project envs
    for p in [
        ORG / ".env.gateway",
        HOME / "git/ascii-render/.env.local",
        HOME / "git/dominion-maker/.env",
        HOME / "LEAP/legal-crm-pilot/.env",
    ]:
        if not p.exists():
            continue
        m = re.search(r'^AI_GATEWAY_API_KEY=["\']?([^\s"\']+)', p.read_text(errors="ignore"), re.M)
        if m:
            return m.group(1).strip()
    raise SystemExit("AI_GATEWAY_API_KEY not found")


def normalize(obj: dict) -> str:
    vendor = re.sub(r"[^a-z0-9-]", "", str(obj.get("vendor", "")).lower())[:40]
    day_raw = re.sub(r"[^0-9]", "", str(obj.get("day", "")))
    month = re.sub(r"[^a-z]", "", str(obj.get("month", "")).lower())[:3]
    year = re.sub(r"[^0-9]", "", str(obj.get("year", "")))
    if len(year) == 4:
        year = year[-2:]
    try:
        day = f"{int(day_raw):02d}" if day_raw else ""
    except Exception:
        day = ""
    return f"{vendor}-{day}-{month}-{year}"


def chat(model: str, text: str, key: str) -> str:
    body = {
        "model": model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": "You extract structured invoice fields. Reply with JSON only."},
            {"role": "user", "content": PROMPT + text[:6000]},
        ],
    }
    req = urllib.request.Request(
        "https://ai-gateway.vercel.sh/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.load(resp)
    return data["choices"][0]["message"]["content"]


def main() -> None:
    key = load_key()
    print(f"gateway key ok (len={len(key)})")
    summary = OUT / "summary-gateway.csv"
    rows = ["model,sample,expected,got,exact,valid_format,vendor_ok,ms"]

    for model in MODELS:
        print(f"\n======== {model} ========")
        exact = valid = vendor_ok = n = total_ms = 0
        for sample in SAMPLES:
            md = OUT / f"{Path(sample).stem}.md"
            if not md.exists() or md.stat().st_size == 0:
                print("skip", sample)
                continue
            expected = Path(sample).stem
            exp_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}(-[0-9]+)?$", "", expected)
            text = md.read_text(errors="ignore")
            t0 = time.time()
            try:
                raw = chat(model, text, key)
                err = None
            except Exception as e:
                raw = "{}"
                err = str(e)[:120]
            ms = int((time.time() - t0) * 1000)
            try:
                obj = json.loads(raw)
            except Exception:
                m = re.search(r"\{[^{}]*\}", raw or "")
                obj = json.loads(m.group(0)) if m else {}
            got = normalize(obj if isinstance(obj, dict) else {})
            is_exact = int(got in {expected, re.sub(r"-[234]$", "", expected)})
            is_valid = int(bool(INVOICE_RE.match(got)))
            got_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}$", "", got)
            is_vendor = int(got_vendor == exp_vendor)
            exact += is_exact
            valid += is_valid
            vendor_ok += is_vendor
            n += 1
            total_ms += ms
            note = f" ERR={err}" if err else ""
            print(f"  {sample:28} expect={expected:28} got={got:32} e={is_exact} v={is_valid} ven={is_vendor} {ms}ms{note}")
            rows.append(f'"{model}",{sample},{expected},{got},{is_exact},{is_valid},{is_vendor},{ms}')
        if n:
            avg = total_ms // n
            print(f"SCORE {model}: exact={exact}/{n} valid={valid}/{n} vendor={vendor_ok}/{n} avg_ms={avg}")
            rows.append(f'"{model}",TOTAL,,,{exact},{valid},{vendor_ok},{avg}')

    summary.write_text("\n".join(rows) + "\n")
    print("\nWrote", summary)


if __name__ == "__main__":
    main()
