import { Plots } from './plot.js';
import { si, plain } from './format.js';

const $ = id => document.getElementById(id);

const els = {
  source: $('source'), highlight: $('highlight'), gutter: $('gutter'), editor: $('editor'),
  fileName: $('file-name'), formatPill: $('format-pill'), cursor: $('cursor-position'),
  run: $('run-button'), examples: $('examples'), results: $('results'),
  resultsTitle: $('results-title'), resultsStats: $('results-stats'), resultsActions: $('results-actions'),
  resetZoom: $('reset-zoom'), viewTabs: $('view-tabs'), csv: $('csv-button'),
  sidebar: $('sidebar'), scrim: $('scrim'), reference: $('reference'), toast: $('toast')
};

const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const MAX_TABLE_ROWS = 1000;
const ANALYSIS_NAMES = { dcop: 'DC operating point', sweep: 'DC sweep', transient: 'Transient analysis' };
const ANALYSIS_TAGS = { dcop: 'DC OP', sweep: 'Sweep', transient: 'Transient' };
const UNIT_ORDER = ['V', 'A', 'Ω', ''];
const GROUP_NAMES = { V: 'Voltages', A: 'Currents', 'Ω': 'Resistances', '': 'Other' };

const state = {
  examples: [],
  exampleId: null,
  pendingView: null,  // a view an example asks for, applied after its first run
  loadedText: '',     // editor contents when last loaded/saved, to detect edits
  result: null,
  view: 'chart',
  visible: new Map(), // series name -> shown
  xChoice: null,      // null = the analysis' own x (time / swept source), else a series name
  running: false
};

let plots = null;

/* ---------- storage (best effort: may be unavailable) ---------- */

const store = {
  get(key) { try { return localStorage.getItem(`jspice.${key}`); } catch (e) { return null; } },
  set(key, value) { try { localStorage.setItem(`jspice.${key}`, value); } catch (e) { /* ignore */ } }
};

/* ---------- small helpers ---------- */

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function svgIcon(paths) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 20 20');
  svg.setAttribute('aria-hidden', 'true');
  for (const d of paths) {
    const p = document.createElementNS(ns, 'path');
    p.setAttribute('d', d);
    svg.append(p);
  }
  return svg;
}

let toastTimer = 0;
function toast(message) {
  els.toast.textContent = message;
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { els.toast.hidden = true; }, 2600);
}

function detectFormat(text) {
  return /^components:/m.test(text) ? 'yaml' : 'spice';
}

function seriesColor(slot) {
  return slot < 8 ? `var(--series-${slot + 1})` : 'var(--series-other)';
}

function resolveColor(value) {
  const match = /^var\((--[\w-]+)\)$/.exec(value);
  return match ? getComputedStyle(document.documentElement).getPropertyValue(match[1]).trim() : value;
}

/* ---------- editor ---------- */

