// Regenerates every logo format from the brand-src SVG masters.
// Usage: node scripts/export-brand.mjs
// Output: /public/brand (SVG copies + rasterized PNGs + favicon.ico)
import { mkdir, copyFile, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import pngToIco from "png-to-ico";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const srcDir = path.join(root, "brand-src");
const outDir = path.join(root, "public", "brand");

const svgCopies = [
  "vadium-mark.svg",
  "vadium-mark--mono.svg",
  "vadium-mark--reverse.svg",
  "vadium-seal.svg",
  "vadium-seal--amber.svg",
  "vadium-lockup--horizontal.svg",
  "vadium-lockup--stacked.svg",
  "vadium-lockup--reverse.svg",
];

const pngTargets = [
  { src: "vadium-mark.svg", name: "vadium-mark-256.png", size: 256 },
  { src: "vadium-mark.svg", name: "vadium-mark-64.png", size: 64 },
  { src: "vadium-mark.svg", name: "vadium-mark-32.png", size: 32 },
  { src: "vadium-mark.svg", name: "vadium-mark-16.png", size: 16 },
  { src: "vadium-seal.svg", name: "vadium-seal-1024.png", size: 1024 },
  { src: "vadium-seal.svg", name: "vadium-seal-512.png", size: 512 },
  { src: "vadium-lockup--horizontal.svg", name: "vadium-lockup-512.png", size: 512 },
  { src: "vadium-appicon.svg", name: "app-icon-512.png", size: 512 },
  { src: "vadium-appicon.svg", name: "app-icon-192.png", size: 192 },
  { src: "vadium-appicon.svg", name: "apple-touch-icon.png", size: 180 },
  { src: "vadium-appicon.svg", name: "app-icon-120.png", size: 120 },
  { src: "og-cover.svg", name: "og-cover.png", size: null },
];

async function renderSvg(file, size) {
  const buffer = await readFile(path.join(srcDir, file));
  let img = sharp(buffer);
  if (size) {
    img = img.resize(size, size, { fit: "fill", withoutEnlargement: false });
  } else {
    img = img.resize(1200, 630, { fit: "fill" });
  }
  return img.png().toBuffer();
}

async function main() {
  await mkdir(outDir, { recursive: true });

  for (const file of svgCopies) {
    await copyFile(path.join(srcDir, file), path.join(outDir, file));
  }
  await copyFile(path.join(srcDir, "vadium-favicon.svg"), path.join(outDir, "favicon.svg"));

  for (const t of pngTargets) {
    const buffer = await renderSvg(t.src, t.size);
    await writeFile(path.join(outDir, t.name), buffer);
    console.log(`wrote ${t.name}`);
  }

  const icoSizes = [16, 32, 48];
  const icoPngs = await Promise.all(
    icoSizes.map(async (s) => renderSvg("vadium-favicon.svg", s)),
  );
  const ico = await pngToIco(icoPngs);
  await writeFile(path.join(outDir, "favicon.ico"), ico);
  console.log("wrote favicon.ico");

  console.log("brand assets exported to public/brand");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});