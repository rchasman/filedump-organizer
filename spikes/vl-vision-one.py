import base64, json, time, urllib.request
from pathlib import Path

cands = [
    Path("/Users/roeychasman/git/filedump-organizer/spikes/bench-results/vision/vercel-04-aug-26.png"),
    Path("/Users/roeychasman/git/filedump-organizer/spikes/bench-results/vision/vercel-04-aug-26.pdf.png"),
]
png = next(p for p in cands if p.exists())
img = base64.b64encode(png.read_bytes()).decode()
model = "hf.co/LiquidAI/LFM2.5-VL-1.6B-Extract-GGUF:q4_k_m"
prompt = (
    "Extract merchant and payment date from this receipt image. "
    "Return ONLY JSON with keys vendor, day, month, year. "
    "vendor=kebab merchant who charged (not bill-to). "
    "day=01-31, month=jan|feb|...|dec, year=two digits. "
    'Example: {"vendor":"stripe","day":"03","month":"mar","year":"25"}'
)
body = {
    "model": model,
    "prompt": prompt,
    "images": [img],
    "stream": False,
    "format": "json",
    "options": {"temperature": 0},
}
req = urllib.request.Request(
    "http://127.0.0.1:11434/api/generate",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"},
)
t0 = time.time()
with urllib.request.urlopen(req, timeout=180) as resp:
    data = json.load(resp)
ms = int((time.time() - t0) * 1000)
print("png", png, "bytes", png.stat().st_size)
print("ms", ms)
print("response", data.get("response") or data)
out = Path("/Users/roeychasman/git/filedump-organizer/spikes/bench-results/vision/vercel-vl.json")
out.write_text(json.dumps({"ms": ms, "response": data.get("response")}, indent=2))
print("wrote", out)