function escapeHtml(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const NUMBER = /^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?(meg|[fpnumkgt])?(ohm|[vfsah])?$/i;
const SPICE_FUNCTIONS = /^(SIN|PULSE|DC|AC|PWL|EXP)$/i;

function highlightSpice(line) {
  const trimmed = line.trimStart();
  if (trimmed.startsWith('*')) return `<span class="tok-comment">${escapeHtml(line)}</span>`;
  const parts = line.split(/(\s+|[()=,])/);
  let first = true;
  return parts.map(part => {
    if (!part) return '';
    const safe = escapeHtml(part);
    if (/^\s+$/.test(part) || /^[()=,]$/.test(part)) return safe;
    if (first) {
      first = false;
      if (part.startsWith('.')) return `<span class="tok-dir">${safe}</span>`;
      if (part === '+') return safe;
      return `<span class="tok-id">${safe}</span>`;
    }
    if (SPICE_FUNCTIONS.test(part)) return `<span class="tok-fn">${safe}</span>`;
    if (NUMBER.test(part)) return `<span class="tok-num">${safe}</span>`;
    return safe;
  }).join('');
}

function highlightYaml(line) {
  const comment = line.search(/(^|\s)#/);
  let code = comment >= 0 ? line.slice(0, comment) : line;
  const tail = comment >= 0 ? `<span class="tok-comment">${escapeHtml(line.slice(comment))}</span>` : '';
  const key = /^(\s*(?:-\s+)?)([\w.]+)(\s*:)(.*)$/.exec(code);
  if (key) {
    const value = key[4];
    const valueTrimmed = value.trim();
    const valueHtml = NUMBER.test(valueTrimmed)
      ? escapeHtml(value).replace(escapeHtml(valueTrimmed), `<span class="tok-num">${escapeHtml(valueTrimmed)}</span>`)
      : escapeHtml(value);
    code = `${escapeHtml(key[1])}<span class="tok-key">${escapeHtml(key[2])}</span>${escapeHtml(key[3])}${valueHtml}`;
  } else {
    code = escapeHtml(code);
  }
  return code + tail;
}

let lastLineCount = 0;
function renderEditor() {
  const text = els.source.value;
  const format = detectFormat(text);
  const lines = text.split('\n');
  const highlight = format === 'yaml' ? highlightYaml : highlightSpice;
  // trailing newline keeps the last line's height in step with the textarea
  els.highlight.innerHTML = lines.map(highlight).join('\n') + '\n\n';
  if (lines.length !== lastLineCount) {
    lastLineCount = lines.length;
    const fragment = document.createDocumentFragment();
    for (let i = 1; i <= lines.length; i++) fragment.append(el('div', '', String(i)));
    els.gutter.replaceChildren(fragment);
  }
  els.formatPill.textContent = format.toUpperCase();
  syncScroll();
  updateCursor();
}

function syncScroll() {
  els.highlight.scrollTop = els.source.scrollTop;
  els.highlight.scrollLeft = els.source.scrollLeft;
  els.gutter.scrollTop = els.source.scrollTop;
}

let currentLine = 0;
function updateCursor() {
  const before = els.source.value.slice(0, els.source.selectionStart);
  const line = before.split('\n').length;
  const column = before.length - before.lastIndexOf('\n');
  els.cursor.textContent = `Ln ${line}, Col ${column}`;
  if (line !== currentLine) {
    els.gutter.children[currentLine - 1]?.classList.remove('current');
    els.gutter.children[line - 1]?.classList.add('current');
    currentLine = line;
  }
}

function setSource(text, fileName) {
  els.source.value = text;
  els.source.scrollTop = 0;
  els.source.setSelectionRange(0, 0);
  if (fileName) els.fileName.value = fileName;
  state.loadedText = text;
  renderEditor();
  persist();
}

function isDirty() {
  return els.source.value.trim() !== '' && els.source.value !== state.loadedText;
}

function persist() {
  store.set('netlist', els.source.value);
  store.set('fileName', els.fileName.value);
  store.set('example', state.exampleId || '');
}

function insertAtCursor(text) {
  // execCommand keeps the browser's undo history intact
  if (!document.execCommand('insertText', false, text)) {
    const { selectionStart: s, selectionEnd: e, value } = els.source;
    els.source.value = value.slice(0, s) + text + value.slice(e);
    els.source.selectionStart = els.source.selectionEnd = s + text.length;
    renderEditor();
  }
}

els.source.addEventListener('input', () => { renderEditor(); persist(); });
els.source.addEventListener('scroll', syncScroll);
els.source.addEventListener('click', updateCursor);
els.source.addEventListener('keyup', updateCursor);
els.source.addEventListener('keydown', e => {
  if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
    e.preventDefault();
    insertAtCursor('  ');
  }
});
els.fileName.addEventListener('change', persist);

/* ---------- examples ---------- */

async function loadExamples() {
  const response = await fetch('api/examples');
  state.examples = await response.json();
  const byCategory = new Map();
  for (const example of state.examples) {
    if (!byCategory.has(example.category)) byCategory.set(example.category, []);
    byCategory.get(example.category).push(example);
  }
  const fragment = document.createDocumentFragment();
  for (const [category, examples] of byCategory) {
    fragment.append(el('h3', '', category));
    for (const example of examples) {
      const button = el('button', 'example');
      button.dataset.id = example.id;
      const title = el('span', 'example-title');
      title.append(el('span', '', example.title), el('span', 'analysis-tag', ANALYSIS_TAGS[example.analysis] || example.analysis));
      button.append(title, el('span', 'example-summary', example.summary));
      button.addEventListener('click', () => openExample(example));
      fragment.append(button);
    }
  }
  els.examples.replaceChildren(fragment);
  markCurrentExample();
}

function markCurrentExample() {
  for (const button of els.examples.querySelectorAll('.example')) {
    button.setAttribute('aria-current', String(button.dataset.id === state.exampleId));
  }
}

function openExample(example) {
  if (isDirty() && !confirm('Replace the current netlist? Your changes will be lost.')) return;
  state.exampleId = example.id;
  state.pendingView = example.view || null;
  state.visible = new Map();
  state.xChoice = null;
  setSource(example.netlist, example.file);
  markCurrentExample();
  closeSidebar();
  run();
}

const TEMPLATE = `* My circuit
* Lines starting with * are comments. Node 0 is ground.
* Open the Reference panel for the full syntax.

V1 in 0 PULSE(0 5 0 1u 1u 1m 2m)
R1 in out 1k
C1 out 0 100n

.tran 2u 6m
.end
`;

$('new-button').addEventListener('click', () => {
  if (isDirty() && !confirm('Start a new netlist? Your changes will be lost.')) return;
  state.exampleId = null;
  state.pendingView = null;
  state.visible = new Map();
  state.xChoice = null;
  setSource(TEMPLATE, 'untitled.cir');
  markCurrentExample();
  closeSidebar();
  els.source.focus();
  els.source.setSelectionRange(TEMPLATE.indexOf('V1'), TEMPLATE.indexOf('V1'));
});

/* ---------- running ---------- */

async function run() {
  if (state.running) return;
  state.running = true;
  els.run.classList.add('running');
  els.run.disabled = true;
  els.results.classList.add('stale');
  let result;
  try {
    const response = await fetch('api/simulate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ netlist: els.source.value, format: detectFormat(els.source.value) })
    });
    result = await response.json();
  } catch (e) {
    result = { error: 'Could not reach the JSpice server. Is it still running?' };
  } finally {
    state.running = false;
    els.run.classList.remove('running');
    els.run.disabled = false;
    els.results.classList.remove('stale');
  }
  showResult(result);
}

