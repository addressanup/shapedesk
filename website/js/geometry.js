// Port of Sources/ShapeDesk/Geometry.swift. Points use screen coordinates
// (y down), the same as Finder's desktop positions.

export const SHAPES = [
  { id: 'heart', title: 'Heart' },
  { id: 'circle', title: 'Circle' },
  { id: 'star', title: 'Star' },
  { id: 'spiral', title: 'Spiral' },
  { id: 'wave', title: 'Wave' },
];

export function densePolyline(kind, samples = 3000) {
  const pts = [];
  switch (kind) {
    case 'circle':
      for (let i = 0; i < samples; i++) {
        const t = (2 * Math.PI * i) / samples;
        pts.push({ x: Math.cos(t), y: Math.sin(t) });
      }
      return { points: pts, closed: true };

    case 'heart':
      // Classic parametric heart, y flipped for screen coordinates.
      for (let i = 0; i < samples; i++) {
        const t = (2 * Math.PI * i) / samples;
        const x = 16 * Math.sin(t) ** 3;
        const y = 13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t);
        pts.push({ x: x / 17, y: -y / 17 });
      }
      return { points: pts, closed: true };

    case 'star':
      for (let i = 0; i < 10; i++) {
        const r = i % 2 === 0 ? 1 : 0.45;
        const a = -Math.PI / 2 + (i * Math.PI) / 5;
        pts.push({ x: r * Math.cos(a), y: r * Math.sin(a) });
      }
      return { points: pts, closed: true };

    case 'spiral': {
      const turns = 2.2;
      for (let i = 0; i < samples; i++) {
        const f = i / (samples - 1);
        const theta = turns * 2 * Math.PI * f;
        const r = 0.04 + 0.96 * f;
        pts.push({ x: r * Math.cos(theta), y: r * Math.sin(theta) });
      }
      return { points: pts, closed: false };
    }

    case 'wave':
      for (let i = 0; i < samples; i++) {
        const f = i / (samples - 1);
        const x = f * 2 - 1;
        pts.push({ x, y: 0.35 * Math.sin(3 * Math.PI * x) });
      }
      return { points: pts, closed: false };

    default:
      throw new Error(`Unknown shape: ${kind}`);
  }
}

/** Places `n` points at even arc-length intervals along the polyline. */
export function resample(polyline, closed, n) {
  if (n <= 0 || polyline.length === 0) return [];
  if (n === 1) return [polyline[Math.floor(polyline.length / 2)]];

  const pts = closed ? [...polyline, polyline[0]] : polyline;
  const cum = [0];
  for (let i = 1; i < pts.length; i++) {
    cum.push(cum[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
  }
  const total = cum[cum.length - 1];
  if (!(total > 0)) return Array.from({ length: n }, () => ({ ...pts[0] }));

  const step = closed ? total / n : total / (n - 1);
  const out = [];
  let seg = 1;
  for (let k = 0; k < n; k++) {
    const target = Math.min(step * k, total);
    while (seg < cum.length - 1 && cum[seg] < target) seg++;
    const d0 = cum[seg - 1];
    const d1 = cum[seg];
    const f = d1 > d0 ? (target - d0) / (d1 - d0) : 0;
    out.push({
      x: pts[seg - 1].x + f * (pts[seg].x - pts[seg - 1].x),
      y: pts[seg - 1].y + f * (pts[seg].y - pts[seg - 1].y),
    });
  }
  return out;
}

/** Scales and centers points into `rect`, preserving aspect ratio. */
export function fit(points, rect, fill) {
  if (points.length === 0) return [];
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const p of points) {
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
  }
  const bw = Math.max(maxX - minX, 0.0001);
  const bh = Math.max(maxY - minY, 0.0001);
  const scale = Math.min((rect.width * fill) / bw, (rect.height * fill) / bh);
  const cx = rect.x + rect.width / 2 - ((minX + maxX) / 2) * scale;
  const cy = rect.y + rect.height / 2 - ((minY + maxY) / 2) * scale;
  return points.map((p) => ({ x: p.x * scale + cx, y: p.y * scale + cy }));
}

export function shapePoints(kind, n, rect, fill) {
  const { points, closed } = densePolyline(kind);
  return fit(resample(points, closed, n), rect, fill);
}

/** Median nearest-neighbor distance; used to warn when icons will overlap. */
export function medianSpacing(points) {
  if (points.length < 2) return Infinity;
  const nearest = points.map((p, i) => {
    let best = Infinity;
    for (let j = 0; j < points.length; j++) {
      if (j !== i) best = Math.min(best, Math.hypot(p.x - points[j].x, p.y - points[j].y));
    }
    return best;
  });
  nearest.sort((a, b) => a - b);
  return nearest[Math.floor(nearest.length / 2)];
}

/** Finder-style sorted grid: right-aligned columns, filled top to bottom. */
export function gridPoints(names, rect, spacing, inset) {
  const order = names
    .map((name, index) => ({ name, index }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }));
  const rows = Math.max(1, Math.floor((rect.height - inset.y * 2) / spacing) + 1);
  const out = new Array(names.length);
  order.forEach(({ index }, k) => {
    const col = Math.floor(k / rows);
    const row = k % rows;
    out[index] = {
      x: rect.x + rect.width - inset.x - col * spacing,
      y: rect.y + inset.y + row * spacing,
    };
  });
  return out;
}
