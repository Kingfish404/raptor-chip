import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { buildArchitecture, edgePoints } from '../assets/js/architecture-model.mjs';
const data = JSON.parse(
  readFileSync(new URL('../assets/generated/portal-data.json', import.meta.url)),
);
const model = buildArchitecture(data);
const hasEdge = (view, from, to) => view.edges.some((e) => e.from === from && e.to === to);

test('default capacity labels follow extracted configuration', () => {
  assert.match(model.widths, /^2 decode · 2 rename · 2 dispatch · 2 commit$/);
  assert.match(model.core.nodes.find((n) => n.id === 'dispatch').subtitle, /ROB 32/);
  assert.equal(model.memory.nodes.find((n) => n.id === 'dtlb').subtitle, '64 entries · 2-way');
  assert.equal(model.memory.nodes.find((n) => n.id === 'l2').subtitle, 'Default: passthrough');
  const alternate = structuredClone(data);
  alternate.config.values.dtlb_entries = 128;
  alternate.config.values.l2_enabled = true;
  const changed = buildArchitecture(alternate);
  assert.match(changed.memory.nodes.find((n) => n.id === 'dtlb').subtitle, /^128 entries/);
  assert.equal(changed.memory.nodes.find((n) => n.id === 'l2').subtitle, 'Enabled in this preset');
  delete alternate.config.values.rob_entries;
  assert.throws(() => buildArchitecture(alternate), /Missing architecture parameter/);
});

test('diagram preserves integrated execution and memory topology', () => {
  for (const [queue, unit] of [
    ['alq', 'alu'],
    ['brq', 'branch'],
    ['mdq', 'muldiv'],
    ['fpq', 'fp'],
    ['ioq', 'lsu'],
  ]) {
    assert.ok(hasEdge(model.core, 'dispatch', queue));
    assert.ok(hasEdge(model.core, queue, unit));
    assert.ok(hasEdge(model.core, unit, 'completion'));
  }
  assert.ok(hasEdge(model.core, 'completion', 'commit'));
  const chain = ['bus', 'axi', 'l2', 'core-port', 'router'];
  chain.slice(1).forEach((id, i) => assert.ok(hasEdge(model.memory, chain[i], id)));
  for (const id of ['clint', 'plic', 'external']) assert.ok(hasEdge(model.memory, 'router', id));
  assert.ok(
    !model.memory.edges.some(
      (e) => (e.from === 'debug' || e.to === 'debug') && e.kind !== 'control',
    ),
  );
  assert.ok(!model.core.nodes.some((n) => n.sources.some((s) => s.id === 'rapt_vpu')));
});

test('both views cover the system with reciprocal overview navigation and boundary paths', () => {
  for (const [view, id, target] of [
    [model.core, 'memory-system', 'memory'],
    [model.memory, 'core-system', 'core'],
  ]) {
    const summary = view.nodes.find((n) => n.id === id);
    assert.equal(summary.targetView, target);
    assert.ok(model[target].nodes.some((n) => n.targetView === view.id));
    for (const source of summary.sources) {
      assert.ok(
        model[target].nodes.some((n) => !n.targetView && n.sources.some((s) => s.id === source.id)),
        `missing detailed source ${source.id}`,
      );
    }
  }
  for (const id of ['icache', 'dcache']) assert.ok(hasEdge(model.core, id, 'memory-system'));
  assert.ok(hasEdge(model.core, 'memory-system', 'csr'));
  for (const id of ['l1i', 'l1d']) assert.ok(hasEdge(model.memory, 'core-system', id));
  for (const id of ['clint', 'plic', 'debug']) assert.ok(hasEdge(model.memory, id, 'core-system'));
});