els.run.addEventListener('click', run);

/* ---------- results ---------- */

function groupSeries(series) {
  const groups = new Map();
  for (const s of series) {
    const unit = UNIT_ORDER.includes(s.unit) ? s.unit : '';
    if (!groups.has(unit)) groups.set(unit, []);
    groups.get(unit).push(s);
  }
  return UNIT_ORDER.filter(u => groups.has(u)).map(unit => {
    const list = groups.get(unit);
    // colour follows the series' position in its group, so toggling never repaints the others
    list.forEach((s, i) => { s.color = seriesColor(i); });
    return { unit, series: list };
  });
}

function defaultVisibility(result) {
  const visible = new Map();
  for (const group of groupSeries(result.series)) {
    group.series.forEach((s, i) => visible.set(s.name, i < 3 || s.name === result.observe));
  }
  return visible;
}

function showResult(result) {
  state.result = result;
  plots?.destroy();
  plots = null;
  els.resetZoom.hidden = true;

  if (result.error) {
    els.resultsTitle.textContent = 'Results';
    els.resultsStats.textContent = '';
    els.resultsActions.hidden = true;
    els.results.replaceChildren(errorCard(result.error));
    return;
  }

  const points = result.x ? result.x.length : 0;
  els.resultsTitle.textContent = ANALYSIS_NAMES[result.analysis] || 'Results';
  els.resultsStats.textContent = [
    points ? `${points.toLocaleString()} points` : `${result.values.length} values`,
    `${result.elapsedMs.toLocaleString()} ms`
  ].join(' · ');
  els.resultsActions.hidden = false;
  els.viewTabs.hidden = result.analysis === 'dcop';

  if (result.analysis !== 'dcop') {
    // keep the user's choices across re-runs of the same circuit, default the rest
    const defaults = defaultVisibility(result);
    const names = new Set(result.series.map(s => s.name));
    for (const [name, shown] of defaults) if (!state.visible.has(name)) state.visible.set(name, shown);
    for (const name of [...state.visible.keys()]) if (!names.has(name)) state.visible.delete(name);
    if (state.xChoice && !names.has(state.xChoice)) state.xChoice = null;
    if (state.pendingView) {
      const view = state.pendingView;
      state.pendingView = null;
      if (view.x && names.has(view.x)) state.xChoice = view.x;
      if (view.show) {
        for (const name of state.visible.keys()) state.visible.set(name, view.show.includes(name));
      }
    }
  }
  renderResult();
}

