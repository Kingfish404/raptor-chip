// Bind the illustrative trace to functional blocks. Queue occupancy and execution
// are separate measurements; unmodeled hardware has no invented zero occupancy.
export function sampleArchitecture(view, data, frame) {
  const samples = new Map();
  if (!frame?.queues || !frame?.executing) return samples;
  const v = data.config.values;
  const q = frame.queues;
  const occ = (id) => frame.occ?.[id] || [];
  const unique = (...lists) => [...new Set(lists.flat())];
  const put = (id, ids, capacity, label, detail = label, count = ids.length) => {
    samples.set(id, { ids, count, capacity, label, detail });
  };
  const queue = (id, key, capacity, name = '') => {
    const ids = q[key] || [];
    put(id, ids, capacity, `${name ? name + ' ' : ''}${ids.length} / ${capacity}`, `${name || id.toUpperCase()}: ${ids.length} of ${capacity} model slots`);
  };
  if (view.id === 'core') {
    const fetched = unique(q.ifu, q.fqu);
    put('fetch', fetched, 3 * v.decode_width, `${fetched.length} buffered`, `IFU: ${q.ifu.length} / ${v.decode_width}; FQU: ${q.fqu.length} / ${2 * v.decode_width}`);
    queue('decode', 'idu', v.decode_width);
    queue('rename', 'rnu', v.rnq_entries, 'RNQ');
    put('dispatch', unique(q.rob, q.uoq), v.rob_entries,
      `ROB ${q.rob.length}/${v.rob_entries} · UOQ ${q.uoq.length}/${v.uoq_entries}`,
      `ROB: ${q.rob.length} / ${v.rob_entries}; UOQ: ${q.uoq.length} / ${v.uoq_entries}. Bar shows ROB occupancy.`, q.rob.length);
    for (const id of ['alq', 'brq', 'mdq', 'fpq', 'ioq']) queue(id, id, v[`${id}_entries`]);
    for (const [id, kind] of [['alu', 'alq'], ['branch', 'brq'], ['muldiv', 'mdq'], ['fp', 'fpq'], ['lsu', 'ioq']]) {
      const ids = frame.executing[kind] || [];
      put(id, ids, null, `${ids.length} executing`);
    }
    put('completion', occ('rapt_completion_stage'), null, `${occ('rapt_completion_stage').length} completing`);
    put('commit', occ('rapt_cmu'), v.commit_width, `${occ('rapt_cmu').length} retired`, 'Instructions retiring in this model cycle only.');
  }
  put(view.id === 'core' ? 'icache' : 'l1i', occ('rapt_l1i'), null, `${occ('rapt_l1i').length} requests`, 'Modeled instruction fetch requests; cache contents are not simulated.');
  put(view.id === 'core' ? 'dcache' : 'l1d', occ('rapt_l1d'), null, `${occ('rapt_l1d').length} requests`, 'Modeled data requests; hit/miss and replay timing are simplified.');
  if (view.id === 'memory') {
    const active = unique(...Object.values(q), ...Object.values(frame.executing), occ('rapt_completion_stage'));
    put('core-system', active, null, `${active.length} in flight · ${occ('rapt_cmu').length} retiring`,
      'Unique instructions across modeled pipeline buffers, the ROB, queues, execution, and completion. An instruction appearing in several structures is counted once; retirement is shown separately.');
    const external = unique(occ('soc_pmem'), occ('soc_uart'));
    for (const id of ['bus', 'axi', 'l2', 'core-port', 'router', 'external']) {
      put(id, external, null, `${external.length} requests`, 'The same outstanding external requests are shown along their path; these are not separate occupied bus slots.');
    }
  } else {
    const external = unique(occ('soc_pmem'), occ('soc_uart'));
    put('memory-system', external, null, `${external.length} external requests`,
      'Outstanding modeled external requests, matching the detailed memory view. Translation, interrupts, debug, and cache contents are not simulated.');
  }
  return samples;
}

// Only run a timer while playing and visible. Seeking and stepping always pause;
// changing the diagram view leaves this shared timeline untouched.
export function createPlayback({ length, period = 180, onChange = () => {}, schedule = setTimeout, cancel = clearTimeout }) {
  let cycle = 0;
  let playing = false;
  let suspended = false;
  let timer = null;
  const state = () => ({ cycle, playing, length });
  function stopTimer() {
    if (timer !== null) cancel(timer);
    timer = null;
  }
  function arm() {
    if (playing && !suspended && timer === null) timer = schedule(() => {
      timer = null;
      cycle = (cycle + 1) % length;
      onChange(state());
      arm();
    }, period);
  }
  function setPlaying(on) {
    playing = Boolean(on && length > 0);
    stopTimer();
    onChange(state());
    arm();
    return playing;
  }
  function seek(value) {
    cycle = Math.max(0, Math.min(length - 1, Math.trunc(Number(value)) || 0));
    cycle = Math.max(0, cycle);
    setPlaying(false);
    return cycle;
  }
  return {
    state,
    setPlaying,
    toggleFlow: () => setPlaying(!playing),
    setCycle: seek,
    step: (delta) => seek(cycle + delta),
    reset: () => seek(0),
    setSuspended(value) { suspended = Boolean(value); stopTimer(); arm(); },
    destroy() { playing = false; stopTimer(); },
  };
}