for (const view of [model.core, model.memory]) {
  test(`${view.id}: blocks have real RTL sources and do not overlap`, () => {
    assert.equal(new Set(view.nodes.map((n) => n.id)).size, view.nodes.length);
    for (const n of view.nodes) {
      assert.ok(n.sources.length > 0, n.id);
      for (const source of n.sources)
        assert.ok(existsSync(new URL(`../../${source.file}`, import.meta.url)), source.file);
      assert.ok(
        view.groups.some(
          (g) => n.x >= g.x && n.y >= g.y + 44 && n.x + n.w <= g.x + g.w && n.y + n.h <= g.y + g.h,
        ),
        `${n.id} outside group`,
      );
      for (const other of view.nodes) {
        if (n === other) continue;
        assert.ok(
          n.x + n.w <= other.x ||
            other.x + other.w <= n.x ||
            n.y + n.h <= other.y ||
            other.y + other.h <= n.y,
          `${n.id} overlaps ${other.id}`,
        );
      }
    }
  });
  test(`${view.id}: edges are orthogonal and do not cross blocks`, () => {
    for (const e of view.edges) {
      const points = edgePoints(view, e);
      points.slice(1).forEach(([x2, y2], i) => {
        const [x1, y1] = points[i];
        assert.ok(x1 === x2 || y1 === y2, `${e.from}->${e.to}: diagonal`);
        assert.ok(x2 >= 0 && y2 >= 0 && x2 <= view.width && y2 <= view.height, 'edge outside view');
        for (const n of view.nodes) {
          const crosses =
            x1 === x2
              ? x1 > n.x && x1 < n.x + n.w && Math.max(y1, y2) > n.y && Math.min(y1, y2) < n.y + n.h
              : y1 > n.y &&
                y1 < n.y + n.h &&
                Math.max(x1, x2) > n.x &&
                Math.min(x1, x2) < n.x + n.w;
          assert.ok(!crosses, `${e.from}->${e.to}: crosses ${n.id}`);
        }
      });
    }
  });
}

// Exercise the actual generated trace, rather than infer activity from source
// membership: one RTL module may own both a waiting queue and an execution unit.
const { sampleArchitecture, createPlayback } = await import(
  '../assets/js/architecture-activity.mjs'
);
test('activity distinguishes waiting queues, execution and unmodeled state', () => {
  for (const frame of data.trace.frames) {
    const core = sampleArchitecture(model.core, data, frame);
    const memory = sampleArchitecture(model.memory, data, frame);
    for (const [queue, unit] of [
      ['alq', 'alu'],
      ['brq', 'branch'],
      ['mdq', 'muldiv'],
      ['fpq', 'fp'],
      ['ioq', 'lsu'],
    ]) {
      assert.deepEqual(core.get(queue).ids, frame.queues[queue]);
      assert.deepEqual(core.get(unit).ids, frame.executing[queue]);
      assert.ok(core.get(queue).count <= core.get(queue).capacity);
    }
    assert.deepEqual(core.get('dcache').ids, memory.get('l1d').ids);
    assert.deepEqual(core.get('icache').ids, memory.get('l1i').ids);
    assert.deepEqual(core.get('commit').ids, frame.occ.rapt_cmu || []);
    assert.deepEqual(core.get('memory-system').ids, memory.get('external').ids);
    const pipelineIds = [
      ...new Set([
        ...Object.values(frame.queues).flat(),
        ...Object.values(frame.executing).flat(),
        ...(frame.occ.rapt_completion_stage || []),
      ]),
    ];
    assert.deepEqual(memory.get('core-system').ids, pipelineIds);
    assert.equal(memory.get('core-system').count, pipelineIds.length);
    assert.equal(core.has('prf'), false);
    assert.equal(core.has('sq'), false);
    assert.equal(memory.has('dtlb'), false);
  }
  assert.equal(sampleArchitecture(model.core, data, null).size, 0);
});

test('playback advances, pauses, seeks, loops and suspends without timer leaks', () => {
  const scheduled = new Map();
  let next = 0;
  const tick = () => {
    const [id, fn] = scheduled.entries().next().value;
    scheduled.delete(id);
    fn();
  };
  const player = createPlayback({
    length: 4,
    schedule: (fn) => {
      scheduled.set(++next, fn);
      return next;
    },
    cancel: (id) => scheduled.delete(id),
  });
  assert.equal(scheduled.size, 0);
  assert.equal(player.toggleFlow(), true);
  tick();
  assert.equal(player.state().cycle, 1);
  tick();
  assert.equal(player.state().cycle, 2);
  player.setPlaying(false);
  assert.equal(scheduled.size, 0);
  assert.equal(player.step(-1), 1);
  assert.equal(player.state().playing, false);
  player.setCycle(999);
  assert.equal(player.state().cycle, 3);
  player.setPlaying(true);
  tick();
  assert.equal(player.state().cycle, 0);
  player.setSuspended(true);
  assert.equal(scheduled.size, 0);
  assert.equal(player.state().playing, true);
  player.setSuspended(false);
  assert.equal(scheduled.size, 1);
  tick();
  assert.equal(player.state().cycle, 1);
  player.reset();
  assert.equal(player.state().cycle, 0);
  assert.equal(scheduled.size, 0);
  player.setPlaying(true);
  player.destroy();
  assert.equal(scheduled.size, 0);
  const empty = createPlayback({ length: 0 });
  assert.equal(empty.toggleFlow(), false);
  assert.equal(empty.step(1), 0);
});