function renderResult() {
  const result = state.result;
  const content = [];
  if (result.warnings?.length) content.push(warningCard(result.warnings));
  if (result.analysis === 'dcop') {
    content.push(dcopView(result));
  } else if (state.view === 'table') {
    content.push(tableView(result));
  } else {
    content.push(chartView(result));
  }
  for (const button of els.viewTabs.querySelectorAll('button')) {
    button.setAttribute('aria-selected', String(button.dataset.view === state.view));
  }
  plots?.destroy();
  plots = null;
  els.results.replaceChildren(...content);
  if (result.analysis !== 'dcop' && state.view === 'chart') drawCharts();
}

function errorCard(message) {
  const card = el('div', 'message error');
  card.setAttribute('role', 'alert');
  card.append(svgIcon(['M10 6v5M10 14h.01', 'M10 2.5 18 17H2z']), el('h3', '', 'The simulation could not run'));
  const body = el('div', 'body');
  body.append(el('div', 'detail', message));
  const hint = el('p');
  if (/Not yet Implemented/i.test(message)) {
    hint.textContent = 'That element is not supported in SPICE netlists. SPICE netlists support R, C, L, V, YMEMRISTOR, .model, .tran and .op. Use the YAML format for diodes, MOSFETs, current sources, controlled sources and DC sweeps.';
  } else if (/did not converge|convergence/i.test(message)) {
    hint.textContent = 'The solver could not find a stable operating point. Check for floating nodes, and that every node has a DC path to ground (node 0).';
  } else {
    hint.textContent = 'Check the netlist against the syntax reference.';
  }
  const open = el('button', 'button small', 'Open the syntax reference');
  open.style.marginTop = '10px';
  open.addEventListener('click', openReference);
  body.append(hint, open);
  card.append(body);
  return card;
}

function warningCard(warnings) {
  const card = el('div', 'message warning');
  card.append(svgIcon(['M10 7v4M10 14h.01', 'M10 2.5 18 17H2z']), el('h3', '', warnings.length === 1 ? '1 warning' : `${warnings.length} warnings`));
  const shown = warnings.slice(0, 3).join('\n') + (warnings.length > 3 ? `\n…and ${warnings.length - 3} more` : '');
  card.append(el('div', 'body', shown));
  return card;
}

function dcopView(result) {
  const container = el('div', 'dcop');
  const groups = new Map();
  for (const v of result.values) {
    const unit = UNIT_ORDER.includes(v.unit) ? v.unit : '';
    if (!groups.has(unit)) groups.set(unit, []);
    groups.get(unit).push(v);
  }
  for (const unit of UNIT_ORDER.filter(u => groups.has(u))) {
    const values = groups.get(unit);
    const max = Math.max(...values.map(v => Math.abs(v.value ?? 0))) || 1;
    const card = el('section', 'card');
    card.append(el('h3', '', GROUP_NAMES[unit]));
    for (const v of values) {
      const row = el('div', 'value-row');
      const bar = el('div', `value-bar${v.value < 0 ? ' negative' : ''}`);
      const fill = el('span');
      fill.style.width = `${Math.abs(v.value ?? 0) / max * 100}%`;
      bar.append(fill);
      row.append(el('span', 'value-name', v.name), bar, el('span', 'value-number', si(v.value, v.unit)));
      card.append(row);
    }
    container.append(card);
  }
  return container;
}

