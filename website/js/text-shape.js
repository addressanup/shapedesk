// Port of Sources/ShapeDesk/TextShape.swift. The text is drawn in a thin
// weight and reduced to the centerlines of its strokes. Icons go on stroke
// ends and sharp corners first, then fill the remaining stroke length evenly.

const FONT_SIZE = 200;
const MAX_STRETCH = 1.6;
const THIN_FONT = `100 ${FONT_SIZE}px system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", "Segoe UI", Arial, sans-serif`;

/**
 * @param {string} text
 * @param {number} n number of icons
 * @param {number} aspect width / height of the area the text will be fit into
 */
export function textPoints(text, n, aspect) {
  return analyzeText(text, n, aspect)?.points ?? [];
}

/** Same as textPoints, but also returns the intermediate steps for figures. */
export function analyzeText(text, n, aspect) {
  // Capitals survive icon resolution; lowercase bowls and tails collapse.
  const word = text.trim().toUpperCase();
  if (!word || n <= 0) return null;
  const glyphs = rasterize(word);
  if (!glyphs) return null;

  let line = centerline(glyphs);
  if (line.length === 0) return null;
  const anchors = endsAndCorners(line, glyphs.width, glyphs.height);

  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const p of line) {
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
  }
  const textAspect = (maxX - minX) / Math.max(maxY - minY, 1);
  const stretch = Math.min(Math.max(textAspect / Math.max(aspect, 0.1), 1), MAX_STRETCH);
  const unstretched = line;
  if (stretch > 1) line = line.map((p) => ({ x: p.x, y: p.y * stretch }));

  let chosen;
  if (anchors.length >= n) {
    // Not even enough icons for every end and corner: spread over those.
    const corners = anchors.map((i) => line[i]);
    chosen = farthestPointSample(corners, [], n).map((i) => corners[i]);
  } else {
    const picked = farthestPointSample(line, anchors, n);
    relax(picked, anchors.length, line);
    chosen = picked.map((i) => line[i]);
  }
  // More icons than stroke pixels: stack the extras.
  for (let i = 0; chosen.length < n; i++) chosen.push(chosen[i]);

  const points = chosen
    .map((p) => ({ x: p.x, y: p.y }))
    // Reading order, so icons fill the word left to right.
    .sort((a, b) => (a.x === b.x ? a.y - b.y : a.x - b.x));

  return { points, glyphs, line: unstretched, anchors, stretch };
}

// MARK: - Strokes

/** The text drawn white on black, as a y-down mask of stroke pixels. */
function rasterize(text) {
  // Extra tracking keeps neighboring letters from reading as one shape once
  // each stroke is only a few icons long.
  const kern = FONT_SIZE * 0.25;
  // Keeps the neighborhood scans below inside the bitmap.
  const pad = 40;

  const probe = document.createElement('canvas').getContext('2d');
  probe.font = THIN_FONT;
  const chars = Array.from(text);
  const advances = chars.map((ch) => probe.measureText(ch).width + kern);
  const metrics = probe.measureText(text);
  const ascent = metrics.fontBoundingBoxAscent || FONT_SIZE * 0.95;
  const descent = metrics.fontBoundingBoxDescent || FONT_SIZE * 0.25;

  const w = Math.ceil(advances.reduce((a, b) => a + b, 0) + 2 * pad);
  const h = Math.ceil(ascent + descent + 2 * pad);
  if (w <= 2 * pad || h <= 2 * pad) return null;

  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, w, h);
  ctx.fillStyle = '#fff';
  ctx.font = THIN_FONT;
  ctx.textBaseline = 'alphabetic';
  let x = pad;
  chars.forEach((ch, i) => {
    ctx.fillText(ch, x, pad + ascent);
    x += advances[i];
  });

  const rgba = ctx.getImageData(0, 0, w, h).data;
  const mask = new Uint8Array(w * h);
  for (let i = 0; i < mask.length; i++) mask[i] = rgba[i * 4] > 128 ? 1 : 0;
  return { width: w, height: h, mask };
}

/**
 * Thins the strokes to one-pixel centerlines (Zhang–Suen), so icons sit
 * mid-stroke instead of zigzagging between its edges.
 */
