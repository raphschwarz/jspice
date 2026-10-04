// Canvas line charts: one panel per unit, a shared x axis, a synced crosshair with a tooltip,
// drag-to-zoom and an X-Y mode (any signal on the x axis, e.g. for I-V curves).

import { si, siExponent, niceTicks, tickLabel, axisTitle } from './format.js';

const MARGIN = { top: 8, right: 14, bottom: 24 };

function css(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

/** Index of the value in the ascending array `xs` closest to `x` */
function nearestIndex(xs, x) {
  let lo = 0;
  let hi = xs.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (xs[mid] < x) lo = mid; else hi = mid;
  }
  return Math.abs(xs[lo] - x) <= Math.abs(xs[hi] - x) ? lo : hi;
}

function lowerBound(xs, x) {
  let lo = 0;
  let hi = xs.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (xs[mid] < x) lo = mid + 1; else hi = mid;
  }
  return lo;
}

function extent(values, from = 0, to = values.length) {
  let min = Infinity;
  let max = -Infinity;
  for (let i = from; i < to; i++) {
    const v = values[i];
    if (v === null || v === undefined) continue;
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return [min, max];
}

function padded([min, max]) {
  if (!isFinite(min)) return [-1, 1];
  if (max - min <= Math.max(Math.abs(max), Math.abs(min)) * 1e-9) {
    const pad = Math.abs(max) * 0.1 || 1;
    return [min - pad, max + pad];
  }
  const pad = (max - min) * 0.06;
  return [min - pad, max + pad];
}

export class Plots {
  /**
   * @param root element the panels are rendered into
   * @param onZoomChange called with true/false when the zoom state changes
   */
  constructor(root, onZoomChange) {
    this.root = root;
    this.onZoomChange = onZoomChange;
    this.panels = [];
    this.domain = null;
    this.hover = null;
    this.drag = null;
    this.frame = 0;
    this.resizeObserver = new ResizeObserver(() => this.schedule());
  }

  /**
   * model: {
   *   x: number[], xName, xUnit, xy: boolean,
   *   groups: [{ unit, series: [{ name, unit, values, color }] }]
   * }
   */
  update(model, keepZoom = false) {
    this.model = model;
    if (!keepZoom) this.setDomain(null);
    this.hover = null;
    this.build();
  }

  destroy() {
    this.resizeObserver.disconnect();
    cancelAnimationFrame(this.frame);
  }

  resetZoom() {
    this.setDomain(null);
    this.schedule();
  }

  setDomain(domain) {
    const wasZoomed = this.domain !== null;
    this.domain = domain;
    if (wasZoomed !== (domain !== null)) this.onZoomChange?.(domain !== null);
  }

  build() {
    this.resizeObserver.disconnect();
    this.root.replaceChildren();
    this.panels = [];
    const { groups, xy } = this.model;

    for (const group of groups) {
      const el = document.createElement('div');
      el.className = 'panel';
      const title = document.createElement('div');
      title.className = 'panel-title';
      const titleText = document.createElement('span');
      const hint = document.createElement('span');
      hint.className = 'chart-hint';
      title.append(titleText, hint);
      const holder = document.createElement('div');
      holder.className = 'panel-canvas';
      const base = document.createElement('canvas');
      const overlay = document.createElement('canvas');
      overlay.className = 'overlay';
      overlay.tabIndex = 0;
      overlay.setAttribute('role', 'img');
      overlay.setAttribute('aria-label', `${group.series.map(s => s.name).join(', ')} plotted against ${this.model.xName}. Use the arrow keys to read values.`);
      const tooltip = document.createElement('div');
      tooltip.className = 'tooltip';
      tooltip.hidden = true;
      holder.append(base, overlay, tooltip);
      el.append(title, holder);
      this.root.append(el);

      const panel = { el, group, titleText, hint, holder, base, overlay, tooltip };
      this.panels.push(panel);
      this.bindEvents(panel);
      this.resizeObserver.observe(holder);
    }
    if (this.panels.length) {
      this.panels[0].hint.textContent = xy ? '' : 'Drag to zoom';
      const axis = document.createElement('div');
      axis.className = 'x-axis-title';
      this.xAxisTitle = axis;
      this.root.append(axis);
    }
    this.schedule();
  }

  schedule() {
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => this.draw());
  }

  /** The data x range currently shown */
  currentDomain() {
    if (this.domain) return this.domain;
    const [min, max] = extent(this.model.x);
    return this.model.xy ? padded([min, max]) : (isFinite(min) ? [min, max] : [0, 1]);
  }

  /** Index range [from, to) of points inside the domain, for monotonic (non X-Y) data */
  indexRange() {
    const xs = this.model.x;
    if (this.model.xy || !this.domain) return [0, xs.length];
    const from = Math.max(0, lowerBound(xs, this.domain[0]) - 1);
    const to = Math.min(xs.length, lowerBound(xs, this.domain[1]) + 1);
    return [from, to];
  }

  draw() {
    if (!this.model) return;
    const domain = this.currentDomain();
    const xExponent = siExponent(Math.max(Math.abs(domain[0]), Math.abs(domain[1])));
    const font = getComputedStyle(document.body).fontFamily;
    const colors = {
      grid: css('--grid'), axis: css('--axis'), muted: css('--text-muted'),
      text: css('--text-secondary'), surface: css('--surface-raised'),
      accent: css('--accent'), accentSoft: css('--accent-soft')
    };
    const [from, to] = this.indexRange();

    for (const panel of this.panels) {
      const rect = panel.holder.getBoundingClientRect();
      const width = Math.max(1, Math.floor(rect.width));
      const height = Math.max(1, Math.floor(rect.height));
      const dpr = window.devicePixelRatio || 1;
      for (const canvas of [panel.base, panel.overlay]) {
        if (canvas.width !== width * dpr || canvas.height !== height * dpr) {
          canvas.width = width * dpr;
          canvas.height = height * dpr;
        }
      }

      // y range over what is visible
      let yMin = Infinity;
      let yMax = -Infinity;
      for (const s of panel.group.series) {
        let [min, max] = [Infinity, -Infinity];
        if (this.model.xy && this.domain) {
          for (let i = 0; i < s.values.length; i++) {
            const x = this.model.x[i];
            const v = s.values[i];
            if (x === null || v === null || x < domain[0] || x > domain[1]) continue;
            if (v < min) min = v;
            if (v > max) max = v;
          }
        } else {
          [min, max] = extent(s.values, from, to);
        }
        yMin = Math.min(yMin, min);
        yMax = Math.max(yMax, max);
      }
      const yDomain = padded([yMin, yMax]);
      const yExponent = siExponent(Math.max(Math.abs(yDomain[0]), Math.abs(yDomain[1])));
      const yFactor = Math.pow(10, -yExponent);
      const yTicks = niceTicks(yDomain[0] * yFactor, yDomain[1] * yFactor, Math.max(2, Math.round(height / 55)));
      const yStep = yTicks.length > 1 ? yTicks[1] - yTicks[0] : 1;

      const ctx = panel.base.getContext('2d');
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, width, height);
      ctx.font = `11.5px ${font}`;
      const yLabels = yTicks.map(t => tickLabel(t, yStep));
      const left = Math.ceil(Math.max(...yLabels.map(l => ctx.measureText(l).width))) + 16;
      const plot = { left, top: MARGIN.top, right: width - MARGIN.right, bottom: height - MARGIN.bottom };
      plot.width = Math.max(1, plot.right - plot.left);
      plot.height = Math.max(1, plot.bottom - plot.top);
      const sx = x => plot.left + (x - domain[0]) / (domain[1] - domain[0]) * plot.width;
      const sy = y => plot.bottom - (y - yDomain[0]) / (yDomain[1] - yDomain[0]) * plot.height;
      panel.geometry = { plot, sx, sy, domain, yDomain, dpr, width, height };

      // grid and y labels
      ctx.lineWidth = 1;
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = colors.muted;
      yTicks.forEach((t, i) => {
        const y = Math.round(sy(t / yFactor)) + 0.5;
        if (y < plot.top - 1 || y > plot.bottom + 1) return;
        ctx.strokeStyle = t === 0 ? colors.axis : colors.grid;
        ctx.beginPath();
        ctx.moveTo(plot.left, y);
        ctx.lineTo(plot.right, y);
        ctx.stroke();
        ctx.fillText(yLabels[i], plot.left - 8, y);
      });

      // x axis
      const xFactor = Math.pow(10, -xExponent);
      const xTicks = niceTicks(domain[0] * xFactor, domain[1] * xFactor, Math.max(2, Math.round(plot.width / 80)));
      const xStep = xTicks.length > 1 ? xTicks[1] - xTicks[0] : 1;
      ctx.strokeStyle = colors.axis;
      ctx.beginPath();
      ctx.moveTo(plot.left, plot.bottom + 0.5);
      ctx.lineTo(plot.right, plot.bottom + 0.5);
      ctx.stroke();
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      for (const t of xTicks) {
        const x = Math.round(sx(t / xFactor)) + 0.5;
        if (x < plot.left - 1 || x > plot.right + 1) continue;
        ctx.beginPath();
        ctx.moveTo(x, plot.bottom);
        ctx.lineTo(x, plot.bottom + 4);
        ctx.stroke();
        ctx.fillText(tickLabel(t, xStep), x, plot.bottom + 7);
      }

      // series
      ctx.save();
      ctx.beginPath();
      ctx.rect(plot.left, plot.top - 2, plot.width, plot.height + 4);
      ctx.clip();
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      for (const s of panel.group.series) {
        ctx.strokeStyle = s.color;
        ctx.beginPath();
        if (this.model.xy) {
          this.tracePath(ctx, this.model.x, s.values, 0, s.values.length, sx, sy);
        } else if (to - from > plot.width * 3) {
          this.traceDecimated(ctx, this.model.x, s.values, from, to, sx, sy);
        } else {
          this.tracePath(ctx, this.model.x, s.values, from, to, sx, sy);
        }
        ctx.stroke();
      }
      ctx.restore();

      panel.titleText.textContent = axisTitle(panel.group.unit, yExponent);
    }
    if (this.xAxisTitle) {
      this.xAxisTitle.textContent = axisTitle(this.model.xUnit, xExponent, this.model.xName);
    }
    this.drawOverlays();
  }

  tracePath(ctx, xs, ys, from, to, sx, sy) {
    let pen = false;
    for (let i = from; i < to; i++) {
      const x = xs[i];
      const y = ys[i];
      if (x === null || y === null) { pen = false; continue; }
      if (pen) ctx.lineTo(sx(x), sy(y)); else ctx.moveTo(sx(x), sy(y));
      pen = true;
    }
  }

  /** Min/max per pixel column, for series with many more points than pixels */
  traceDecimated(ctx, xs, ys, from, to, sx, sy) {
    let column = null;
    let min = 0;
    let max = 0;
    let pen = false;
    const flush = () => {
      if (column === null) return;
      if (pen) ctx.lineTo(column, sy(min)); else ctx.moveTo(column, sy(min));
      ctx.lineTo(column, sy(max));
      pen = true;
    };
    for (let i = from; i < to; i++) {
      const y = ys[i];
      if (y === null) { flush(); column = null; pen = false; continue; }
      const c = Math.round(sx(xs[i]));
      if (c !== column) {
        flush();
        column = c;
        min = max = y;
      } else {
        if (y < min) min = y;
        if (y > max) max = y;
      }
    }
    flush();
  }

  drawOverlays() {
    const surface = css('--surface-raised');
    const crosshair = css('--text-muted');
    for (const panel of this.panels) {
      const g = panel.geometry;
      if (!g) continue;
      const ctx = panel.overlay.getContext('2d');
      ctx.setTransform(g.dpr, 0, 0, g.dpr, 0, 0);
      ctx.clearRect(0, 0, g.width, g.height);

      if (this.drag && this.drag.panel === panel && Math.abs(this.drag.current - this.drag.start) > 2) {
        const a = Math.max(g.plot.left, Math.min(this.drag.start, this.drag.current));
        const b = Math.min(g.plot.right, Math.max(this.drag.start, this.drag.current));
        ctx.fillStyle = css('--accent-soft');
        ctx.fillRect(a, g.plot.top, b - a, g.plot.height);
        ctx.strokeStyle = css('--accent');
        ctx.lineWidth = 1;
        ctx.strokeRect(Math.round(a) + 0.5, g.plot.top + 0.5, Math.round(b - a), g.plot.height - 1);
      }

      if (!this.hover) {
        panel.tooltip.hidden = true;
        continue;
      }
      const marker = (x, y, color) => {
        ctx.beginPath();
        ctx.arc(x, y, 4, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = surface;
        ctx.stroke();
      };

      if (this.model.xy) {
        if (this.hover.panel !== panel) { panel.tooltip.hidden = true; continue; }
        const { series, index } = this.hover;
        const px = g.sx(this.model.x[index]);
        const py = g.sy(series.values[index]);
        marker(px, py, series.color);
        this.showTooltip(panel, px, [[series, series.values[index]]], `${this.model.xName} = ${si(this.model.x[index], this.model.xUnit)}`);
        continue;
      }

      const index = this.hover.index;
      const xValue = this.model.x[index];
      const px = Math.round(g.sx(xValue)) + 0.5;
      if (px < g.plot.left || px > g.plot.right) { panel.tooltip.hidden = true; continue; }
      ctx.strokeStyle = crosshair;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(px, g.plot.top);
      ctx.lineTo(px, g.plot.bottom);
      ctx.stroke();
      const rows = [];
      for (const s of panel.group.series) {
        const v = s.values[index];
        if (v === null) continue;
        marker(px, g.sy(v), s.color);
        rows.push([s, v]);
      }
      if (this.hover.panel === panel) {
        this.showTooltip(panel, px, rows, `${this.model.xName} = ${si(xValue, this.model.xUnit)}`);
      } else {
        panel.tooltip.hidden = true;
      }
    }
  }

  showTooltip(panel, px, rows, heading) {
    const tip = panel.tooltip;
    const header = document.createElement('div');
    header.className = 'tip-x';
    header.textContent = heading;
    const lines = rows.map(([s, v]) => {
      const row = document.createElement('div');
      row.className = 'tip-row';
      const key = document.createElement('span');
      key.className = 'key';
      key.style.background = s.color;
      const value = document.createElement('strong');
      value.textContent = si(v, s.unit);
      const name = document.createElement('span');
      name.textContent = s.name;
      row.append(key, value, name);
      return row;
    });
    tip.replaceChildren(header, ...lines);
    tip.hidden = false;
    const g = panel.geometry;
    const tipWidth = tip.offsetWidth;
    let left = px + 14;
    if (left + tipWidth > g.width - 4) left = px - 14 - tipWidth;
    tip.style.left = `${Math.max(4, left)}px`;
    tip.style.top = `${g.plot.top + 4}px`;
  }

  bindEvents(panel) {
    const canvas = panel.overlay;
    const local = e => {
      const r = canvas.getBoundingClientRect();
      return [e.clientX - r.left, e.clientY - r.top];
    };
    const toData = px => {
      const g = panel.geometry;
      return g.domain[0] + (px - g.plot.left) / g.plot.width * (g.domain[1] - g.domain[0]);
    };

    canvas.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      const [px] = local(e);
      this.drag = { panel, start: px, current: px };
      canvas.setPointerCapture(e.pointerId);
    });

    canvas.addEventListener('pointermove', e => {
      const [px, py] = local(e);
      if (this.drag && this.drag.panel === panel) {
        this.drag.current = px;
      }
      this.updateHover(panel, px, py, toData(px));
      this.drawOverlays();
    });

    canvas.addEventListener('pointerup', () => {
      const drag = this.drag;
      this.drag = null;
      if (drag && Math.abs(drag.current - drag.start) > 6) {
        const a = toData(Math.min(drag.start, drag.current));
        const b = toData(Math.max(drag.start, drag.current));
        if (b > a) {
          this.setDomain([a, b]);
          this.schedule();
          return;
        }
      }
      this.drawOverlays();
    });

    canvas.addEventListener('pointerleave', () => {
      if (this.drag) return;
      this.hover = null;
      this.drawOverlays();
    });

    canvas.addEventListener('dblclick', () => this.resetZoom());

    canvas.addEventListener('keydown', e => {
      const xs = this.model.x;
      if (this.model.xy || !xs.length) return;
      const [from, to] = this.indexRange();
      let index = this.hover ? this.hover.index : from;
      const step = e.shiftKey ? Math.max(1, Math.round((to - from) / 20)) : 1;
      if (e.key === 'ArrowRight') index = Math.min(to - 1, index + step);
      else if (e.key === 'ArrowLeft') index = Math.max(from, index - step);
      else if (e.key === 'Home') index = from;
      else if (e.key === 'End') index = to - 1;
      else if (e.key === 'Escape') { this.hover = null; this.drawOverlays(); return; }
      else return;
      e.preventDefault();
      this.hover = { panel, index };
      this.drawOverlays();
    });

    canvas.addEventListener('blur', () => {
      if (this.hover && this.hover.panel === panel) {
        this.hover = null;
        this.drawOverlays();
      }
    });
  }

  updateHover(panel, px, py, xValue) {
    const g = panel.geometry;
    if (!g || px < g.plot.left - 4 || px > g.plot.right + 4) {
      this.hover = null;
      return;
    }
    if (!this.model.xy) {
      if (!this.model.x.length) return;
      this.hover = { panel, index: nearestIndex(this.model.x, xValue) };
      return;
    }
    // X-Y: the nearest point on screen, within 40px
    let best = null;
    let bestDistance = 40 * 40;
    for (const s of panel.group.series) {
      for (let i = 0; i < s.values.length; i++) {
        const x = this.model.x[i];
        const y = s.values[i];
        if (x === null || y === null) continue;
        const dx = g.sx(x) - px;
        const dy = g.sy(y) - py;
        const d = dx * dx + dy * dy;
        if (d < bestDistance) {
          bestDistance = d;
          best = { panel, series: s, index: i };
        }
      }
    }
    this.hover = best;
  }
}
