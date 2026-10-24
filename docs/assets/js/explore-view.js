import { buildArchitecture, edgePoints } from './architecture-model.mjs';
import { sampleArchitecture, createPlayback } from './architecture-activity.mjs';

const NS = 'http://www.w3.org/2000/svg';
const svgElement = (tag, attrs = {}, text) => {
  const el = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value);
  if (text != null) el.textContent = text;
  return el;
};
const htmlElement = (tag, text, className) => {
  const el = document.createElement(tag);
  if (text != null) el.textContent = text;
  if (className) el.className = className;
  return el;
};
// Embedded in the drawing so downloaded SVGs retain their typography and colors.
const drawingStyle = `
  .architecture-svg { font-family: 'Segoe UI', Arial, sans-serif; background: var(--a-bg); }
  .a-background { fill: var(--a-bg); }
  .a-group rect { fill: var(--a-color); fill-opacity: .055; stroke: var(--a-color); stroke-opacity: .3; stroke-dasharray: 4 4; }
  .a-group-title { fill: var(--a-color); font-size: 13px; font-weight: 700; letter-spacing: 1px; }
  .a-group-note { fill: var(--a-muted); font-size: 11px; }
  .a-kicker { fill: var(--a-muted); font-size: 11px; letter-spacing: 1px; }
  .a-node { cursor: pointer; outline: none; }
  .a-node .a-body { fill: var(--a-bg); stroke: var(--a-color); stroke-width: 1.5; }
  .a-node .a-accent { fill: var(--a-color); stroke: none; }
  .a-node-title { fill: var(--a-ink); font-size: 15px; font-weight: 600; }
  .a-node-note { fill: var(--a-muted); font-size: 11.5px; }
  .a-view-link { fill: var(--a-color); font-size: 12px; font-weight: 600; text-decoration: underline; }
  .a-node[data-domain='optional'] .a-body { stroke-dasharray: 5 4; }
  .a-node:hover .a-body, .a-node:focus-visible .a-body, .a-node[aria-pressed='true'] .a-body { stroke-width: 3; }
  .a-node[aria-pressed='true'] .a-body { fill: var(--a-selected); }
  .a-edge { fill: none; stroke-width: 1.7; stroke-linejoin: round; opacity: .7; }
  .a-edge[data-kind='flow'], .a-edge[data-kind='memory'] { stroke-width: 3; }
  .a-edge[data-kind='result'] { stroke-width: 2.4; }
  .a-edge[data-kind='translation'] { stroke-dasharray: 6 3; }
  .a-edge[data-kind='control'] { stroke-dasharray: 3 4; }
  .architecture-svg.has-selection .a-edge { opacity: .12; }
  .architecture-svg.has-selection .a-edge.is-connected { opacity: 1; stroke-width: 2.5; }
  .a-edge[hidden] { display: none; }
  .a-node .a-load { fill: var(--a-color); stroke: none; opacity: .14; }
  .a-node .a-occupancy { fill: var(--a-color); stroke: none; opacity: .7; }
  .a-activity-label { fill: var(--a-ink); font-size: 10px; }
  .a-activity-dot { stroke: var(--a-bg); stroke-width: 1; }

`;
const light = { bg: '#fffefa', ink: '#1c2733', muted: '#546373', selected: '#fff0d3', frontend: '#256694', backend: '#6956a2', execute: '#425b92', fp: '#965887', memory: '#22776e', platform: '#637080', optional: '#637080', flow: '#52627a', operand: '#6956a2', result: '#8b619d', translation: '#217b78', control: '#a06835' };
const dark = { bg: '#1b202a', ink: '#e8edf3', muted: '#a9b5c6', selected: '#3b3540', frontend: '#7db6df', backend: '#b4a1eb', execute: '#91a9e0', fp: '#dca4cc', memory: '#79c5b8', platform: '#aab6c8', optional: '#aab6c8', flow: '#acbcd1', operand: '#b4a1eb', result: '#d1a3e1', translation: '#79c5b8', control: '#e6b485' };

