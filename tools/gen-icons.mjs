/*
 * Renders the Flux icon set to PNG and emits src/Assets/IconAtlas.lua as base64.
 *
 * Why generated instead of hand-picked asset ids:
 *   - `rbxthumb://` icon URIs resolve only in Studio, so a library consumed from a client
 *     would paint nothing;
 *   - a third-party icon asset database is someone else's upload, and an id that gets
 *     deleted leaves every menu with blank squares;
 *   - GUI frames cannot rotate, so axis-aligned primitives cannot express a diagonal.
 *
 * So the bytes travel with the script: IconManager writes them to the client's cache and
 * points `Image` at `getcustomasset`, exactly like a hub logo already does. Glyphs are
 * white on transparent, which `ImageColor3` tints cleanly, so one asset serves every
 * accent colour.
 *
 * Usage: node tools/gen-icons.mjs [--size 64] [--out src/Assets/IconAtlas.lua]
 */

import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const sizeFlag = argv.indexOf("--size");
const SIZE = sizeFlag === -1 ? 64 : Number(argv[sizeFlag + 1]);
const outFlag = argv.indexOf("--out");
const OUT_LUA = resolve(root, outFlag === -1 ? join("src", "Assets", "IconAtlas.lua") : argv[outFlag + 1]);

/* ------------------------------------------------------------ rasterizer */

// Coverage is computed per pixel from a signed-distance style test, which gives real
// antialiasing without supersampling.
function canvas() {
  return new Float32Array(SIZE * SIZE);
}

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

function paintCoverage(buf, fn) {
  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      // Pixel centre, in the 24-unit icon space.
      const px = (x + 0.5) / SIZE;
      const py = (y + 0.5) / SIZE;
      const coverage = fn(px, py);
      if (coverage <= 0) continue;
      const index = y * SIZE + x;
      // Compose like a screen over black so overlapping strokes stay solid.
      buf[index] = Math.max(buf[index], clamp01(coverage));
    }
  }
}

function distToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const lenSq = dx * dx + dy * dy;
  let t = lenSq === 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lenSq;
  t = clamp01(t);
  const cx = ax + t * dx;
  const cy = ay + t * dy;
  return Math.hypot(px - cx, py - cy);
}

// All coordinates below are in a 24x24 design grid, like the Lucide family.
function toSpace(v) {
  return v / 24;
}

class Glyph {
  constructor(buf) {
    this.buf = buf;
  }

  stroke(width = 2) {
    this.width = toSpace(width);
    return this;
  }

  line(x1, y1, x2, y2, width = 2) {
    const w = toSpace(width) / 2;
    paintCoverage(this.buf, (px, py) => {
      const d = distToSegment(px, py, toSpace(x1), toSpace(y1), toSpace(x2), toSpace(y2));
      return 1 - (d - w) / 0.012;
    });
    return this;
  }

  polyline(points, width = 2, close = false) {
    const path = close ? [...points, points[0]] : points;
    for (let i = 0; i < path.length - 1; i += 1) {
      this.line(path[i][0], path[i][1], path[i + 1][0], path[i + 1][1], width);
    }
    return this;
  }

  ring(cx, cy, r, width = 2) {
    const w = toSpace(width) / 2;
    const rr = toSpace(r);
    const ccx = toSpace(cx);
    const ccy = toSpace(cy);
    paintCoverage(this.buf, (px, py) => {
      const d = Math.abs(Math.hypot(px - ccx, py - ccy) - rr);
      return 1 - (d - w) / 0.012;
    });
    return this;
  }

  disc(cx, cy, r) {
    const rr = toSpace(r);
    const ccx = toSpace(cx);
    const ccy = toSpace(cy);
    paintCoverage(this.buf, (px, py) => {
      const d = Math.hypot(px - ccx, py - ccy) - rr;
      return 1 - d / 0.012;
    });
    return this;
  }

