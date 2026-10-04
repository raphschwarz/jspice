// Number formatting for engineering values: SI prefixes, axis scaling and tick generation.

const PREFIXES = { '-15': 'f', '-12': 'p', '-9': 'n', '-6': 'µ', '-3': 'm', '0': '', '3': 'k', '6': 'M', '9': 'G', '12': 'T' };

/** The power-of-1000 exponent that makes `value` read naturally, e.g. 0.0047 -> -3 (milli) */
export function siExponent(value) {
  const abs = Math.abs(value);
  if (!isFinite(abs) || abs === 0) return 0;
  const exponent = Math.floor(Math.log10(abs) / 3) * 3;
  return Math.max(-15, Math.min(12, exponent));
}

export function prefixFor(exponent) {
  return PREFIXES[String(exponent)] ?? '';
}

/** 0.0047, "A" -> "4.7 mA" */
export function si(value, unit = '', digits = 4) {
  if (value === null || value === undefined || !isFinite(value)) return '—';
  if (value === 0) return `0 ${unit}`.trim();
  const exponent = siExponent(value);
  const scaled = value / Math.pow(10, exponent);
  const text = String(parseFloat(scaled.toPrecision(digits))).replace('-', '−');
  return `${text} ${prefixFor(exponent)}${unit}`.trim();
}

/** Plain number for tables and CSV: up to 6 significant digits, no prefix */
export function plain(value) {
  if (value === null || value === undefined || !isFinite(value)) return '';
  if (value === 0) return '0';
  const abs = Math.abs(value);
  if (abs >= 1e-3 && abs < 1e6) return String(parseFloat(value.toPrecision(6)));
  return value.toExponential(5).replace(/\.?0+e/, 'e');
}

/** Roughly `count` evenly spaced ticks at 1/2/5 x 10^n covering [min, max], and at least three where the range allows */
export function niceTicks(min, max, count = 5) {
  let ticks = ticksFor(min, max, count);
  for (let c = count + 1; ticks.length < 3 && c <= count + 6; c++) ticks = ticksFor(min, max, c);
  return ticks;
}

function ticksFor(min, max, count) {
  if (!(max > min)) return [min];
  const rough = (max - min) / count;
  const magnitude = Math.pow(10, Math.floor(Math.log10(rough)));
  const residual = rough / magnitude;
  const step = (residual > 5 ? 10 : residual > 2 ? 5 : residual > 1 ? 2 : 1) * magnitude;
  const ticks = [];
  for (let t = Math.ceil(min / step) * step; t <= max + step * 1e-9; t += step) {
    ticks.push(Math.abs(t) < step * 1e-9 ? 0 : t);
  }
  return ticks;
}

/** Tick label with just enough decimals for the step between ticks */
export function tickLabel(value, step) {
  const decimals = Math.max(0, Math.min(10, -Math.floor(Math.log10(step) + 1e-9)));
  return value.toFixed(decimals).replace('-', '−');
}

export const UNIT_NAMES = { V: 'Voltage', A: 'Current', 'Ω': 'Resistance', s: 'Time', '': 'Value' };

/** "Voltage (mV)" for an axis whose largest magnitude is `maxAbs` */
export function axisTitle(unit, exponent, name) {
  const label = name ?? UNIT_NAMES[unit] ?? 'Value';
  const suffix = `${prefixFor(exponent)}${unit}`;
  return suffix ? `${label} (${suffix})` : label;
}
