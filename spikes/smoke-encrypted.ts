import { isPdfEncrypted } from "../src/extract.ts";
console.log("enc", await isPdfEncrypted("/tmp/enc-test.pdf"));
console.log("plain", await isPdfEncrypted("/tmp/plain-test.pdf"));
console.log("vercel", await isPdfEncrypted(`${process.env.HOME}/Downloads/Invoices/vercel-04-aug-26.pdf`));