function xAxis(result) {
  if (state.xChoice) {
    const s = result.series.find(item => item.name === state.xChoice);
    return { values: s.values, name: s.name, unit: s.unit };
  }
  return { values: result.x, name: result.xLabel, unit: result.xUnit };
}

function chartView(result) {
  const view = el('div', 'chart-view');
  const controls = el('div', 'chart-controls');

  // x axis picker
  const xControl = el('label');
  xControl.append(el('span', 'control-label', 'X axis'));
  const select = el('select', 'x-select');
  const own = el('option', '', result.xLabel);
  own.value = '';
  select.append(own);
  for (const s of result.series) {
    const option = el('option', '', s.name);
    option.value = s.name;
    select.append(option);
  }
  select.value = state.xChoice || '';
  select.addEventListener('change', () => {
    state.xChoice = select.value || null;
    if (state.xChoice) state.visible.set(state.xChoice, false);
    renderResult();
  });
  xControl.append(select);

  // legend: toggles grouped by unit
  const legend = el('div', 'legend');
  for (const group of groupSeries(result.series)) {
    if (group.series.every(s => s.name === state.xChoice)) continue;
    const row = el('div', 'legend-group');
    row.append(el('span', 'legend-group-label', GROUP_NAMES[group.unit]));
    for (const s of group.series) {
      if (s.name === state.xChoice) continue;
      const chip = el('button', 'chip');
      chip.setAttribute('aria-pressed', String(!!state.visible.get(s.name)));
      const key = el('span', 'key');
      key.style.background = s.color;
      chip.append(key, document.createTextNode(s.name));
      chip.addEventListener('click', () => {
        state.visible.set(s.name, !state.visible.get(s.name));
        chip.setAttribute('aria-pressed', String(state.visible.get(s.name)));
        drawCharts(true);
      });
      row.append(chip);
    }
    legend.append(row);
  }
  controls.append(xControl, legend);
  const panels = el('div', 'panels');
  panels.id = 'panels';
  view.append(controls, panels);
  return view;
}

function drawCharts(keepZoom = false) {
  const result = state.result;
  const container = $('panels');
  if (!container) return;
  const x = xAxis(result);
  const groups = groupSeries(result.series)
    .map(group => ({
      unit: group.unit,
      series: group.series
        .filter(s => state.visible.get(s.name) && s.name !== state.xChoice)
        .map(s => ({ name: s.name, unit: s.unit, values: s.values, color: resolveColor(s.color) }))
    }))
    .filter(group => group.series.length);

  if (!groups.length) {
    plots?.destroy();
    plots = null;
    const empty = el('div', 'empty');
    empty.append(el('h3', '', 'No signals selected'), el('p', '', 'Turn on one or more signals above to plot them.'));
    container.replaceChildren(empty);
    els.resetZoom.hidden = true;
    return;
  }
  if (!plots) plots = new Plots(container, zoomed => { els.resetZoom.hidden = !zoomed; });
  plots.update({ x: x.values, xName: x.name, xUnit: x.unit, xy: !!state.xChoice, groups }, keepZoom);
}