  // Boolean subtraction, which is what turns a filled disc into a crescent and a ring
  // into a palette silhouette with a thumb notch.
  cutDisc(cx, cy, r) {
    const rr = toSpace(r);
    const ccx = toSpace(cx);
    const ccy = toSpace(cy);
    for (let i = 0; i < this.buf.length; i += 1) {
      const x = ((i % SIZE) + 0.5) / SIZE;
      const y = (Math.floor(i / SIZE) + 0.5) / SIZE;
      const d = Math.hypot(x - ccx, y - ccy) - rr;
      const keep = clamp01(1 + d / 0.012);
      this.buf[i] *= keep;
    }
    return this;
  }

  // Radial ticks: used by gear and sun, where the strokes are at angles a frame cannot
  // express but a distance field can.
  ticks(cx, cy, inner, outer, count, width = 2, phase = 0) {
    for (let i = 0; i < count; i += 1) {
      const angle = phase + (i / count) * Math.PI * 2;
      const dx = Math.cos(angle);
      const dy = Math.sin(angle);
      this.line(cx + dx * inner, cy + dy * inner, cx + dx * outer, cy + dy * outer, width);
    }
    return this;
  }

  // Signed distance to a rounded box: shrink the extents by the radius, measure the
  // outside distance from the corner circle, then add back the overlap for inside points.
  boxSdf(px, py, left, top, right, bottom, rr) {
    const cx = (left + right) / 2;
    const cy = (top + bottom) / 2;
    const halfX = (right - left) / 2 - rr;
    const halfY = (bottom - top) / 2 - rr;
    const qx = Math.abs(px - cx) - halfX;
    const qy = Math.abs(py - cy) - halfY;
    const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
    const inside = Math.min(Math.max(qx, qy), 0);
    return outside + inside - rr;
  }

  roundRect(x, y, w, h, r, width = 2) {
    const left = toSpace(x);
    const top = toSpace(y);
    const right = toSpace(x + w);
    const bottom = toSpace(y + h);
    const rr = Math.min(toSpace(r), (right - left) / 2, (bottom - top) / 2);
    const half = toSpace(width) / 2;

    paintCoverage(this.buf, (px, py) => {
      const ring = Math.abs(this.boxSdf(px, py, left, top, right, bottom, rr)) - half;
      return 1 - ring / 0.012;
    });
    return this;
  }

  fillRoundRect(x, y, w, h, r) {
    const left = toSpace(x);
    const top = toSpace(y);
    const right = toSpace(x + w);
    const bottom = toSpace(y + h);
    const rr = Math.min(toSpace(r), (right - left) / 2, (bottom - top) / 2);

    paintCoverage(this.buf, (px, py) => {
      const sd = this.boxSdf(px, py, left, top, right, bottom, rr);
      return 1 - sd / 0.012;
    });
    return this;
  }
}

/* --------------------------------------------------------------- the set */

