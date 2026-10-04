import { initDesktop } from './desktop.js';
import { densePolyline, fit, resample } from './geometry.js';
import { analyzeText } from './text-shape.js';

const SVG_NS = 'http://www.w3.org/2000/svg';

function startClock() {
  const clock = document.getElementById('clock');
  const narrow = matchMedia('(max-width: 560px)');
  const render = () => {
    const now = new Date();
    const options = narrow.matches
      ? { hour: 'numeric', minute: '2-digit' }
      : { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' };
    clock.textContent = new Intl.DateTimeFormat(undefined, options).format(now).replace(/,/g, '');
    clock.dateTime = now.toISOString();
  };
  render();
  setInterval(render, 15000);
  narrow.addEventListener('change', render);
}

/** 40 evenly spaced points on the heart, exactly as the app samples them. */
function drawHeartFigure() {
  const svg = document.getElementById('figure-heart');
  if (!svg) return;
  const rect = { x: 40, y: 24, width: 240, height: 192 };
  const dense = densePolyline('heart');
  const curve = fit(dense.points, rect, 1);
  const points = resample(curve, dense.closed, 40);

  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', `M${curve.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join('L')}Z`);
  path.setAttribute('fill', 'none');
  path.setAttribute('stroke', 'rgba(244,238,248,0.18)');
  path.setAttribute('stroke-width', '1');
  path.setAttribute('stroke-dasharray', '3 4');
  svg.append(path);

  for (const p of points) {
    const dot = document.createElementNS(SVG_NS, 'circle');
    dot.setAttribute('cx', p.x.toFixed(1));
    dot.setAttribute('cy', p.y.toFixed(1));
    dot.setAttribute('r', '4.5');
    dot.setAttribute('fill', '#4ba8f0');
    svg.append(dot);
  }
}

/** The letters H and I: stroke, centerline, ends first, then the rest. */
function drawWordFigure() {
  const canvas = document.getElementById('figure-word');
  if (!canvas) return;
  const result = analyzeText('HI', 16, 10);
  if (!result) return;
  const { glyphs, line, anchors, points } = result;

  const art = document.createElement('canvas');
  art.width = glyphs.width;
  art.height = glyphs.height;
  const artCtx = art.getContext('2d');
  const image = artCtx.createImageData(glyphs.width, glyphs.height);
  for (let i = 0; i < glyphs.mask.length; i++) {
    if (!glyphs.mask[i]) continue;
    image.data.set([244, 238, 248, 34], i * 4);
  }
  for (const p of line) image.data.set([244, 238, 248, 150], (p.y * glyphs.width + p.x) * 4);
  artCtx.putImageData(image, 0, 0);

  const ctx = canvas.getContext('2d');
  const pad = 40;
  // Crop the bitmap's own padding so the letters fill the figure.
  const minX = Math.min(...line.map((p) => p.x)) - 20;
  const maxX = Math.max(...line.map((p) => p.x)) + 20;
  const minY = Math.min(...line.map((p) => p.y)) - 20;
  const maxY = Math.max(...line.map((p) => p.y)) + 20;
  const scale = Math.min((canvas.width - 2 * pad) / (maxX - minX), (canvas.height - 2 * pad) / (maxY - minY));
  const ox = (canvas.width - (maxX - minX) * scale) / 2 - minX * scale;
  const oy = (canvas.height - (maxY - minY) * scale) / 2 - minY * scale;

  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(art, ox, oy, glyphs.width * scale, glyphs.height * scale);

  const isAnchor = new Set(anchors.map((i) => `${line[i].x},${line[i].y}`));
  for (const p of points) {
    const anchor = isAnchor.has(`${p.x},${p.y}`);
    ctx.beginPath();
    ctx.arc(ox + p.x * scale, oy + p.y * scale, anchor ? 11 : 9, 0, Math.PI * 2);
    ctx.fillStyle = anchor ? '#f08a4b' : '#4ba8f0';
    ctx.fill();
  }
}

function wireCopyButtons() {
  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = 'Copied';
      } catch {
        button.textContent = 'Press ⌘C';
        const code = button.previousElementSibling;
        const range = document.createRange();
        range.selectNodeContents(code);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
      }
      setTimeout(() => { button.textContent = 'Copy'; }, 1800);
    });
  });
}

startClock();
initDesktop();
drawHeartFigure();
drawWordFigure();
wireCopyButtons();
