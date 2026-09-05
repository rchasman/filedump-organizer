import { classifyWithGateway, loadGatewayApiKey } from "../src/gateway.ts";
import { readFile } from "node:fs/promises";
import { validateInvoiceName } from "../src/move.ts";

const samples = [
  ["vercel-04-aug-26", "Receipt-239482.pdf"],
  ["github-21-jul-26", "download.pdf"],
  ["google-30-jun-26", "Statement.pdf"],
  ["uber-eats-18-jun-26", "IMG_9021.pdf"],
  ["neon-01-sep-26", "invoice (1).pdf"],
  ["comfort-suites-03-aug-26", "folio.pdf"],
  ["woolworths-01-jun-25", "Gift Card.pdf"],
  ["huggingface-01-aug-26", "Payment confirmation.pdf"],
] as const;
const key = await loadGatewayApiKey();
if (!key) throw new Error("no key");
let exact = 0, vendor = 0;
for (const [stem, fake] of samples) {
  const text = await readFile(`spikes/bench-results/${stem}.md`, "utf8");
  const r = await classifyWithGateway(text, { apiKey: key, filename: fake });
  const expVendor = stem.replace(/-\d{2}-[a-z]{3}-\d{2}$/, "");
  const gotVendor = r.name.replace(/-\d{2}-[a-z]{3}-\d{2}$/, "");
  const e = r.category === "Invoices" && r.name === stem ? 1 : 0;
  const v = r.category === "Invoices" && gotVendor === expVendor ? 1 : 0;
  const valid = r.category === "Invoices" ? !!validateInvoiceName(r.name) : true;
  exact += e; vendor += v;
  console.log(`${fake.padEnd(28)} expect=${stem.padEnd(26)} got=${r.category}/${r.name} e=${e} ven=${v} validInv=${valid}`);
}
console.log(`BLIND SCORE exact=${exact}/8 vendor=${vendor}/8`);
