#!/usr/bin/env python3
"""Round 2 lean-prompt bakeoff: flash/Kimi/Qwen/GLM family via Vercel AI Gateway."""
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
LOG = OUT / "lean-bakeoff-round2.log"
CSV_PATH = OUT / "summary-lean-bakeoff-round2.csv"
JSON_PATH = OUT / "summary-lean-bakeoff-round2.json"
RESULTS_MD = OUT / "RESULTS.md"
PRIOR_JSON = OUT / "summary-lean-bakeoff.json"
GATEWAY_MODELS_TXT = OUT / "gateway-models.txt"

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

PRIORITY_MODELS = [
    "moonshotai/kimi-k2.5",
    "moonshotai/kimi-k3-fast",
    "moonshotai/kimi-k2",
    "alibaba/qwen3.7-flash",
    "alibaba/qwen3.8-flash",
    "alibaba/qwen3.8-flash-next",
    "alibaba/qwen3.5-plus",
    "zai/glm-4.7-flash",
    "zai/glm-5.3-flash",
    "zai/glm-4.5-air",
    "deepseek/deepseek-v4-flash",
    "google/gemini-3-flash",
    "google/gemini-3.1-flash-lite",
    "google/gemini-3.5-flash-lite",
    "google/gemini-3.5-flash",
    "meta/llama-4-maverick",
    "amazon/nova-2-lite",
    "stepfun/step-3.5-flash",
    "openai/gpt-4.1-mini",
    "openai/gpt-5-mini",
]

# Sanity re-verify of round1 winner (once)
SANITY_MODEL = "meta/llama-4-scout"

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


def load_gateway_catalog() -> set[str]:
    if not GATEWAY_MODELS_TXT.exists():
        return set()
    return {ln.strip() for ln in GATEWAY_MODELS_TXT.read_text().splitlines() if ln.strip()}


