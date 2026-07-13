// Admin-only tool for adding a custom hat to the shared catalog -- the hat
// counterpart to add-skin.js (see that file for why this is a script run
// on the machine, not an HTTP endpoint). Run this directly on the server.
//
// Usage: node add-hat.js <path-to-png> "<Hat Name>"
//
// The image must be exactly 18x16 (see server.js's HAT_DIMENSIONS and
// skin_catalog.gd's HAT_WIDTH/HAT_HEIGHT) -- this script does not resize
// or validate it, so double check before running.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = path.join(__dirname, 'data');
const SKIN_IMAGE_DIR = path.join(DATA_DIR, 'skin_images');
const CATALOG_JSON_PATH = path.join(DATA_DIR, 'catalog.json');

const [, , imagePath, name] = process.argv;
if (!imagePath || !name) {
  console.error('Usage: node add-hat.js <path-to-png> "<Hat Name>"');
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
const id = 'hat_' + crypto.randomBytes(8).toString('hex');
fs.writeFileSync(path.join(SKIN_IMAGE_DIR, id + '.png'), imageBytes);
catalog.push({ id, name: String(name).slice(0, 40), type: 'hat', createdBy: null, createdAt: Date.now() });
fs.writeFileSync(CATALOG_JSON_PATH, JSON.stringify(catalog));

// No server restart needed -- the catalog endpoint re-reads this file fresh
// on every request, it's never cached in memory.
console.log(`Added hat "${name}" as ${id}`);
