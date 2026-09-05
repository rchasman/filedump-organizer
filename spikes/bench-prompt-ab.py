#!/usr/bin/env python3
"""A/B lean vs rich extract schemas for Liquid 1.2b (prompt-only, no regex)."""
import json, re, time, urllib.request
from pathlib import Path

OUT = Path.home() / "git/filedump-organizer/spikes/bench-results"
MODEL = "LiquidAI/lfm2.5-1.2b-instruct:q4_k_m"
SAMPLES = [
    "github-21-jul-26.pdf","google-30-jun-26.pdf","huggingface-01-aug-26.pdf","inngest-01-sep-26.pdf",
    "linear-27-aug-26.pdf","neon-01-sep-26.pdf","vercel-04-aug-26.pdf","uber-eats-18-jun-26.pdf",
    "woolworths-01-jun-25.pdf","comfort-suites-03-aug-26.pdf",
]
INVOICE_RE = re.compile(r"^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$")
MON = {
    "1":"jan","01":"jan","jan":"jan","january":"jan",
    "2":"feb","02":"feb","feb":"feb","february":"feb",
    "3":"mar","03":"mar","mar":"mar","march":"mar",
    "4":"apr","04":"apr","apr":"apr","april":"apr",
    "5":"may","05":"may","may":"may",
    "6":"jun","06":"jun","jun":"jun","june":"jun",
    "7":"jul","07":"jul","jul":"jul","july":"jul",
    "8":"aug","08":"aug","aug":"aug","august":"aug",
    "9":"sep","09":"sep","sep":"sep","september":"sep",
    "10":"oct","oct":"oct","october":"oct",
    "11":"nov","nov":"nov","november":"nov",
    "12":"dec","dec":"dec","december":"dec",
}

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

RICH = """Read the receipt text. Answer with JSON only (fill every field; use null if unknown):
{
  "issuer": "<company that issued/charged — header/From/support domain>",
  "bill_to": "<customer or account billed, or null>",
  "restaurant_or_merchant_line": "<store/restaurant if different from issuer, else null>",
  "payment_method": "<Amex/Visa/... or null>",
  "amount_total": "<number or null>",
  "currency": "<USD/AUD/... or null>",
  "date_paid": "<ISO YYYY-MM-DD or null>",
  "date_issued": "<ISO YYYY-MM-DD or null>",
  "date_due": "<ISO YYYY-MM-DD or null>",
  "invoice_or_txn_id": "<id or null>",
  "vendor": "<short lowercase kebab of issuer only; never bill_to, never restaurant_or_merchant_line, never payment_method>",
  "day": "<DD from date_paid else date_issued>",
  "month": "<mon abbr from that date: jan..dec>",
  "year": "<YY from that date>"
}

Rules:
- issuer/vendor = who charged (GitHub, Vercel, Uber Eats, Woolworths, Comfort Suites).
- On delivery apps, issuer is the platform (uber-eats), restaurant goes in restaurant_or_merchant_line.
- Never put Bill-to / Account billed into vendor.
- month must be jan..dec never a number; year exactly 2 digits; day 01-31.
- Prefer date_paid over date_issued; ignore date_due for day/month/year.

RECEIPT TEXT:
"""

def ask(prompt_prefix, text):
    body = {
        "model": MODEL,
        "prompt": prompt_prefix + text[:5500],
        "stream": False,
        "format": "json",
        "options": {"temperature": 0, "top_p": 0.1},
    }
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        raw = json.load(resp).get("response") or "{}"
    try:
        return json.loads(raw), raw
    except Exception:
        m = re.search(r"\{[\s\S]*\}", raw)
        if m:
            try:
                return json.loads(m.group(0)), raw
            except Exception:
                pass
        return {}, raw

def clean_vendor(v):
    v = re.sub(r"[^a-z0-9 -]", "", str(v or "").lower())
    v = re.sub(r"\s+", "-", v)
    v = re.sub(r"[^a-z0-9-]", "", v)
    v = re.sub(r"-(inc|llc|ltd|limited|corp|corporation|co)$", "", v)
    return v.strip("-")[:40]