function centerline({ width: w, height: h, mask }) {
  const on = Uint8Array.from(mask);
  const doomed = new Uint8Array(w * h);
  // Neighbors clockwise from north (P2...P9 in Zhang–Suen's notation).
  const around = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1];

  // Only stroke pixels can change, so scan those instead of the whole bitmap.
  let active = [];
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) if (on[y * w + x]) active.push(y * w + x);
  }

  let changed = true;
  while (changed) {
    changed = false;
    for (let pass = 0; pass < 2; pass++) {
      const removals = [];
      for (const i of active) {
        if (!on[i]) continue;
        let bits = 0;
        for (let k = 0; k < 8; k++) if (on[i + around[k]]) bits |= 1 << k;
        let neighbors = 0;
        for (let k = 0; k < 8; k++) if (bits & (1 << k)) neighbors++;
        if (neighbors < 2 || neighbors > 6) continue;
        let transitions = 0;
        for (let k = 0; k < 8; k++) {
          if (!(bits & (1 << k)) && bits & (1 << ((k + 1) % 8))) transitions++;
        }
        if (transitions !== 1) continue;
        const n = bits & 1, e = bits & 4, s = bits & 16, west = bits & 64;
        const keep = pass === 0
          ? (n && e && s) || (e && s && west)
          : (n && e && west) || (n && s && west);
        if (!keep) removals.push(i);
      }
      for (const i of removals) doomed[i] = 1;
      for (const i of removals) {
        // Removing a pixel together with all of its neighbors would erase a
        // tiny part (the dot of "!") outright.
        if (around.some((o) => on[i + o] && !doomed[i + o])) {
          on[i] = 0;
          changed = true;
        }
      }
      for (const i of removals) doomed[i] = 0;
    }
    active = active.filter((i) => on[i]);
  }

  return active
    .sort((a, b) => a - b)
    .map((i) => ({ x: i % w, y: Math.floor(i / w) }));
}

/**
 * Indices of stroke ends and sharp corners on the centerline.
 *
 * A point qualifies when its nearby centerline is lopsided (the centroid sits
 * well off the point) and a ring around it is crossed by strokes in one
 * direction (an end) or in two directions that bend (a corner). Points near a
 * junction look lopsided too, since the branch pulls the centroid toward it,
 * but their rings are crossed in three or more directions.
 */
function endsAndCorners(line, w, h) {
  const onLine = new Uint8Array(w * h);
  for (const p of line) onLine[p.y * w + p.x] = 1;
  const isLine = (x, y) => x >= 0 && y >= 0 && x < w && y < h && onLine[y * w + x] === 1;

  const r = Math.floor(FONT_SIZE * 0.08);
  const disc = discOffsets(r);

  const ringRadius = FONT_SIZE * 0.12;
  const reach = Math.ceil(ringRadius) + 1;
  const ring = [];
  for (let dy = -reach; dy <= reach; dy++) {
    for (let dx = -reach; dx <= reach; dx++) {
      if (Math.abs(Math.hypot(dx, dy) - ringRadius) <= 1) {
        ring.push({ dx, dy, angle: Math.atan2(dy, dx) });
      }
    }
  }
  ring.sort((a, b) => a.angle - b.angle);
  // Ring hits closer than this (in radians) belong to the same stroke.
  const sameBranch = 2.5 / ringRadius;

  const found = [];
  line.forEach((p, i) => {
    let sx = 0, sy = 0, hits = 0;
    for (const [dx, dy] of disc) {
      if (isLine(p.x + dx, p.y + dy)) { sx += dx; sy += dy; hits++; }
    }
    // Ends score about 0.5, right-angle corners about 0.35.
    const score = Math.hypot(sx, sy) / hits / r;
    if (score < 0.15) return;

    // Directions in which strokes leave the ring, as summed unit vectors.
    const branches = [];
    let firstAngle = null;
    let lastAngle = -Infinity;
    for (const o of ring) {
      if (!isLine(p.x + o.dx, p.y + o.dy)) continue;
      if (o.angle - lastAngle > sameBranch) branches.push({ x: 0, y: 0 });
      const b = branches[branches.length - 1];
      b.x += Math.cos(o.angle);
      b.y += Math.sin(o.angle);
      if (firstAngle === null) firstAngle = o.angle;
      lastAngle = o.angle;
    }
    // A stroke crossing the ring at ±180° is split in two; rejoin it.
    if (branches.length > 1 && firstAngle !== null && firstAngle + 2 * Math.PI - lastAngle <= sameBranch) {
      const tail = branches.pop();
      branches[0].x += tail.x;
      branches[0].y += tail.y;
    }

    let qualifies = branches.length <= 1;
    if (branches.length === 2) {
      const a = Math.atan2(branches[0].y, branches[0].x);
      const b = Math.atan2(branches[1].y, branches[1].x);
      let between = Math.abs(a - b);
      if (between > Math.PI) between = 2 * Math.PI - between;
      qualifies = Math.PI - between > 0.7; // bends by more than ~40°
    }
    if (qualifies) found.push({ index: i, score });
  });

  // Keep the strongest point per neighborhood. The neighborhood spans the
  // whole ring because a sharp point (the top of an A) still reads as a
  // corner some way down each of its strokes.
  const anchors = [];
  const r2 = ringRadius * ringRadius;
  for (const f of found.sort((a, b) => b.score - a.score)) {
    if (anchors.every((a) => squaredDistance(line[a], line[f.index]) > r2)) anchors.push(f.index);
  }
  return anchors;
}

