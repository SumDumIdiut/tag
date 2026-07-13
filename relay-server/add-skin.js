// Admin-only tool for adding a custom skin to the shared catalog. Run this
// directly on the server (e.g. over SSH) -- there is deliberately no HTTP
// endpoint that can do this, so a new skin can only be added by someone with
// actual access to the machine, not by any connected game client.
//
// Usage: node add-skin.js <path-to-png> "<Skin Name>"
//
// The image should already be roughly a 32x48 PNG (the in-game skin
// silhouette size) -- this script does not resize it.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = path.join(__dirname, 'data');
const SKIN_IMAGE_DIR = path.join(DATA_DIR, 'skin_images');
const CATALOG_JSON_PATH = path.join(DATA_DIR, 'catalog.json');

const [, , imagePath, name] = process.argv;
if (!imagePath || !name) {
  console.error('Usage: node add-skin.js <path-to-png> "<Skin Name>"');
  process.exit(1);
}

fs.mkdirSync(SKIN_IMAGE_DIR, { recursive: true });

let catalog;
try {
  catalog = JSON.parse(fs.readFileSync(CATALOG_JSON_PATH, 'utf-8'));
} catch {
  catalog = [];
}

const imageBytes = fs.readFileSync(imagePath);
const id = 'custom_' + crypto.randomBytes(8).toString('hex');
fs.writeFileSync(path.join(SKIN_IMAGE_DIR, id + '.png'), imageBytes);
catalog.push({ id, name: String(name).slice(0, 40), type: 'skin', createdBy: null, createdAt: Date.now() });
fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));

// No server restart needed -- the catalog endpoint re-reads this file fresh
// on every request, it's never cached in memory.
console.log(`Added skin "${name}" as ${id}`);
