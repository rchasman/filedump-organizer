import { join } from "node:path";
import { classifyWithGateway, loadGatewayApiKey } from "../src/gateway.ts";
import { extractText } from "../src/extract.ts";
import { needsVision, refineHotelFolioResult, renderPdfPage1, cleanupTempImage } from "../src/vision.ts";

const dir = join(process.env.HOME!, "Downloads/Invoices");
const samples = [
  "comfort-suites-03-aug-26.pdf",
  "woolworths-01-jun-25.pdf",
  "vercel-04-aug-26.pdf",
];
const key = await loadGatewayApiKey();
if (!key) throw new Error("no key");

for (const file of samples) {
  const path = join(dir, file);
  const text = await extractText(path);
  const nv = needsVision(text);
  let imagePath: string | null = null;
  const t0 = performance.now();
  try {
    if (nv) imagePath = await renderPdfPage1(path);
    let r = await classifyWithGateway(text, {
      apiKey: key,
      filename: file,
      pdfPath: nv ? path : undefined,
      imagePath: imagePath ?? undefined,
    });
    if (nv) r = refineHotelFolioResult(text, r);
    const ms = Math.round(performance.now() - t0);
    console.log(`${file.padEnd(36)} needsVision=${nv} ${ms}ms → ${r.category}/${r.name}`);
  } finally {
    await cleanupTempImage(imagePath);
  }
}