def norm_month(m):
    m = re.sub(r"[^a-z0-9]", "", str(m or "").lower())
    return MON.get(m) or MON.get(m[:3]) or m[:3]

def norm_day(d):
    d = re.sub(r"[^0-9]", "", str(d or ""))
    try:
        return f"{int(d):02d}" if d else ""
    except Exception:
        return ""

def norm_year(y):
    y = re.sub(r"[^0-9]", "", str(y or ""))
    if len(y) == 4:
        y = y[-2:]
    return y

def iso_to_dmy(iso):
    if not iso or not isinstance(iso, str):
        return None
    m = re.match(r"(20\d{2})-(\d{2})-(\d{2})", iso.strip())
    if not m:
        return None
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    months = {1:"jan",2:"feb",3:"mar",4:"apr",5:"may",6:"jun",7:"jul",8:"aug",9:"sep",10:"oct",11:"nov",12:"dec"}
    return f"{d:02d}", months[mo], f"{y%100:02d}"

def to_name(obj, prefer_iso=False):
    vendor = clean_vendor(obj.get("vendor") or obj.get("issuer") or "")
    day = month = year = ""
    if prefer_iso:
        for key in ("date_paid", "date_issued"):
            parsed = iso_to_dmy(obj.get(key))
            if parsed:
                day, month, year = parsed
                break
    if not (day and month and year):
        day = norm_day(obj.get("day"))
        month = norm_month(obj.get("month"))
        year = norm_year(obj.get("year"))
    return f"{vendor}-{day}-{month}-{year}"

def run(label, prompt, prefer_iso=False):
    exact = vendor_ok = valid = 0
    rows = []
    print(f"\n======== {label} / {MODEL} ========")
    for sample in SAMPLES:
        expected = Path(sample).stem
        exp_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}(-[0-9]+)?$", "", expected)
        text = (OUT / f"{expected}.md").read_text(errors="ignore")
        t0 = time.time()
        obj, raw = ask(prompt, text)
        got = to_name(obj, prefer_iso=prefer_iso)
        ms = int((time.time() - t0) * 1000)
        e = int(got == expected)
        v = int(bool(INVOICE_RE.match(got)))
        got_vendor = re.sub(r"-[0-9]{2}-[a-z]{3}-[0-9]{2}$", "", got)
        ven = int(got_vendor == exp_vendor)
        exact += e; valid += v; vendor_ok += ven
        rows.append((sample, expected, got, e, v, ven, ms, obj))
        print(f"  {sample:28} got={got:40} e={e} ven={ven} {ms}ms")
        if not e:
            # show helpful rich fields when present
            bits = {k: obj.get(k) for k in ("issuer","bill_to","restaurant_or_merchant_line","date_paid","date_issued","vendor","day","month","year") if k in obj}
            if bits:
                print(f"    fields={bits}")
    n = len(SAMPLES)
    print(f"SCORE {label}: exact={exact}/{n} vendor={vendor_ok}/{n} valid={valid}/{n}")
    return {"label": label, "exact": exact, "vendor": vendor_ok, "valid": valid, "n": n, "rows": rows}

def main():
    lean = run("lean-current", LEAN, prefer_iso=False)
    rich = run("rich-discard", RICH, prefer_iso=True)
    # also: rich but only use vendor/day/month/year fields (ignore ISO mapping)
    rich_lean_fields = run("rich-but-use-dmy", RICH, prefer_iso=False)
    summary = {
        "lean-current": {k: lean[k] for k in ("exact","vendor","valid","n")},
        "rich-discard": {k: rich[k] for k in ("exact","vendor","valid","n")},
        "rich-but-use-dmy": {k: rich_lean_fields[k] for k in ("exact","vendor","valid","n")},
    }
    (OUT / "summary-prompt-ab.json").write_text(json.dumps(summary, indent=2))
    print("\nSUMMARY", json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()
