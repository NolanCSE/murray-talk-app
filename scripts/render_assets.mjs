// Rasterise resources/*.svg into the iOS asset catalogue with the Playwright
// Chromium we already have — no sharp, no native build step, works on Linux.
import { chromium } from "playwright";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "..");
const ICONS = resolve(app, "ios/App/App/Assets.xcassets/AppIcon.appiconset");
const SPLASH = resolve(app, "ios/App/App/Assets.xcassets/Splash.imageset");

async function shot(page, svgPath, size, out) {
  const svg = readFileSync(svgPath, "utf8");
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0;background:#0b0b0d">${svg.replace("<svg ", `<svg width="${size}" height="${size}" `)}</body></html>`);
  await page.screenshot({ path: out, clip: { x: 0, y: 0, width: size, height: size } });
  console.log("wrote", out.replace(app + "/", ""));
}

const browser = await chromium.launch();
const page = await browser.newPage();
mkdirSync(ICONS, { recursive: true }); mkdirSync(SPLASH, { recursive: true });
await shot(page, resolve(app, "resources/icon.svg"), 1024, resolve(ICONS, "AppIcon-512@2x.png"));
writeFileSync(resolve(ICONS, "Contents.json"), JSON.stringify({
  images: [{ filename: "AppIcon-512@2x.png", idiom: "universal", platform: "ios", size: "1024x1024" }],
  info: { author: "xcode", version: 1 } }, null, 2));
for (const [name, scale] of [["splash-2732x2732-2.png", 1], ["splash-2732x2732-1.png", 2], ["splash-2732x2732.png", 3]])
  await shot(page, resolve(app, "resources/splash.svg"), 2732, resolve(SPLASH, name));
writeFileSync(resolve(SPLASH, "Contents.json"), JSON.stringify({
  images: [
    { filename: "splash-2732x2732-2.png", idiom: "universal", scale: "1x" },
    { filename: "splash-2732x2732-1.png", idiom: "universal", scale: "2x" },
    { filename: "splash-2732x2732.png", idiom: "universal", scale: "3x" }],
  info: { author: "xcode", version: 1 } }, null, 2));
await browser.close();