const ICONS = {
  dot: (g) => g.disc(12, 12, 4),
  ring: (g) => g.ring(12, 12, 8, 2),
  circle: (g) => g.disc(12, 12, 8),
  square: (g) => g.roundRect(5, 5, 14, 14, 2, 2),
  search: (g) => g.ring(10.5, 10.5, 6.5, 2).line(15.5, 15.5, 20, 20, 2),
  close: (g) => g.line(6, 6, 18, 18, 2).line(18, 6, 6, 18, 2),
  check: (g) => g.polyline([[5, 12.5], [10, 17.5], [19, 7]], 2),
  chevronDown: (g) => g.polyline([[7, 10], [12, 15], [17, 10]], 2),
  chevronUp: (g) => g.polyline([[7, 14], [12, 9], [17, 14]], 2),
  chevronRight: (g) => g.polyline([[10, 6], [16, 12], [10, 18]], 2),
  plus: (g) => g.line(12, 5, 12, 19, 2).line(5, 12, 19, 12, 2),
  minus: (g) => g.line(5, 12, 19, 12, 2),
  home: (g) => g.polyline([[4, 11], [12, 4], [20, 11]], 2).polyline([[6, 10], [6, 19], [18, 19], [18, 10]], 2),
  layers: (g) =>
    g
      .polyline([[12, 3], [21, 8], [12, 13], [3, 8], [12, 3]], 2)
      .polyline([[4, 12], [12, 16.5], [20, 12]], 2)
      .polyline([[4, 16], [12, 20.5], [20, 16]], 2),
  crosshair: (g) => g.ring(12, 12, 7.5, 2).line(12, 1.5, 12, 5, 2).line(12, 19, 12, 22.5, 2).line(1.5, 12, 5, 12, 2).line(19, 12, 22.5, 12, 2),
  target: (g) => g.ring(12, 12, 8.5, 2).ring(12, 12, 4.5, 2).disc(12, 12, 1.6),
  bullet: (g) =>
    g
      .polyline([[12, 3], [16.5, 8], [16.5, 15], [12, 21], [7.5, 15], [7.5, 8], [12, 3]], 2)
      .line(12, 8, 12, 14, 2),
  robot: (g) =>
    g
      .roundRect(5, 8, 14, 10, 3, 2)
      .disc(9.5, 13, 1.4)
      .disc(14.5, 13, 1.4)
      .line(12, 4, 12, 8, 2)
      .disc(12, 3.4, 1.3),
  eye: (g) =>
    g
      .polyline([[2.5, 12], [7, 6.5], [17, 6.5], [21.5, 12], [17, 17.5], [7, 17.5], [2.5, 12]], 2)
      .ring(12, 12, 3.2, 2),
  globe: (g) => g.ring(12, 12, 8.5, 2).line(3.5, 12, 20.5, 12, 2).polyline([[12, 3.5], [16.5, 12], [12, 20.5], [7.5, 12], [12, 3.5]], 2),
  chat: (g) =>
    g
      .roundRect(3.5, 5, 17, 11, 3, 2)
      .polyline([[8, 16], [8, 20], [12, 16]], 2),
  palette: (g) =>
    g
      .ring(12, 12.5, 8.5, 2)
      .cutDisc(18.6, 16.4, 3.4)
      .disc(8.6, 9.6, 1.3)
      .disc(14.4, 8.4, 1.3)
      .disc(16.4, 12.6, 1.3)
      .disc(8, 15, 1.3),
  sliders: (g) =>
    g
      .line(4, 8, 20, 8, 2)
      .line(4, 16, 20, 16, 2)
      .ring(9, 8, 2.2, 2)
      .ring(16, 16, 2.2, 2),
  bell: (g) =>
    g
      .polyline([[5.5, 17], [5.5, 11], [9.5, 5.5], [14.5, 5.5], [18.5, 11], [18.5, 17]], 2)
      .line(3.5, 17, 20.5, 17, 2)
      .ring(12, 19.6, 2, 2),
  gear: (g) => g.ring(12, 12, 3.4, 2).ring(12, 12, 6.4, 1.8).ticks(12, 12, 7.4, 9.8, 8, 2.6, Math.PI / 8),
  filter: (g) => g.polyline([[4, 6], [20, 6], [14, 13], [14, 19], [10, 17], [10, 13], [4, 6]], 2),
  power: (g) => g.line(12, 3, 12, 11, 2).polyline([[7.5, 6.2], [4.5, 11], [12, 20.5], [19.5, 11], [16.5, 6.2]], 2),
  hold: (g) => g.ring(12, 12, 8, 2).polyline([[12, 7], [12, 12], [15.5, 14]], 2),
  keyboard: (g) =>
    g
      .roundRect(3, 7, 18, 11, 2.5, 2)
      .line(7, 11, 7, 11.01, 1.8)
      .line(11, 11, 11, 11.01, 1.8)
      .line(15, 11, 15, 11.01, 1.8)
      .line(9, 15, 15, 15, 1.8),
  play: (g) => g.polyline([[8, 5], [19, 12], [8, 19], [8, 5]], 2),
  save: (g) =>
    g
      .roundRect(4, 4, 16, 16, 2.5, 2)
      .polyline([[8, 4], [8, 9], [16, 9], [16, 4]], 2)
      .roundRect(8, 13, 8, 7, 1, 2),
  trash: (g) =>
    g
      .line(4, 7, 20, 7, 2)
      .polyline([[6, 7], [7, 20], [17, 20], [18, 7]], 2)
      .polyline([[9, 7], [9, 4], [15, 4], [15, 7]], 2),
  copy: (g) => g.roundRect(9, 9, 11, 11, 2.5, 2).polyline([[15, 5], [5, 5], [5, 15]], 2),
  refresh: (g) =>
    g
      .polyline([[19, 8], [16, 5], [12, 4.5], [7, 7], [5, 12]], 2)
      .polyline([[5, 16], [8, 19], [12, 19.5], [17, 17], [19, 12]], 2)
      .polyline([[19, 3], [19, 8], [14, 8]], 2),
  download: (g) => g.line(12, 4, 12, 15, 2).polyline([[7, 10], [12, 15], [17, 10]], 2).line(4, 19, 20, 19, 2),
  upload: (g) => g.line(12, 19, 12, 8, 2).polyline([[7, 12], [12, 7], [17, 12]], 2).line(4, 4, 20, 4, 2),
  folder: (g) => g.polyline([[4, 19], [4, 8], [10, 8], [12, 10], [20, 10], [20, 19], [4, 19]], 2),
  info: (g) => g.ring(12, 12, 8.5, 2).line(12, 11, 12, 16.5, 2).line(12, 7.5, 12, 7.6, 2),
  warning: (g) =>
    g
      .polyline([[12, 3.5], [21, 20], [3, 20], [12, 3.5]], 2)
      .line(12, 10, 12, 15, 2)
      .line(12, 17.6, 12, 17.7, 2),
  error: (g) => g.ring(12, 12, 8.5, 2).line(9, 9, 15, 15, 2).line(15, 9, 9, 15, 2),
  success: (g) => g.ring(12, 12, 8.5, 2).polyline([[8, 12.5], [11, 15.5], [16.5, 9]], 2),
  lock: (g) => g.roundRect(5, 11, 14, 9, 2.5, 2).polyline([[8.5, 11], [8.5, 7.5], [12, 5], [15.5, 7.5], [15.5, 11]], 2),
  unlock: (g) => g.roundRect(5, 11, 14, 9, 2.5, 2).polyline([[8.5, 11], [8.5, 7.5], [12, 5], [15.5, 7.5]], 2),
  star: (g) =>
    g.polyline(
      [[12, 3.5], [14.4, 9.2], [20.5, 9.8], [15.9, 13.8], [17.4, 19.8], [12, 16.5], [6.6, 19.8], [8.1, 13.8], [3.5, 9.8], [9.6, 9.2], [12, 3.5]],
      2,
    ),
  user: (g) => g.ring(12, 8.5, 4, 2).polyline([[5, 20], [5, 16.5], [12, 14], [19, 16.5], [19, 20]], 2),
  grid: (g) =>
    g
      .roundRect(4, 4, 7, 7, 1.5, 2)
      .roundRect(13, 4, 7, 7, 1.5, 2)
      .roundRect(4, 13, 7, 7, 1.5, 2)
      .roundRect(13, 13, 7, 7, 1.5, 2),
  list: (g) =>
    g
      .line(8, 7, 20, 7, 2)
      .line(8, 12, 20, 12, 2)
      .line(8, 17, 20, 17, 2)
      .line(4, 7, 4.01, 7, 2)
      .line(4, 12, 4.01, 12, 2)
      .line(4, 17, 4.01, 17, 2),
  sun: (g) => g.ring(12, 12, 4.4, 2).ticks(12, 12, 6.8, 9.4, 8, 2),
  moon: (g) => g.ring(12, 12, 8, 2).cutDisc(17.4, 8.2, 7.1),
  image: (g) =>
    g
      .roundRect(3.5, 5, 17, 14, 2.5, 2)
      .disc(9, 10, 1.6)
      .polyline([[5, 17], [10, 12.5], [14, 16], [16.5, 14], [19.5, 16.5]], 2),
  code: (g) => g.polyline([[9, 7], [4, 12], [9, 17]], 2).polyline([[15, 7], [20, 12], [15, 17]], 2),
  flask: (g) =>
    g
      .line(10, 3, 10, 9, 2)
      .line(14, 3, 14, 9, 2)
      .polyline([[10, 9], [5.5, 18], [7, 20], [17, 20], [18.5, 18], [14, 9]], 2)
      .line(8, 4, 16, 4, 2),
  cursor: (g) => g.polyline([[6, 4], [6, 18], [10, 14.5], [12.5, 20], [15, 19], [12.5, 13.5], [18, 13], [6, 4]], 2),
};

