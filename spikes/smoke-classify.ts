import { classifyWithGateway, loadGatewayApiKey } from "../src/gateway.ts";
import { readFile } from "node:fs/promises";

const samples = [
  "vercel-04-aug-26",
  "github-21-jul-26",
  "google-30-jun-26",
  "uber-eats-18-jun-26",
  "neon-01-sep-26",
  "comfort-suites-03-aug-26",
  "woolworths-01-jun-25",
  "huggingface-01-aug-26",
];
const key = await loadGatewayApiKey();
if (!key) throw new Error("no key");
let exact = 0, vendor = 0;
for (const stem of samples) {
  const text = await readFile(`spikes/bench-results/${stem}.md`, "utf8");
  const r = await classifyWithGateway(text, { apiKey: key, filename: `${stem}.pdf` });
  const expVendor = stem.replace(/-\d{2}-[a-z]{3}-\d{2}$/, "");
  const gotVendor = r.name.replace(/-\d{2}-[a-z]{3}-\d{2}$/, "");
  const e = r.category === "Invoices" && r.name === stem ? 1 : 0;
  const v = r.category === "Invoices" && gotVendor === expVendor ? 1 : 0;
  exact += e; vendor += v;
  console.log(`${stem.padEnd(28)} → ${r.category}/${r.name}  e=${e} ven=${v}`);
}
console.log(`SCORE exact=${exact}/${samples.length} vendor=${vendor}/${samples.length}`);
