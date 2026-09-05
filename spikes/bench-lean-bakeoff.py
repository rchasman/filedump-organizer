#!/usr/bin/env python3
"""Lean-prompt bakeoff: same prompt across local Ollama + Vercel AI Gateway (+ optional Gemini)."""
from __future__ import annotations

import csv
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ORG = Path.home() / "git/filedump-organizer"
OUT = ORG / "spikes/bench-results"
OUT.mkdir(parents=True, exist_ok=True)
LOG = OUT / "lean-bakeoff.log"
CSV_PATH = OUT / "summary-lean-bakeoff.csv"
JSON_PATH = OUT / "summary-lean-bakeoff.json"
RESULTS_MD = OUT / "RESULTS.md"

SAMPLES = [
    "github-21-jul-26",
    "google-30-jun-26",
    "huggingface-01-aug-26",
    "inngest-01-sep-26",
    "linear-27-aug-26",
    "neon-01-sep-26",
    "vercel-04-aug-26",
    "uber-eats-18-jun-26",
    "woolworths-01-jun-25",
    "comfort-suites-03-aug-26",
]

LOCAL_MODELS = [
    "LiquidAI/lfm2.5-1.2b-instruct:q4_k_m",
    "LiquidAI/lfm2.5-350m:q4_k_m",
    "mistral:latest",
    "gemma2:9b",
    "gemma4:latest",
    "llama3.2:latest",
    "deepseek-coder:latest",
]

GATEWAY_MODELS = [
    "alibaba/qwen3.5-flash",
    "google/gemini-2.5-flash",
    "google/gemini-2.5-flash-lite",
    "openai/gpt-4o-mini",
    "anthropic/claude-haiku-4.5",
    "meta/llama-4-scout",
    "mistral/mistral-small",
    "spacexai/grok-4.1-fast-non-reasoning",
]

LEAN = """Read the receipt text. Answer with JSON only:
{"vendor":"<slug>","day":"<DD>","month":"<mon>","year":"<YY>"}

vendor = short lowercase kebab of who ISSUED/CHARGED (header, From, support URL host) — e.g. github, vercel, uber-eats.
NEVER Bill-to / Account billed / customer / restaurant-on-a-delivery-app / Amex/Visa/Mastercard.
Strip Inc/LLC/Ltd (Hugging Face Inc -> huggingface). Keep 1-3 tokens.
Prefer Date paid / issue / order completed date (not due date, not arrival).
month MUST be one of: jan feb mar apr may jun jul aug sep oct nov dec (never a number).
day 01-31; year exactly 2 digits.

RECEIPT TEXT:
"""

INVOICE_RE = re.compile(
    r"^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$"
)

MON = {
    "1": "jan", "01": "jan", "jan": "jan", "january": "jan",
    "2": "feb", "02": "feb", "feb": "feb", "february": "feb",
    "3": "mar", "03": "mar", "mar": "mar", "march": "mar",
    "4": "apr", "04": "apr", "apr": "apr", "april": "apr",
    "5": "may", "05": "may", "may": "may",
    "6": "jun", "06": "jun", "jun": "jun", "june": "jun",
    "7": "jul", "07": "jul", "jul": "jul", "july": "jul",
    "8": "aug", "08": "aug", "aug": "aug", "august": "aug",
    "9": "sep", "09": "sep", "sep": "sep", "september": "sep", "sept": "sep",
    "10": "oct", "oct": "oct", "october": "oct",
    "11": "nov", "nov": "nov", "november": "nov",
    "12": "dec", "dec": "dec", "december": "dec",
}

_log_fp = None


def log(msg: str) -> None:
    global _log_fp
    line = msg if msg.endswith("\n") else msg + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    if _log_fp is None:
        _log_fp = open(LOG, "a", encoding="utf-8")
    _log_fp.write(line)
    _log_fp.flush()


def load_gateway_key() -> str | None:
    p = ORG / ".env.gateway"
    if not p.exists():
        return None
    m = re.search(r'^AI_GATEWAY_API_KEY=["\']?([^\s"\']+)', p.read_text(errors="ignore"), re.M)
    return m.group(1).strip() if m else None