/* ----------------------------------------------------------- PNG encoder */

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([length, typeBuf, data, crc]);
}

/** White RGBA with the glyph coverage as alpha, so ImageColor3 can tint it. */
function encodePng(coverage) {
  const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1));
  let offset = 0;

  for (let y = 0; y < SIZE; y += 1) {
    raw[offset] = 0; // filter: none
    offset += 1;
    for (let x = 0; x < SIZE; x += 1) {
      const alpha = Math.round(clamp01(coverage[y * SIZE + x]) * 255);
      raw[offset] = 255;
      raw[offset + 1] = 255;
      raw[offset + 2] = 255;
      raw[offset + 3] = alpha;
      offset += 4;
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(SIZE, 0);
  ihdr.writeUInt32BE(SIZE, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/* --------------------------------------------------------------- outputs */

const atlas = {};
const pngDir = join(root, "assets", "icons");
mkdirSync(pngDir, { recursive: true });
mkdirSync(dirname(OUT_LUA), { recursive: true });

for (const [name, draw] of Object.entries(ICONS)) {
  const buf = canvas();
  const glyph = new Glyph(buf);
  draw(glyph);
  const png = encodePng(buf);
  atlas[name] = png.toString("base64");
  writeFileSync(join(pngDir, `${name}.png`), png);
}

const entries = Object.keys(atlas)
  .sort()
  .map((name) => `\t["${name}"] = "${atlas[name]}"`)
  .join(",\n");

const lua = `--[[
	Assets/IconAtlas — generated by tools/gen-icons.mjs. Do not hand-edit.

	${Object.keys(atlas).length} glyphs, ${SIZE}x${SIZE} RGBA PNG, white on transparent so
	ImageColor3 tints them. The bytes are carried here on purpose: rbxthumb:// icon URIs
	only resolve in Studio, and a third-party asset id can be deleted under the library.

	IconManager writes these to the client's cache folder and points Image at
	getcustomasset; a client with no file API falls back to Assets/GlyphFallback.
]]

return {
	encoding = "base64-png",
	size = ${SIZE},
	glyphs = {
${entries},
	},
}
`;

writeFileSync(OUT_LUA, lua, "utf8");

const totalKb = (Object.values(atlas).reduce((sum, b64) => sum + b64.length, 0) / 1024).toFixed(1);
console.log(`icons: ${Object.keys(atlas).length} glyphs at ${SIZE}x${SIZE}`);
console.log(`wrote ${OUT_LUA} (${totalKb} KB of base64)`);
console.log(`wrote ${join(pngDir, "<name>.png")} for uploading as asset ids`);