function tableView(result) {
  const wrap = el('div', 'table-wrap');
  const table = el('table', 'data-table');
  const head = el('tr');
  const header = (name, unit) => el('th', '', unit ? `${name} [${unit}]` : name);
  head.append(el('th', '', '#'), header(result.xLabel, result.xUnit), ...result.series.map(s => header(s.name, s.unit)));
  const thead = el('thead');
  thead.append(head);
  const tbody = el('tbody');
  const rows = Math.min(result.x.length, MAX_TABLE_ROWS);
  for (let i = 0; i < rows; i++) {
    const tr = el('tr');
    tr.append(el('td', '', String(i)), el('td', '', plain(result.x[i])), ...result.series.map(s => el('td', '', plain(s.values[i]))));
    tbody.append(tr);
  }
  table.append(thead, tbody);
  wrap.append(table);
  if (result.x.length > rows) {
    wrap.append(el('div', 'table-note', `Showing the first ${rows.toLocaleString()} of ${result.x.length.toLocaleString()} rows. Download the CSV for all of them.`));
  }
  return wrap;
}

els.viewTabs.addEventListener('click', e => {
  const view = e.target.closest('button')?.dataset.view;
  if (!view || view === state.view) return;
  state.view = view;
  renderResult();
});

els.resetZoom.addEventListener('click', () => plots?.resetZoom());

/* ---------- files ---------- */

function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = el('a');
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function baseName() {
  return (els.fileName.value.trim() || 'netlist').replace(/\.[^.]*$/, '');
}

function saveNetlist() {
  let name = els.fileName.value.trim() || 'netlist';
  if (!/\.\w+$/.test(name)) name += detectFormat(els.source.value) === 'yaml' ? '.yml' : '.cir';
  download(name, els.source.value, 'text/plain');
  state.loadedText = els.source.value;
  toast(`Saved ${name}`);
}

function csvCell(text) {
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function exportCsv() {
  const result = state.result;
  if (!result || result.error) return;
  let lines;
  if (result.analysis === 'dcop') {
    lines = ['name,value,unit', ...result.values.map(v => [v.name, plain(v.value), v.unit].map(csvCell).join(','))];
  } else {
    const header = [`${result.xLabel} [${result.xUnit}]`, ...result.series.map(s => `${s.name} [${s.unit}]`)];
    lines = [header.map(csvCell).join(',')];
    for (let i = 0; i < result.x.length; i++) {
      lines.push([plain(result.x[i]), ...result.series.map(s => plain(s.values[i]))].join(','));
    }
  }
  download(`${baseName()}-results.csv`, lines.join('\n') + '\n', 'text/csv');
}

function openFile(file) {
  if (!file) return;
  if (isDirty() && !confirm(`Open ${file.name}? Your changes to the current netlist will be lost.`)) return;
  const reader = new FileReader();
  reader.onload = () => {
    state.exampleId = null;
    state.pendingView = null;
    state.visible = new Map();
    state.xChoice = null;
    setSource(String(reader.result).replace(/\r\n/g, '\n'), file.name);
    markCurrentExample();
    toast(`Opened ${file.name}`);
  };
  reader.readAsText(file);
}

$('save-button').addEventListener('click', saveNetlist);
els.csv.addEventListener('click', exportCsv);
$('open-button').addEventListener('click', () => $('file-input').click());
$('file-input').addEventListener('change', e => { openFile(e.target.files[0]); e.target.value = ''; });

let dragDepth = 0;
els.editor.addEventListener('dragenter', e => { e.preventDefault(); dragDepth++; els.editor.classList.add('dragging'); });
els.editor.addEventListener('dragover', e => e.preventDefault());
els.editor.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; els.editor.classList.remove('dragging'); } });
els.editor.addEventListener('drop', e => {
  e.preventDefault();
  dragDepth = 0;
  els.editor.classList.remove('dragging');
  openFile(e.dataTransfer.files[0]);
});

/* ---------- layout: theme, panes, drawers ---------- */

function effectiveTheme() {
  return document.documentElement.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
}

function updateThemeButton() {
  const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
  $('theme-button').setAttribute('aria-label', `Switch to ${next} theme`);
  $('theme-button').title = `Switch to ${next} theme`;
}

$('theme-button').addEventListener('click', () => {
  const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  store.set('theme', next);
  updateThemeButton();
  if (state.result && !state.result.error) renderResult();
});

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  updateThemeButton();
  if (state.result && !state.result.error && !document.documentElement.dataset.theme) renderResult();
});