def load_gemini_key() -> str | None:
    for p in [ORG / ".env", Path.home() / "Downloads/.organize/.env"]:
        if not p.exists():
            continue
        m = re.search(r'^GEMINI_API_KEY=["\']?([^\s"\']+)', p.read_text(errors="ignore"), re.M)
        if m:
            return m.group(1).strip()
    return None


def clean_vendor(v: str) -> str:
    v = re.sub(r"[^a-z0-9 -]", "", str(v or "").lower())
    v = re.sub(r"\s+", "-", v)
    v = re.sub(r"[^a-z0-9-]", "", v)
    v = re.sub(r"-(inc|llc|ltd|limited|corp|corporation|co)$", "", v)
    return v.strip("-")[:40]


def norm_month(m) -> str:
    m = re.sub(r"[^a-z0-9]", "", str(m or "").lower())
    return MON.get(m) or MON.get(m[:3]) or (m[:3] if m else "")


def norm_day(d) -> str:
    d = re.sub(r"[^0-9]", "", str(d or ""))
    try:
        return f"{int(d):02d}" if d else ""
    except Exception:
        return ""


def norm_year(y) -> str:
    y = re.sub(r"[^0-9]", "", str(y or ""))
    if len(y) == 4:
        y = y[-2:]
    return y


def to_name(obj: dict) -> str:
    vendor = clean_vendor(obj.get("vendor") or obj.get("issuer") or "")
    day = norm_day(obj.get("day"))
    month = norm_month(obj.get("month"))
    year = norm_year(obj.get("year"))
    return f"{vendor}-{day}-{month}-{year}"


def parse_json_loose(raw: str) -> dict:
    raw = (raw or "").strip()
    if not raw:
        return {}
    try:
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else {}
    except Exception:
        pass
    m = re.search(r"\{[\s\S]*\}", raw)
    if m:
        try:
            obj = json.loads(m.group(0))
            return obj if isinstance(obj, dict) else {}
        except Exception:
            pass
    return {}


def ask_ollama(model: str, text: str) -> tuple[dict, str, str | None]:
    body = {
        "model": model,
        "prompt": LEAN + text[:5500],
        "stream": False,
        "format": "json",
        "options": {"temperature": 0, "top_p": 0.1},
    }
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            raw = json.load(resp).get("response") or "{}"
        return parse_json_loose(raw), raw, None
    except Exception as e:
        return {}, "", str(e)[:200]


def ask_gateway(model: str, text: str, key: str) -> tuple[dict, str, str | None]:
    body = {
        "model": model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": "You extract structured invoice fields. Reply with JSON only."},
            {"role": "user", "content": LEAN + text[:5500]},
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
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
        raw = data["choices"][0]["message"]["content"]
        return parse_json_loose(raw), raw, None
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", errors="ignore")[:300]
        except Exception:
            detail = ""
        return {}, "", f"HTTP {e.code}: {detail}"
    except Exception as e:
        return {}, "", str(e)[:200]


def ask_gemini(text: str, key: str) -> tuple[dict, str, str | None]:
    # Gemini 2.5 Flash via Google AI Studio generateContent
    model = "gemini-2.5-flash"
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
    body = {
        "contents": [{"role": "user", "parts": [{"text": LEAN + text[:5500]}]}],
        "generationConfig": {
            "temperature": 0,
            "topP": 0.1,
            "responseMimeType": "application/json",
        },
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
        raw = data["candidates"][0]["content"]["parts"][0]["text"]
        return parse_json_loose(raw), raw, None
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", errors="ignore")[:300]
        except Exception:
            detail = ""
        return {}, "", f"HTTP {e.code}: {detail}"
    except Exception as e:
        return {}, "", str(e)[:200]


def score_row(expected: str, got: str) -> tuple[int, int, int]:
    exp_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}(-[0-9]+)?$", "", expected)
    exact = int(got == expected)
    valid = int(bool(INVOICE_RE.match(got)))
    got_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}$", "", got)
    vendor_ok = int(got_vendor == exp_vendor)
    return exact, valid, vendor_ok