export function createExplorer(root, data) {
  const model = buildArchitecture(data);
  const host = root.closest('.architecture-explorer');
  const side = host.querySelector('.arch-side');
  const frames = data.trace?.frames || [];
  const hasTrace = frames.length > 0 && frames.every((frame) => frame.queues && frame.executing);
  const instructions = data.payload?.instructions || [];
  const play = host.querySelector('[data-cycle-play]');
  const slider = host.querySelector('#cycle-slider');
  const readout = host.querySelector('#cycle-readout');
  const blocks = new Map();
  let samples = new Map();
  let livePanel = null;
  let cycleStamp;
  const playback = createPlayback({
    length: hasTrace ? frames.length : 0,
    period: (data.model?.cycle_seconds || 0.18) * 1000,
    onChange: paintActivity,
  });
  const picker = host.querySelector('#arch-picker');
  const inspect = host.querySelector('#uarch-inspect');
  const control = host.querySelector('#arch-control');
  const zoom = host.querySelector('#arch-zoom');
  let view = model.core;
  let svg;
  let selected = '';

  function applyPalette() {
    const preference = document.documentElement.dataset.theme || 'auto';
    const isDark = preference === 'dark' || (preference === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    for (const [name, color] of Object.entries(isDark ? dark : light)) svg.style.setProperty(`--a-${name}`, color);
  }
  function showDetails(node) {
    livePanel = null;
    inspect.replaceChildren();
    inspect.append(htmlElement('p', node ? 'Selected block' : 'Reading the architecture', 'eyebrow'));
    inspect.append(htmlElement('h2', node?.title || view.title));
    inspect.append(htmlElement('p', node?.summary || view.description));
    if (!node) {
      inspect.append(htmlElement('p', 'Both views show the whole system. Open the overview block to switch detail views; select other blocks for implementation and configuration. Highlighted arrows show direct connections only.', 'muted'));
      return;
    }
    if (node.targetView) {
      const open = htmlElement('button', `Open ${model[node.targetView].title} →`);
      open.type = 'button';
      open.addEventListener('click', () => navigate(node.targetView));
      inspect.append(open);
    }
    if (node.facts.length) {
      const facts = htmlElement('dl', null, 'arch-facts');
      node.facts.forEach(([name, value]) => {
        const row = htmlElement('div');
        row.append(htmlElement('dt', name), htmlElement('dd', value));
        facts.append(row);
      });
      inspect.append(facts);
    }
    livePanel = htmlElement('section', null, 'arch-live');
    livePanel.setAttribute('aria-live', 'off');
    inspect.append(livePanel);
    paintInspector();
    inspect.append(htmlElement('h3', 'RTL sources'));
    const links = htmlElement('ul', null, 'arch-sources');
    for (const source of node.sources) {
      const item = htmlElement('li');
      const link = htmlElement('a', source.id);
      link.href = `https://github.com/Kingfish404/raptor-chip/blob/master/${source.file}`;
      link.title = source.file;
      item.append(link);
      links.append(item);
    }
    inspect.append(links);
    const clear = htmlElement('button', 'Clear selection');
    clear.type = 'button';
    clear.addEventListener('click', () => {
      const previous = svg.querySelector('.a-node[aria-pressed="true"]');
      select('');
      if (window.matchMedia('(max-width: 1100px)').matches) previous?.focus({ preventScroll: true });
      else picker.focus();
    });
    inspect.append(clear);
  }
  function select(id) {
    selected = id;
    side.classList.toggle('has-selection', Boolean(id));
    svg.classList.toggle('has-selection', Boolean(id));
    svg.querySelectorAll('.a-node').forEach((el) => el.setAttribute('aria-pressed', String(el.dataset.id === id)));
    svg.querySelectorAll('.a-edge').forEach((el) => el.classList.toggle('is-connected', el.dataset.from === id || el.dataset.to === id));
    picker.value = id;
    showDetails(view.nodes.find((n) => n.id === id));
  }
  function navigate(id) {
    draw(id);
    host.querySelector(`[data-arch-view="${id}"]`).focus({ preventScroll: true });
    host.querySelector('.arch-toolbar').scrollIntoView({ block: 'nearest' });
  }
  function activate(id) {
    const node = view.nodes.find((n) => n.id === id);
    if (node?.targetView) navigate(node.targetView);
    else select(selected === id ? '' : id);
  }
  function paintInspector() {
    if (!livePanel) return;
    livePanel.replaceChildren(htmlElement('h3', `Model cycle ${playback.state().cycle}`));
    const sample = samples.get(selected);
    if (!sample) {
      livePanel.append(htmlElement('p', hasTrace ? 'Activity is not modeled for this block.' : 'No occupancy trace is available.', 'arch-live-empty'));
      return;
    }
    livePanel.append(htmlElement('p', sample.detail));
    if (!sample.ids.length) {
      livePanel.append(htmlElement('p', 'No instructions in this block this cycle.', 'arch-live-empty'));
      return;
    }
    const list = htmlElement('ol');
    for (const idx of sample.ids.slice(0, 8)) {
      const item = htmlElement('li', `#${idx} ${instructions[idx]?.asm || 'instruction'}`);
      list.append(item);
    }
    livePanel.append(list);
    if (sample.ids.length > 8) livePanel.append(htmlElement('p', `+ ${sample.ids.length - 8} more instructions`, 'muted'));
  }
  function paintActivity() {
    if (!svg) return;
    const { cycle, playing } = playback.state();
    const frame = hasTrace ? frames[cycle] : null;
    samples = sampleArchitecture(view, data, frame);
    for (const [id, record] of blocks) {
      const sample = samples.get(id);
      if (!sample) continue;
      const { node, group, fill, bar, label, dots } = record;
      group.dataset.count = String(sample.count);
      group.dataset.instructions = sample.ids.join(',');
      // A queue has a proportional fill; an execution/request block has an
      // activity strip only, never a fabricated physical-slot denominator.
      const ratio = sample.capacity ? Math.min(1, sample.count / sample.capacity) : Number(sample.count > 0);
      bar.setAttribute('width', (node.w - 4) * ratio);
      const fillHeight = (node.h - 4) * ratio;
      fill.setAttribute('height', fillHeight);
      fill.setAttribute('y', node.y + node.h - 2 - fillHeight);
      label.textContent = sample.label;
      dots.replaceChildren(...sample.ids.slice(0, 5).map((idx, i) => {
        const domain = instructions[idx]?.domain;
        const color = { integer: 'execute', branch: 'control', mul: 'backend', fp: 'fp', memory: 'memory', mmio: 'control', system: 'backend' }[domain] || node.domain;
        const dot = svgElement('circle', { class: 'a-activity-dot', cx: node.x + 14 + i * 10, cy: node.y + node.h - 12, r: 3.5, fill: `var(--a-${color})` });
        dot.append(svgElement('title', {}, `#${idx} ${instructions[idx]?.asm || ''}`));
        return dot;
      }));
    }
    play.textContent = playing ? 'Pause' : 'Play';
    play.setAttribute('aria-pressed', String(playing));
    slider.max = Math.max(frames.length - 1, 0);
    slider.value = cycle;
    readout.textContent = hasTrace ? `Cycle ${cycle} / ${frames.length - 1} · retired ${frame.retired_total}` : 'Model unavailable';
    cycleStamp.textContent = hasTrace ? `MODEL CYCLE ${cycle} · RETIRED ${frame.retired_total}` : 'NO ACTIVITY TRACE';
    host.querySelectorAll('[data-cycle-step]').forEach((button) => {
      button.disabled = !hasTrace || (Number(button.dataset.cycleStep) < 0 ? cycle === 0 : cycle === frames.length - 1);
    });
    paintInspector();
  }
  function toggleControl() {
    svg.querySelectorAll('.a-edge[data-kind="control"]').forEach((el) => el.toggleAttribute('hidden', !control.checked));
  }
  function setZoom() {
    svg.style.width = ['auto', 'fit'].includes(zoom.value) ? '100%' : `${view.width * Number(zoom.value) / 100}px`;
    svg.style.minWidth = zoom.value === 'auto' ? `${view.id === 'core' ? 1024 : 820}px` : '0';
  }
  function draw(id) {
    view = model[id];
    blocks.clear();
    samples = sampleArchitecture(view, data, hasTrace ? frames[playback.state().cycle] : null);
    svg = svgElement('svg', { class: 'architecture-svg', viewBox: `0 0 ${view.width} ${view.height}`, width: view.width, height: view.height, role: 'group', 'aria-labelledby': 'architecture-title architecture-desc' });
    svg.append(svgElement('title', { id: 'architecture-title' }, `Raptor — ${view.title}`));
    svg.append(svgElement('desc', { id: 'architecture-desc' }, `${view.description} Default preset. Functional connections, not cycle timing or a physical floorplan. Dots and bars show an illustrative queue model, not an RTL trace.`));
    svg.append(svgElement('style', {}, drawingStyle));
    svg.append(svgElement('rect', { class: 'a-background', width: view.width, height: view.height }));
    svg.append(svgElement('text', { x: 32, y: 28, class: 'a-kicker' }, `RAPTOR / ${view.title.toUpperCase()} / DEFAULT PRESET`));
    cycleStamp = svgElement('text', { x: view.width - 32, y: 28, 'text-anchor': 'end', class: 'a-kicker' });
    svg.append(cycleStamp);
    const defs = svgElement('defs');
    for (const kind of ['flow', 'operand', 'result', 'memory', 'translation', 'control']) {
      const marker = svgElement('marker', { id: `a-arrow-${kind}`, viewBox: '0 0 8 8', refX: 7, refY: 4, markerWidth: 5, markerHeight: 5, orient: 'auto-start-reverse' });
      marker.append(svgElement('path', { d: 'M0 0 L8 4 L0 8 Z', fill: `var(--a-${kind})` }));
      defs.append(marker);
    }
    svg.append(defs);
    for (const group of view.groups) {
      const g = svgElement('g', { class: 'a-group', style: `--a-color:var(--a-${group.domain})` });
      g.append(svgElement('rect', { x: group.x, y: group.y, width: group.w, height: group.h, rx: 3 }));
      g.append(svgElement('text', { x: group.x + 16, y: group.y + 23, class: 'a-group-title' }, group.title));
      g.append(svgElement('text', { x: group.x + 16, y: group.y + 41, class: 'a-group-note' }, group.subtitle));
      svg.append(g);
    }
    for (const edge of view.edges) {
      const points = edgePoints(view, edge);
      const path = svgElement('path', { class: 'a-edge', d: points.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' '), stroke: `var(--a-${edge.kind})`, 'marker-end': `url(#a-arrow-${edge.kind})`, 'data-kind': edge.kind, 'data-from': edge.from, 'data-to': edge.to });
      path.append(svgElement('title', {}, edge.label || `${edge.from} → ${edge.to}`));
      svg.append(path);
    }
    for (const node of view.nodes) {
      const modeled = samples.has(node.id);
      const g = svgElement('g', { class: 'a-node', 'data-id': node.id, 'data-domain': node.domain, style: `--a-color:var(--a-${node.domain})`, tabindex: 0, role: 'button', 'aria-pressed': 'false', 'aria-label': `${node.title}. ${node.subtitle}. ${node.targetView ? `Open ${model[node.targetView].title} view.` : 'Inspect block.'}` });
      g.append(svgElement('title', {}, `${node.title}: ${node.subtitle}`));
      g.append(svgElement('rect', { x: node.x, y: node.y, width: node.w, height: node.h, rx: 2, class: 'a-body' }));
      g.append(svgElement('rect', { x: node.x + 1, y: node.y + 12, width: 3, height: node.h - 24, rx: 1, class: 'a-accent' }));
      g.append(svgElement('text', { x: node.x + node.w / 2, y: modeled ? node.y + 19 : node.y + node.h / 2 - 4, 'text-anchor': 'middle', class: 'a-node-title' }, node.title));
      g.append(svgElement('text', { x: node.x + node.w / 2, y: modeled ? node.y + 35 : node.y + node.h / 2 + 16, 'text-anchor': 'middle', class: 'a-node-note' }, node.subtitle));
      if (node.targetView) {
        g.dataset.targetView = node.targetView;
        // Keep the action above the activity strip, also when no trace exists.
        g.querySelector('.a-node-title').setAttribute('y', node.y + 23);
        g.querySelector('.a-node-note').setAttribute('y', node.y + 43);
        g.append(svgElement('text', { x: node.x + node.w / 2, y: node.y + 66, 'text-anchor': 'middle', class: 'a-view-link' }, `Open ${model[node.targetView].title} →`));
      }
      if (modeled) {
        const fill = svgElement('rect', { class: 'a-load', x: node.x + 2, y: node.y + node.h - 2, width: node.w - 4, height: 0 });
        g.insertBefore(fill, g.querySelector('.a-accent'));
        const bar = svgElement('rect', { class: 'a-occupancy', x: node.x + 2, y: node.y + node.h - 4, height: 2, width: 0 });
        const label = svgElement('text', { class: 'a-activity-label', x: node.x + node.w - 10, y: node.y + node.h - 9, 'text-anchor': 'end' });
        const dots = svgElement('g');
        g.append(bar, dots, label);
        blocks.set(node.id, { node, group: g, fill, bar, label, dots });
      }
      g.addEventListener('click', () => activate(node.id));
      g.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activate(node.id); }
      });
      svg.append(g);
    }
    root.replaceChildren(svg);
    root.scrollLeft = 0;
    picker.replaceChildren(new Option('Overview', ''));
    view.nodes.forEach((n) => picker.add(new Option(n.targetView ? `Open ${n.title} →` : n.title, n.id)));
    host.querySelectorAll('[data-arch-view]').forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.archView === id)));
    control.disabled = !view.edges.some((e) => e.kind === 'control');
    if (control.disabled) control.checked = false;
    applyPalette(); setZoom(); toggleControl(); select(''); paintActivity();
  }
  host.querySelector('#arch-config').textContent = `Default preset · RV32 / RV64 · ${model.widths} · ${data.config.values.rob_entries} ROB entries`;
  host.querySelectorAll('[data-arch-view], #arch-picker, #arch-control, #arch-zoom, #arch-export').forEach((el) => { el.disabled = false; });
  host.querySelectorAll('[data-arch-view]').forEach((el) => el.addEventListener('click', () => draw(el.dataset.archView)));
  host.querySelectorAll('[data-cycle-play], [data-cycle-reset], #cycle-slider').forEach((el) => { el.disabled = !hasTrace; });
  play.addEventListener('click', () => playback.toggleFlow());
  host.querySelector('[data-cycle-reset]').addEventListener('click', () => playback.reset());
  host.querySelectorAll('[data-cycle-step]').forEach((el) => el.addEventListener('click', () => playback.step(Number(el.dataset.cycleStep))));
  slider.addEventListener('input', () => playback.setCycle(slider.value));
  document.addEventListener('visibilitychange', () => playback.setSuspended(document.hidden));
  window.addEventListener('pagehide', () => playback.setSuspended(true));
  window.addEventListener('pageshow', () => playback.setSuspended(document.hidden));
  playback.setSuspended(document.hidden);
  const modelNotes = host.querySelector('#arch-model-notes');
  for (const note of data.trace?.notes || []) modelNotes.append(htmlElement('li', note));
  const payload = host.querySelector('#arch-payload');
  instructions.forEach((instruction, idx) => payload.append(htmlElement('li', `#${idx} ${instruction.asm}`)));
  picker.addEventListener('change', () => activate(picker.value));
  control.addEventListener('change', toggleControl);
  zoom.addEventListener('change', setZoom);
  window.addEventListener('raptor-theme', applyPalette);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && selected && !document.getElementById('term')?.classList.contains('is-open')) {
      const previous = svg.querySelector('.a-node[aria-pressed="true"]');
      select('');
      previous?.focus({ preventScroll: true });
    }
  });
  host.querySelector('#arch-export').addEventListener('click', () => {
    const copy = svg.cloneNode(true);
    copy.style.width = `${view.width}px`;
    copy.style.minWidth = '0';
    copy.classList.remove('has-selection');
    copy.querySelectorAll('[aria-pressed]').forEach((el) => { el.setAttribute('aria-pressed', 'false'); el.removeAttribute('tabindex'); });
    copy.querySelectorAll('.is-connected').forEach((el) => el.classList.remove('is-connected'));
    const blob = new Blob([new XMLSerializer().serializeToString(copy)], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const link = htmlElement('a');
    link.href = url; link.download = `raptor-${view.id}-cycle-${playback.state().cycle}.svg`;
    document.body.append(link); link.click(); link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  draw('core');
  return {
    focus(id) {
      for (const candidate of [view, model.core, model.memory]) {
        const node = candidate.nodes.find((n) => n.id === id || (!n.targetView && n.sources.some((s) => s.id === id)));
        if (!node) continue;
        if (candidate !== view) draw(candidate.id);
        select(node.id);
        return true;
      }
      return false;
    },
    toggleFlow: playback.toggleFlow,
    setPlaying: playback.setPlaying,
    setCycle: playback.setCycle,
    step: playback.step,
    reset: playback.reset,
  };
}
