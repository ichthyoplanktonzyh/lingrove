#!/usr/bin/env node

/**
 * Render the installer's two background scales from Lingrove's approved whale.
 * Finder owns the real app/Applications icons; this art preserves their existing
 * point coordinates. The SVG is also saved so the shipped illustration remains
 * inspectable and reproducible without editing a flattened PNG.
 */
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
const index = args.indexOf('--sharp-module');
const modulePath = index < 0 ? undefined : args[index + 1];
if (index >= 0 && (!modulePath || modulePath.startsWith('--'))) {
  throw new Error('--sharp-module requires a module path.');
}
const sharp = require(modulePath ? path.resolve(modulePath) : 'sharp');
const master = await fs.readFile(path.join(root, 'assets/branding/lingrove-logo.svg'), 'utf8');
const whale = master.match(/<svg\b[^>]*>([\s\S]*)<\/svg>/)?.[1];
if (!whale) throw new Error('The approved whale SVG has no root element.');

// Embed the original path markup unchanged. Scaling the group preserves the
// master proportions, palette, and silhouette while leaving the master intact.
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="700" height="504" viewBox="0 0 700 504">
  <title>Lingrove installer background</title>
  <defs>
    <linearGradient id="paper" x2="0" y2="1">
      <stop stop-color="#FCFDFC"/>
      <stop offset="1" stop-color="#F0F7F7"/>
    </linearGradient>
    <radialGradient id="water">
      <stop stop-color="#3CBFCF" stop-opacity="0.12"/>
      <stop offset="1" stop-color="#3CBFCF" stop-opacity="0"/>
    </radialGradient>
    <filter id="card-shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#174467" flood-opacity="0.06"/>
    </filter>
  </defs>
  <rect width="700" height="504" fill="url(#paper)"/>
  <ellipse cx="588" cy="442" rx="230" ry="160" fill="url(#water)"/>
  <g font-family="Helvetica Neue, Helvetica, sans-serif" text-anchor="middle">
    <text x="350" y="65" font-size="30" font-weight="600" fill="#174467">Lingrove</text>
    <text x="350" y="89" font-size="13" fill="#627B89">Autocomplete and language learning</text>
  </g>
  <g fill="#FFFFFF" fill-opacity="0.8" stroke="#D6E3E7" filter="url(#card-shadow)">
    <rect x="165" y="132" width="124" height="122" rx="16"/>
    <rect x="407" y="132" width="124" height="122" rx="16"/>
  </g>
  <path d="M324 190h45m-12-12 12 12-12 12" fill="none" stroke="#3CBFCF"
    stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="350" y="294" text-anchor="middle" font-family="Helvetica Neue, Helvetica, sans-serif"
    font-size="13" fill="#627B89">Drag Lingrove into Applications</text>
  <g transform="translate(526 324) scale(0.140625)">${whale}</g>
</svg>
`;

const destination = path.join(root, 'assets/release');
await fs.writeFile(path.join(destination, 'dmg_background.svg'), svg);
for (const scale of [1, 2]) {
  const filename = `dmg_background${scale === 1 ? '' : '@2x'}.png`;
  await sharp(Buffer.from(svg), { density: 72 * scale }).png().toFile(path.join(destination, filename));
}
console.log('Generated Lingrove installer backgrounds: 700×504 and 1400×1008.');