def run_model(model: str, source: str, ask_fn) -> dict:
    rows = []
    exact = vendor_ok = valid = total_ms = 0
    n = 0
    misses = []
    log(f"\n======== {source}:{model} ========")
    for stem in SAMPLES:
        md = OUT / f"{stem}.md"
        text = md.read_text(errors="ignore") if md.exists() else ""
        expected = stem
        t0 = time.time()
        obj, raw, err = ask_fn(text)
        ms = int((time.time() - t0) * 1000)
        got = to_name(obj if isinstance(obj, dict) else {})
        e, v, ven = score_row(expected, got)
        exact += e
        valid += v
        vendor_ok += ven
        total_ms += ms
        n += 1
        note = f" ERR={err}" if err else ""
        log(f"  {stem:28} got={got:40} e={e} ven={ven} v={v} {ms}ms{note}")
        if not e:
            misses.append(f"{stem}: got={got} expected={expected}")
        rows.append({
            "model": model,
            "sample": stem,
            "expected": expected,
            "got": got,
            "exact": e,
            "valid_format": v,
            "vendor_ok": ven,
            "ms": ms,
            "source": source,
            "err": err or "",
        })
    avg_ms = total_ms // n if n else 0
    log(f"SCORE {source}:{model}: exact={exact}/{n} vendor={vendor_ok}/{n} valid={valid}/{n} avg_ms={avg_ms}")
    return {
        "model": model,
        "source": source,
        "exact": exact,
        "vendor_ok": vendor_ok,
        "valid_format": valid,
        "n": n,
        "avg_ms": avg_ms,
        "rows": rows,
        "misses": misses,
    }