// editor / results splitter
const workspace = $('workspace');
const resizer = $('resizer');
function setEditorWidth(px) {
  const bounds = workspace.getBoundingClientRect();
  const clamped = Math.max(280, Math.min(px, bounds.width - 252 - 340));
  workspace.style.setProperty('--editor-width', `${clamped}px`);
  return clamped;
}
const savedWidth = Number(store.get('editorWidth'));
if (savedWidth) setEditorWidth(savedWidth);
resizer.addEventListener('pointerdown', e => {
  resizer.setPointerCapture(e.pointerId);
  resizer.classList.add('dragging');
  const startX = e.clientX;
  const startWidth = document.querySelector('.editor-pane').getBoundingClientRect().width;
  const move = ev => setEditorWidth(startWidth + ev.clientX - startX);
  const up = () => {
    resizer.classList.remove('dragging');
    resizer.removeEventListener('pointermove', move);
    resizer.removeEventListener('pointerup', up);
    store.set('editorWidth', document.querySelector('.editor-pane').getBoundingClientRect().width);
  };
  resizer.addEventListener('pointermove', move);
  resizer.addEventListener('pointerup', up);
});
resizer.addEventListener('keydown', e => {
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  const width = document.querySelector('.editor-pane').getBoundingClientRect().width;
  store.set('editorWidth', setEditorWidth(width + (e.key === 'ArrowRight' ? 24 : -24)));
});

// examples drawer on narrow screens
function closeSidebar() {
  els.sidebar.classList.remove('open');
  els.scrim.hidden = true;
  $('sidebar-toggle').setAttribute('aria-expanded', 'false');
}
$('sidebar-toggle').addEventListener('click', () => {
  const open = !els.sidebar.classList.contains('open');
  els.sidebar.classList.toggle('open', open);
  els.scrim.hidden = !open;
  $('sidebar-toggle').setAttribute('aria-expanded', String(open));
});
els.scrim.addEventListener('click', closeSidebar);

// syntax reference
function openReference() {
  els.reference.hidden = false;
  $('help-button').setAttribute('aria-expanded', 'true');
  $('reference-close').focus();
}
function closeReference() {
  els.reference.hidden = true;
  $('help-button').setAttribute('aria-expanded', 'false');
}
$('help-button').addEventListener('click', () => (els.reference.hidden ? openReference() : closeReference()));
$('reference-close').addEventListener('click', closeReference);

/* ---------- keyboard shortcuts ---------- */

document.addEventListener('keydown', e => {
  const mod = isMac ? e.metaKey : e.ctrlKey;
  if (mod && e.key === 'Enter') { e.preventDefault(); run(); }
  else if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); saveNetlist(); }
  else if (mod && e.key.toLowerCase() === 'o') { e.preventDefault(); $('file-input').click(); }
  else if (e.key === 'Escape') { closeReference(); closeSidebar(); }
});

if (isMac) {
  $('run-shortcut').textContent = '⌘ ↵';
  for (const k of document.querySelectorAll('kbd.mod')) k.textContent = '⌘';
  els.run.title = 'Run the simulation (⌘Enter)';
}

/* ---------- start ---------- */

async function start() {
  updateThemeButton();
  const savedNetlist = store.get('netlist');
  try {
    await loadExamples();
  } catch (e) {
    toast('Could not load the examples.');
  }
  if (savedNetlist && savedNetlist.trim()) {
    state.exampleId = store.get('example') || null;
    setSource(savedNetlist, store.get('fileName') || 'untitled.cir');
    state.loadedText = state.examples.find(x => x.id === state.exampleId)?.netlist ?? savedNetlist;
    markCurrentExample();
    run();
  } else {
    // first visit: show something right away
    const first = state.examples.find(x => x.id === 'rc-step-response') || state.examples[0];
    if (first) openExample(first); else setSource(TEMPLATE, 'untitled.cir');
  }
}

start();