def prior_exact_scores() -> dict[str, int]:
    if not PRIOR_JSON.exists():
        return {}
    data = json.loads(PRIOR_JSON.read_text())
    out = {}
    for r in data.get("ranked", []):
        if r.get("source") == "gateway":
            out[r["model"]] = int(r["exact"])
    return out


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
        with urllib.request.urlopen(req, timeout=120) as resp:
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
    LOG.write_text(f"lean-bakeoff-round2 start {time.strftime('%Y-%m-%d %H:%M:%S UTC')}\n")
    global _log_fp
    _log_fp = open(LOG, "a", encoding="utf-8")

    gw_key = load_gateway_key()
    if not gw_key:
        log("NO gateway key — abort")
        return
    log(f"gateway key loaded (len={len(gw_key)})")

    catalog = load_gateway_catalog()
    prior = prior_exact_scores()
    log(f"prior gateway models with scores: {len(prior)}")
    log(f"gateway catalog entries: {len(catalog)}")

    all_results = []
    all_rows = []

    # Sanity: re-verify scout once
    log(f"\n(sanity re-verify of round1 winner {SANITY_MODEL})")
    res = run_model(SANITY_MODEL, "gateway", lambda text, m=SANITY_MODEL: ask_gateway(m, text, gw_key))
    all_results.append(res)
    all_rows.extend(res["rows"])

    # Priority set
    for model in PRIORITY_MODELS:
        if model in prior and model != SANITY_MODEL:
            log(f"\nSKIP {model} — already in summary-lean-bakeoff.json with exact={prior[model]}")
            continue
        if catalog and model not in catalog:
            log(f"\nSKIP {model} — not in gateway-models.txt catalog")
            continue
        res = run_model(model, "gateway", lambda text, m=model: ask_gateway(m, text, gw_key))
        all_results.append(res)
        all_rows.extend(res["rows"])

    # Extras if any ≥8/10 (excluding sanity scout for threshold? include all round2 runs)
    best_exact = max((r["exact"] for r in all_results), default=0)
    # Also consider: if any NEW model (not scout) hits ≥8, or scout itself counts for extras trigger
    hit_ge8 = any(r["exact"] >= 8 for r in all_results)
    flash_ge8 = any(
        r["exact"] >= 8 and "deepseek-v4-flash" in r["model"] for r in all_results
    )

    if hit_ge8:
        extras = []
        # kimi-k3
        extras.append("moonshotai/kimi-k3")
        # glm-5.3-fast
        extras.append("zai/glm-5.3-fast")
        # qwen3.8-plus if exists
        if not catalog or "alibaba/qwen3.8-plus" in catalog:
            extras.append("alibaba/qwen3.8-plus")
        else:
            log("\n(extra) alibaba/qwen3.8-plus NOT in gateway catalog — skip")
        # deepseek-v4-pro only if flash ≥8
        if flash_ge8:
            extras.append("deepseek/deepseek-v4-pro")
        else:
            log("\n(extra) deepseek/deepseek-v4-pro skipped — deepseek-v4-flash did not hit ≥8")

        for model in extras:
            if any(r["model"] == model for r in all_results):
                continue
            if catalog and model not in catalog:
                log(f"\nSKIP extra {model} — not in gateway catalog")
                continue
            log(f"\n(extra strong variant because some model hit ≥8)")
            res = run_model(model, "gateway", lambda text, m=model: ask_gateway(m, text, gw_key))
            all_results.append(res)
            all_rows.extend(res["rows"])
    else:
        log("\nNo model hit ≥8/10 — skipping extras")

    ranked = sorted(
        all_results,
        key=lambda r: (-r["exact"], -r["vendor_ok"], -r["valid_format"], r["avg_ms"]),
    )

    with open(CSV_PATH, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["model", "sample", "expected", "got", "exact", "valid_format", "vendor_ok", "ms", "source"],
        )
        w.writeheader()
        for row in all_rows:
            w.writerow({k: row[k] for k in w.fieldnames})
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

    summary = {
        "round": 2,
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
        "winner_criteria": "highest exact/10; tie-break vendor_ok, valid_format, latency",
        "round1_winner": "meta/llama-4-scout (8/10)",
        "beats_scout": False,
    }
    if ranked:
        top = ranked[0]
        summary["winner"] = f"{top['source']}:{top['model']} ({top['exact']}/10 exact)"
        non_scout = [r for r in ranked if r["model"] != SANITY_MODEL]
        best_new = max((r["exact"] for r in non_scout), default=0)
        summary["best_new_exact"] = best_new
        summary["beats_scout"] = best_new > 8 or (
            best_new >= 8 and any(
                r["exact"] >= 8 and r["model"] != SANITY_MODEL and (
                    r["exact"] > 8
                    or r["vendor_ok"] > 8
                    or (r["exact"] == 8 and r["avg_ms"] < next(
                        (x["avg_ms"] for x in ranked if x["model"] == SANITY_MODEL), 99999
                    ))
                )
                for r in ranked
            )
        )
        # Clearer: anything strictly >8, or ==8 with notes
        summary["beats_scout"] = any(r["exact"] > 8 for r in non_scout)
        summary["ties_scout"] = any(r["exact"] == 8 for r in non_scout)

    JSON_PATH.write_text(json.dumps(summary, indent=2))

    # Append RESULTS.md section
    lines = []
    lines.append("\n\n## Round 2: flash/Kimi/Qwen/GLM\n")
    lines.append(f"_Generated {time.strftime('%Y-%m-%d %H:%M UTC')}_ — same lean prompt + postprocess + 10 samples.\n")
    lines.append("| Rank | Model | Exact | Vendor OK | Valid | Avg ms |")
    lines.append("|---:|---|---:|---:|---:|---:|")
    for i, r in enumerate(ranked, 1):
        mark = " ← scout sanity" if r["model"] == SANITY_MODEL else ""
        lines.append(
            f"| {i} | `{r['model']}`{mark} | {r['exact']}/10 | {r['vendor_ok']}/10 | {r['valid_format']}/10 | {r['avg_ms']} |"
        )
    scout_exact = next((r["exact"] for r in ranked if r["model"] == SANITY_MODEL), 8)
    best_new_r = next((r for r in ranked if r["model"] != SANITY_MODEL), None)
    if summary.get("beats_scout"):
        lines.append(f"\n**Beats round1 scout:** yes — best new `{best_new_r['model']}` at {best_new_r['exact']}/10 (scout sanity {scout_exact}/10).\n")
    elif summary.get("ties_scout"):
        ties = [r["model"] for r in ranked if r["model"] != SANITY_MODEL and r["exact"] == 8]
        lines.append(f"\n**Beats round1 scout:** no (strict >8). Ties at 8/10: {', '.join(f'`{t}`' for t in ties)}. Scout sanity: {scout_exact}/10.\n")
    else:
        be = best_new_r["exact"] if best_new_r else 0
        bm = best_new_r["model"] if best_new_r else "?"
        lines.append(f"\n**Beats round1 scout:** no. Best new `{bm}` at {be}/10 vs scout sanity {scout_exact}/10.\n")

    lines.append("\nWorst misses (≥7 exact):\n")
    for r in ranked:
        if r["exact"] >= 7:
            if r["misses"]:
                lines.append(f"- `{r['model']}` ({r['exact']}/10): " + "; ".join(r["misses"]))
            else:
                lines.append(f"- `{r['model']}` ({r['exact']}/10): (no misses)")
    lines.append(f"\nArtifacts: `{CSV_PATH.name}`, `{JSON_PATH.name}`, `{LOG.name}`.\n")
    with open(RESULTS_MD, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    log("\n===== ROUND2 LEADERBOARD =====")
    for i, r in enumerate(ranked, 1):
        log(f"{i:2}. {r['exact']}/10 exact  ven={r['vendor_ok']} valid={r['valid_format']} avg={r['avg_ms']}ms  {r['model']}")
    log(f"beats_scout={summary.get('beats_scout')} ties_scout={summary.get('ties_scout')}")
    log(f"Wrote {CSV_PATH}")
    log(f"Wrote {JSON_PATH}")
    log(f"Appended {RESULTS_MD}")

    if _log_fp:
        _log_fp.close()


if __name__ == "__main__":
    main()