function discOffsets(r) {
  const disc = [];
  for (let dy = -r; dy <= r; dy++) {
    for (let dx = -r; dx <= r; dx++) if (dx * dx + dy * dy <= r * r) disc.push([dx, dy]);
  }
  return disc;
}

// MARK: - Spreading icons

/**
 * Starting from `seeds`, repeatedly adds the candidate farthest from
 * everything picked so far. Returns indices into `candidates`.
 */
function farthestPointSample(candidates, seeds, n) {
  if (candidates.length === 0) return [];
  const chosen = [...seeds];
  if (chosen.length === 0) {
    let start = 0;
    candidates.forEach((c, i) => {
      if (c.x + c.y < candidates[start].x + candidates[start].y) start = i;
    });
    chosen.push(start);
  }
  const nearest = new Float64Array(candidates.length).fill(Infinity);
  const absorb = (c) => {
    for (let i = 0; i < candidates.length; i++) {
      nearest[i] = Math.min(nearest[i], squaredDistance(candidates[i], candidates[c]));
    }
  };
  chosen.forEach(absorb);
  while (chosen.length < n) {
    let best = 0;
    for (let i = 0; i < nearest.length; i++) if (nearest[i] > nearest[best]) best = i;
    if (nearest[best] === 0) break;
    chosen.push(best);
    absorb(best);
  }
  return chosen;
}

/**
 * Lloyd relaxation along the strokes: each free point moves to the middle of
 * the stretch of stroke closest to it, which evens out the uneven gaps
 * farthest-point sampling leaves. The first `fixed` points (ends and corners)
 * stay put.
 */
function relax(chosen, fixed, line, iterations = 10) {
  if (chosen.length <= fixed) return;
  for (let it = 0; it < iterations; it++) {
    const cells = chosen.map(() => []);
    for (let i = 0; i < line.length; i++) {
      let best = 0, bestD = Infinity;
      for (let k = 0; k < chosen.length; k++) {
        const d = squaredDistance(line[i], line[chosen[k]]);
        if (d < bestD) { bestD = d; best = k; }
      }
      cells[best].push(i);
    }
    for (let k = fixed; k < chosen.length; k++) {
      const cell = cells[k];
      if (cell.length === 0) continue;
      let cx = 0, cy = 0;
      for (const i of cell) { cx += line[i].x; cy += line[i].y; }
      const centroid = { x: cx / cell.length, y: cy / cell.length };
      // Snap back onto the stroke.
      let onStroke = cell[0];
      for (const i of cell) {
        if (squaredDistance(line[i], centroid) < squaredDistance(line[onStroke], centroid)) onStroke = i;
      }
      chosen[k] = onStroke;
    }
  }
}

function squaredDistance(a, b) {
  const dx = a.x - b.x, dy = a.y - b.y;
  return dx * dx + dy * dy;
}
