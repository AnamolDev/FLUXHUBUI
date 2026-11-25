/*
 * Contact sheet for the generated icon set: white glyphs on the panel colour, so the
 * atlas can be judged by eye before anything ships. node tools/icon-sheet.mjs
 */

import { deflateSync, inflateSync } from "node:zlib";
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const iconDir = join(root, "assets", "icons");
const names = readdirSync(iconDir).filter((n) => n.endsWith(".png")).map((n) => n.replace(".png", "")).sort();

const CELL = 84;
const COLS = 8;
const ROWS = Math.ceil(names.length / COLS);
const WIDTH = COLS * CELL;
const HEIGHT = ROWS * CELL;

const rgba = Buffer.alloc(WIDTH * HEIGHT * 4);
for (let i = 0; i < WIDTH * HEIGHT; i += 1) {
  rgba[i * 4] = 24;
  rgba[i * 4 + 1] = 24;
  rgba[i * 4 + 2] = 30;
  rgba[i * 4 + 3] = 255;
}

// Minimal PNG reader for the exact encoder gen-icons.mjs emits: 8-bit RGBA, filter 0.
function readPng(file) {
  const buf = readFileSync(file);
  let offset = 8;
  let width = 0;
  let height = 0;
  const idat = [];

  while (offset < buf.length) {
    const length = buf.readUInt32BE(offset);
    const type = buf.toString("ascii", offset + 4, offset + 8);
    const data = buf.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
    } else if (type === "IDAT") {
      idat.push(data);
    }
    offset += 12 + length;
  }

  const raw = Buffer.concat([Buffer.alloc(0), inflateSync(Buffer.concat(idat))]);
  const out = new Float32Array(width * height);
  const stride = width * 4 + 1;

  for (let y = 0; y < height; y += 1) {
    const rowStart = y * stride + 1;
    for (let x = 0; x < width; x += 1) {
      out[y * width + x] = raw[rowStart + x * 4 + 3] / 255;
    }
  }
  return { width, height, alpha: out };
}

const ICON_SIZE = 40;

names.forEach((name, index) => {
  const png = readPng(join(iconDir, `${name}.png`));
  const col = index % COLS;
  const row = Math.floor(index / COLS);
  const ox = col * CELL + (CELL - ICON_SIZE) / 2;
  const oy = row * CELL + (CELL - ICON_SIZE) / 2;

  for (let y = 0; y < ICON_SIZE; y += 1) {
    for (let x = 0; x < ICON_SIZE; x += 1) {
      const sx = Math.floor((x / ICON_SIZE) * png.width);
      const sy = Math.floor((y / ICON_SIZE) * png.height);
      const coverage = png.alpha[sy * png.width + sx];
      const target = (oy + y) * WIDTH + (ox + x);
      const t = Math.min(1, coverage);
      rgba[target * 4] = Math.round(24 + (231 - 24) * t);
      rgba[target * 4 + 1] = Math.round(24 + (231 - 24) * t);
      rgba[target * 4 + 2] = Math.round(30 + (237 - 30) * t);
    }
  }
});

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(b) {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i += 1) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}

const raw = Buffer.alloc(HEIGHT * (WIDTH * 4 + 1));
let off = 0;
for (let y = 0; y < HEIGHT; y += 1) {
  raw[off] = 0;
  off += 1;
  rgba.copy(raw, off, y * WIDTH * 4, (y + 1) * WIDTH * 4);
  off += WIDTH * 4;
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(WIDTH, 0);
ihdr.writeUInt32BE(HEIGHT, 4);
ihdr[8] = 8;
ihdr[9] = 6;

mkdirSync(join(root, "assets", "previews"), { recursive: true });
writeFileSync(
  join(root, "assets", "previews", "icon-sheet.png"),
  Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]),
);

console.log(`sheet: ${names.length} glyphs -> assets/previews/icon-sheet.png`);