def main() -> None:
    # fresh log
    LOG.write_text(f"lean-bakeoff start {time.strftime('%Y-%m-%d %H:%M:%S UTC')}\n")
    global _log_fp
    _log_fp = open(LOG, "a", encoding="utf-8")

    all_results = []
    all_rows = []

    # --- Local Ollama ---
    for model in LOCAL_MODELS:
        res = run_model(model, "local", lambda text, m=model: ask_ollama(m, text))
        all_results.append(res)
        all_rows.extend(res["rows"])

    # --- Gateway ---
    gw_key = load_gateway_key()
    if gw_key:
        log(f"\ngateway key loaded (len={len(gw_key)})")
        for model in GATEWAY_MODELS:
            res = run_model(model, "gateway", lambda text, m=model: ask_gateway(m, text, gw_key))
            all_results.append(res)
            all_rows.extend(res["rows"])
        # If any ≥8/10, try 1–2 stronger variants
        best_exact = max((r["exact"] for r in all_results if r["source"] == "gateway"), default=0)
        if best_exact >= 8:
            extras = ["openai/gpt-4o", "google/gemini-2.5-pro"]
            for model in extras:
                log(f"\n(extra strong variant because gateway hit ≥8)")
                res = run_model(model, "gateway", lambda text, m=model: ask_gateway(m, text, gw_key))
                all_results.append(res)
                all_rows.extend(res["rows"])
    else:
        log("NO gateway key — skipping gateway models")

    # --- Gemini direct ---
    gem_key = load_gemini_key()
    if gem_key:
        log(f"\ngemini key loaded (len={len(gem_key)})")
        res = run_model("gemini-2.5-flash (direct)", "gemini", lambda text: ask_gemini(text, gem_key))
        all_results.append(res)
        all_rows.extend(res["rows"])
    else:
        log("NO gemini key — skipping")

    # If nothing beats 7/10 and local best ≤6, note large models skipped per instructions
    best_overall = max((r["exact"] for r in all_results), default=0)
    if best_overall < 7:
        log("\nBest still <7/10; large Ollama models (llama3.3/gpt-oss/qwen3-coder/huihui) intentionally skipped per instructions.")

    # Rank
    ranked = sorted(
        all_results,
        key=lambda r: (-r["exact"], -r["vendor_ok"], -r["valid_format"], r["avg_ms"], 0 if r["source"] == "local" else 1),
    )

    # CSV
    with open(CSV_PATH, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["model", "sample", "expected", "got", "exact", "valid_format", "vendor_ok", "ms", "source"],
        )
        w.writeheader()
        for row in all_rows:
            w.writerow({k: row[k] for k in w.fieldnames})
        # TOTAL rows
        for r in ranked:
            w.writerow({
                "model": r["model"],
                "sample": "TOTAL",
                "expected": "",
                "got": "",
                "exact": r["exact"],
                "valid_format": r["valid_format"],
                "vendor_ok": r["vendor_ok"],
                "ms": r["avg_ms"],
                "source": r["source"],
            })

    # JSON summary
    summary = {
        "ranked": [
            {
                "model": r["model"],
                "source": r["source"],
                "exact": r["exact"],
                "vendor_ok": r["vendor_ok"],
                "valid_format": r["valid_format"],
                "avg_ms": r["avg_ms"],
                "n": r["n"],
                "misses": r["misses"],
            }
            for r in ranked
        ],
        "winner_criteria": "highest exact/10; tie-break vendor_ok, valid_format, latency, local-preferred",
    }
    if ranked:
        top = ranked[0]
        if top["exact"] >= 7:
            summary["winner"] = f"{top['source']}:{top['model']} ({top['exact']}/10 exact)"
        else:
            summary["winner"] = None
            summary["top3"] = [
                f"{r['source']}:{r['model']} exact={r['exact']} vendor={r['vendor_ok']} valid={r['valid_format']} avg_ms={r['avg_ms']}"
                for r in ranked[:3]
            ]
            summary["note"] = f"Best still {top['exact']}/10 — no clear ≥7 winner"
    JSON_PATH.write_text(json.dumps(summary, indent=2))

    # Append RESULTS.md
    lines = []
    lines.append("\n\n## Lean-prompt bakeoff (identical lean prompt, all models)\n")
    lines.append(f"_Generated {time.strftime('%Y-%m-%d %H:%M UTC')}_\n")
    lines.append("| Rank | Model | Source | Exact | Vendor OK | Valid | Avg ms |")
    lines.append("|---:|---|---|---:|---:|---:|---:|")
    for i, r in enumerate(ranked, 1):
        lines.append(
            f"| {i} | `{r['model']}` | {r['source']} | {r['exact']}/10 | {r['vendor_ok']}/10 | {r['valid_format']}/10 | {r['avg_ms']} |"
        )
    if ranked and ranked[0]["exact"] >= 7:
        w = ranked[0]
        lines.append(f"\n**Winner:** `{w['source']}:{w['model']}` — **{w['exact']}/10 exact**, vendor {w['vendor_ok']}/10, avg {w['avg_ms']} ms.\n")
    elif ranked:
        lines.append(f"\n**No clear ≥7/10 winner.** Best: `{ranked[0]['source']}:{ranked[0]['model']}` at {ranked[0]['exact']}/10. Top 3 listed above.\n")
    lines.append("\nWorst misses (top contenders):\n")
    for r in ranked[:5]:
        if r["misses"]:
            lines.append(f"- `{r['model']}`: " + "; ".join(r["misses"][:5]))
        else:
            lines.append(f"- `{r['model']}`: (no misses)")
    lines.append(f"\nArtifacts: `{CSV_PATH.name}`, `{JSON_PATH.name}`, `{LOG.name}`.\n")
    with open(RESULTS_MD, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    log("\n===== LEADERBOARD =====")
    for i, r in enumerate(ranked, 1):
        log(f"{i:2}. {r['exact']}/10 exact  ven={r['vendor_ok']} valid={r['valid_format']} avg={r['avg_ms']}ms  [{r['source']}] {r['model']}")
    if ranked and ranked[0]["exact"] >= 7:
        log(f"\nWINNER: {ranked[0]['source']}:{ranked[0]['model']} ({ranked[0]['exact']}/10)")
    else:
        log(f"\nNO ≥7 winner. Top: {ranked[0]['source']}:{ranked[0]['model']} ({ranked[0]['exact']}/10)" if ranked else "No results")
    log(f"Wrote {CSV_PATH}")
    log(f"Wrote {JSON_PATH}")
    log(f"Appended {RESULTS_MD}")

    if _log_fp:
        _log_fp.close()


if __name__ == "__main__":
    main()
