// Functional diagrams of the integrated default core, not a netlist or floorplan.
// Dimensions are drawing coordinates. Capacities come from portal-data.json;
// each selectable block names the RTL modules that implement its contract.
export function buildArchitecture(data) {
  const v = data.config.values;
  const modules = new Map(data.modules.map((m) => [m.id, m]));
  const value = (key) => {
    if (v[key] == null) throw new Error(`Missing architecture parameter: ${key}`);
    return v[key];
  };
  const source = (id) => {
    const mod = modules.get(id);
    if (!mod) throw new Error(`Missing architecture module: ${id}`);
    return { id, file: mod.file };
  };
  function block(id, title, subtitle, x, y, w, h, domain, ids, summary, facts = []) {
    return { id, title, subtitle, x, y, w, h, domain, sources: ids.map(source), summary, facts };
  }
  const edge = (from, to, kind = 'flow', start = 'bottom', end = 'top', via = [], label = '') =>
    ({ from, to, kind, start, end, via, label });
  const group = (title, subtitle, x, y, w, h, domain) => ({ title, subtitle, x, y, w, h, domain });
  const widths =
    `${value('decode_width')} decode · ${value('rename_width')} rename · ` +
    `${value('dispatch_width')} dispatch · ${value('commit_width')} commit`;
  const caches =
    `${value('l1i_kib')} KiB L1I · ${value('l1d_kib')} KiB L1D · ` +
    `${value('cache_line_bytes')} B lines`;
  const core = {
    id: 'core', title: 'Core pipeline', width: 1440, height: 876,
    description:
      'Follow the frontend on the left, rename and dispatch in the center, then five parallel ' +
      'execution domains on the right. Completion returns to the ROB before in-order retirement.',
    groups: [
      group('01  FRONTEND', `${value('decode_width')}-wide decode`, 24, 52, 300, 540, 'frontend'),
      group(
        '02  RENAME & DISPATCH', `${value('rob_entries')} in-flight ROB owners`, 348, 52, 350, 540,
        'backend'),
      group(
        '03  SCHEDULE & EXECUTE', 'Five scheduler classes · independent execution paths',
        722, 52, 694, 540, 'execute'),
      group('REGISTER STATE', 'Integer physical · FP architectural', 24, 620, 300, 228, 'backend'),
      group('04  COMPLETE & RETIRE', 'Precise architectural state', 348, 620, 714, 228, 'backend'),
      group('DATA MEMORY', 'See Memory & platform', 1086, 620, 330, 228, 'memory'),
    ],
    nodes: [
      block(
        'predict', 'Branch prediction',
        `${value('dirp')} · BTB ${value('btb_entries')} · RAS ${value('rsb_entries')}`,
        48, 112, 252, 72, 'frontend', ['rapt_bpu', 'rapt_bpu_tage', 'rapt_bpu_btb', 'rapt_ras'],
        'Predicts direction and targets. Accepted branches update ' +
        'speculative history; retirement trains the predictor.',
        [
          [
            'TAGE',
            `${value('tage_base_entries')} base + 3 × ${value('tage_tagged_entries')} tagged`],
          ['BTB', `${value('btb_entries')} entries, ${value('btb_ways')}-way`],
          ['RAS', `${value('rsb_entries')} entries`]]),
      block(
        'fetch', 'Fetch & instruction queue', '6 halfwords · FQU 4 entries', 48, 316, 252, 88,
        'frontend', ['rapt_ifu', 'rapt_fqu', 'rapt_frontend'],
        'IFU assembles complete 16/32-bit instructions and holds the unused ' +
        'suffix. The registered FQU feeds decode; this is not a micro-op cache.',
        [
          ['Lookahead', '6 halfwords in the default preset'],
          ['FQU', '4 entries; no empty-queue fall-through']]),
      block(
        'icache', 'L1 instruction cache',
        `${value('l1i_kib')} KiB · ${value('l1i_ways')}-way · ITLB ${value('itlb_entries')}`,
        48, 208, 252, 64, 'memory', ['rapt_l1i', 'rapt_tlb'],
        'The memory subsystem supplies instruction bytes and translation to the frontend. ' +
        'Its cache is drawn here for context; it is instantiated in rapt_memory.',
        [
          ['Cache line', `${value('cache_line_bytes')} bytes`], ['Refill sector', '32 bytes'],
          ['ITLB', `${value('itlb_entries')} fully associative entries`]]),
      block(
        'decode', 'Instruction decode',
        `${value('decode_width')} instructions / cycle · RV32 or RV64`, 48, 468, 252, 64,
        'frontend', ['rapt_idu', 'rapt_decode_slot'],
        'Each decode slot uses the generated scalar decoder. Decode can correct ' +
        'direct jumps, return predictions, and stale branch targets before rename.'),
      block(
        'rename', 'Rename & packet buffers',
        `${value('rename_width')}-wide · RNQ ${value('rnq_entries')} · ` +
        `checkpoints ${value('branch_checkpoints')}`, 372, 112, 302, 72, 'backend',
        ['rapt_rnu', 'rapt_operand_stage'],
        'Renames integer registers and resolves dependencies within each group. ' +
        'RNQ, rename_pipe, and the operand stage are distinct registered buffers.',
        [
          ['RNQ', `${value('rnq_entries')} entries`],
          ['rename_pipe', `${2 * value('rename_width')} entries`],
          ['Operand stage', `${value('rename_width')} renamed slots`]]),
      block(
        'prf', 'Integer register file', `${value('phys_regs')} physical registers`,
        48, 680, 252, 64, 'backend', ['rapt_prf'],
        'Integer operands are read at dispatch. Retirement updates the ' +
        'architectural mapping and releases stale physical registers.',
        [
          ['Physical registers', value('phys_regs')], ['Architectural mappings', value('arch_regs')]
        ]),
      block(
        'fpr', 'Floating-point state', 'ROB-backed results · 32 × 64-bit FPRs', 48, 772, 252, 64,
        'fp', ['rapt_fp_registers'],
        'FP renaming uses ROB-backed speculative result versions. The 32-entry architectural ' +
        'FPR bank changes only at retirement; it is not an integer-style physical register file.'),
      block(
        'checkpoints', 'Branch checkpoints',
        `${value('branch_checkpoints')} entries · history & ancestry`, 372, 412, 302, 64, 'backend',
        ['rapt_rename_checkpoint'],
        'Checkpoints retain predictor history and branch ancestry, not MAP/free-list ' +
        'snapshots. A precise flush rebuilds rename state from committed mappings.'),
      block(
        'dispatch', 'Reorder & dispatch',
        `UOQ ${value('uoq_entries')} · ROB ${value('rob_entries')} · ` +
        `${value('dispatch_width')}-wide dispatch`, 372, 260, 302, 88, 'backend',
        ['rapt_rou', 'rapt_dpu'],
        'UOQ admission precedes ROB allocation. Registered carry lanes and ranked resident ' +
        'owners feed capacity-aware dispatch; a blocked domain need not block other domains.',
        [
          ['ROB', `${value('rob_entries')} entries`],
          [
            'Dispatch window', `${value('steer_scan_entries')} lanes, including disabled live lanes`
          ], ['Operand spill', `${value('operand_spill_entries')} entries`]]),
      block(
        'alq', 'Integer queue',
        `ALQ ${value('alq_entries')} · ${value('integer_issue_ports')} issue ports`,
        746, 116, 240, 64, 'execute', ['rapt_ieu', 'rapt_iq'],
        'One shared ALQ selects ready integer instructions for the physical ' +
        'integer ports. CSR/system operations use the designated system port.'),
      block(
        'brq', 'Branch queue', `BRQ ${value('brq_entries')} entries`, 746, 208, 240, 64, 'execute',
        ['rapt_ieu', 'rapt_iq'],
        'The branch queue has its own selection and ' +
        'execution path, separate from the integer ALUs.'),
      block(
        'mdq', 'Multiply / divide queue', `MDQ ${value('mdq_entries')} entries`, 746, 300, 240, 64,
        'execute', ['rapt_ieu_muldiv'],
        'A private queue feeds pipelined multiplication and iterative division.'),
      block(
        'fpq', 'Floating-point queue', `FPQ ${value('fpq_entries')} entries`, 746, 392, 240, 64,
        'fp', ['rapt_feu', 'rapt_iq'],
        'The FP queue captures renamed operands, including the third FMA ' +
        'operand, and selects an instruction whose arithmetic unit has capacity.'),
      block(
        'ioq', 'Memory queue', `IOQ ${value('ioq_entries')} entries`, 746, 484, 240, 64, 'memory',
        ['rapt_lsu_ioq'],
        'IOQ prepares addresses and enforces memory ordering. Eligible ' +
        'younger loads can proceed; atomics and MMIO stay ordered at the head.'),
      block(
        'alu', `Integer ALUs ×${value('integer_issue_ports')}`, 'CSR / system on port 0',
        1112, 116, 280, 64, 'execute', ['rapt_ieu', 'rapt_ieu_alu', 'rapt_ieu_pipe_alu_csr'],
        'Simple integer operations execute on the ALU ports. Local operand capture ' +
        'can wake dependent ALQ/BRQ entries ahead of global registered wakeup.'),
      block(
        'branch', 'Branch execution', 'Compare · target · recovery', 1112, 208, 280, 64, 'execute',
        ['rapt_ieu_pipe_branch'],
        'Resolves branch direction and targets. A misprediction creates a registered ' +
        'recovery transaction; precise rename recovery completes at retirement.'),
      block(
        'muldiv', 'Integer MUL / DIV', 'Pipelined MUL · iterative DIV', 1112, 300, 280, 64,
        'execute', ['rapt_ieu_muldiv', 'rapt_ieu_mul'],
        'The default multiplier has two pipeline stages; division is iterative with ' +
        'data-dependent normalization. Execution latency is distinct from retirement latency.'),
      block('fp', 'Scalar floating point', 'F / D / Zfhmin', 1112, 392, 280, 64, 'fp', ['rapt_feu'],
        'Independent arithmetic units overlap, with shared multiply/FMA product pipelines and a ' +
        'separate divide/square-root unit. The standalone VPU is not part of this scalar core.'),
      block(
        'lsu', 'Load / store execution', 'Address · ordering · replay', 1112, 484, 280, 64,
        'memory', ['rapt_lsu', 'rapt_lsu_ioq'],
        'Loads, stores, and atomics share one memory completion endpoint. ' +
        'Hit-under-miss and MSHR replay do not add a second memory completion port.'),
      block(
        'completion', `Guarded completion ×${value('completion_ports')}`,
        'Registered before ROB writeback & recovery', 372, 680, 666, 64, 'backend',
        ['rapt_completion_guard', 'rapt_completion_stage', 'rapt_backend'],
        'Every accepted completion is registered before it updates the ROB. Operand wakeup ' +
        'has separate local and global paths; those bypasses are omitted from the overview.',
        [
          ['Endpoints', `${value('integer_issue_ports')} integer + branch + memory + MUL/DIV + FP`],
          ['Owner identity', 'ROB slot + allocation generation']]),
      block(
        'commit', `In-order retirement ×${value('commit_width')}`,
        'Ready ROB head prefix · precise exceptions', 372, 772, 400, 64, 'backend',
        ['rapt_rou', 'rapt_cmu'],
        'ROU retires a ready prefix in order; CMU broadcasts architectural effects. ' +
        'Stores become committed here and drain separately through the store queue.'),
      block(
        'csr', 'CSR & traps', 'M / S / U · interrupts', 798, 772, 240, 64, 'backend', ['rapt_csr'],
        'Holds privilege, trap, translation, interrupt, and PMP configuration. ' +
        'CSR/system instructions serialize architectural updates.'),
      block(
        'dcache', 'L1 data cache',
        `${value('l1d_kib')} KiB · ${value('l1d_ways')}-way · write-back`, 1110, 680, 282, 64,
        'memory', ['rapt_l1d'],
        'L1D serves translated loads and committed stores. Its shared data ' +
        'read port and single memory completion endpoint limit bandwidth.',
        [
          ['MSHRs', value('l1d_mshrs')], ['Writeback buffers', '2'],
          ['Translation', 'See Memory & platform']]),
      block(
        'sq', 'Unified store queue', `${value('sq_entries')} entries · drain after commit`,
        1110, 772, 282, 64, 'memory', ['rapt_lsu_sq'],
        'An entry holds a store from speculative execution through committed ' +
        'drain. Flush discards speculative entries but preserves committed stores.'),
    ],
    edges: [
      edge('predict', 'fetch', 'flow', 'right', 'right', [[312, 148], [312, 360]]),
      edge('icache', 'fetch', 'memory'),
      edge('fetch', 'decode'),
      edge('decode', 'rename', 'flow', 'right', 'top', [[340, 500], [340, 96], [523, 96]]),
      edge('rename', 'dispatch'),
      edge('prf', 'dispatch', 'operand', 'right', 'left', [[336, 712], [336, 304]]),
      edge('fpr', 'dispatch', 'operand', 'right', 'left', [[330, 804], [330, 304]]),
      edge('rename', 'checkpoints', 'control', 'left', 'left', [[360, 148], [360, 444]]),
      ...['alq', 'brq', 'mdq', 'fpq', 'ioq'].map(
        (id, i) => edge('dispatch', id, 'flow', 'right', 'left', [[710, 304], [710, 148 + i * 92]])
      ),
      ...[['alq', 'alu'], ['brq', 'branch'], ['mdq', 'muldiv'], ['fpq', 'fp'], ['ioq', 'lsu']].map(
        ([a, b]) => edge(a, b, 'flow', 'right', 'left')),
      ...['alu', 'branch', 'muldiv', 'fp', 'lsu'].map(
        (id, i) => edge(
          id, 'completion', 'result', 'right', 'top',
          [[1428, 148 + i * 92], [1428, 608], [705, 608]])),
      edge('completion', 'commit', 'result', 'bottom', 'top', [[705, 758], [572, 758]]),
      edge('lsu', 'dcache', 'memory', 'right', 'right', [[1422, 516], [1422, 712]]),
      edge('lsu', 'sq', 'memory', 'right', 'right', [[1434, 516], [1434, 804]]),
      edge('sq', 'dcache', 'memory', 'top', 'bottom'),
      edge('commit', 'sq', 'control', 'bottom', 'bottom', [[572, 860], [1251, 860]]),
      edge('commit', 'csr', 'control', 'right', 'left'),
      edge(
        'commit', 'predict', 'control', 'bottom', 'left', [[572, 854], [12, 854], [12, 148]],
        'Flush / predictor training'),
    ],
  };
  const memory = {
    id: 'memory', title: 'Memory & platform', width: 1160, height: 1110,
    description:
      'Translation and cache traffic are separate paths. Follow TLB misses to the shared L2 ' +
      'TLB, then page-table walkers; follow memory requests through AXI to the cluster router.',
    groups: [
      group('L1 MEMORY SYSTEMS', caches, 32, 48, 1096, 210, 'memory'),
      group('PROTECTION', 'Applied to fetch, data & PTE access', 32, 282, 244, 252, 'backend'),
      group(
        'SHARED TRANSLATION', 'L2 TLB is independent of the L2 data cache', 300, 282, 560, 252,
        'memory'),
      group('DATA MISS HANDLING', 'Inside L1D', 880, 282, 248, 252, 'memory'),
      group(
        'CORE BIU → CLUSTER L2 SUBSYSTEM', 'l2_client_if boundary; AXI outside the core',
        32, 558, 1096, 248, 'memory'),
      group(
        'CLUSTER & PLATFORM', 'rapt cluster boundary · off-core devices', 32, 834, 1096, 252,
        'platform'),
    ],
    nodes: [
      block(
        'l1i', 'L1 instruction cache', `${value('l1i_kib')} KiB · ${value('l1i_ways')}-way`,
        60, 108, 240, 88, 'memory', ['rapt_l1i'],
        'Instruction-cache storage belongs to rapt_memory. A default ' +
        'miss refills a 32-byte sector within a 64-byte line.'),
      block(
        'itlb', 'Instruction TLB', `${value('itlb_entries')} · fully associative`,
        340, 108, 204, 88, 'memory', ['rapt_tlb', 'rapt_l1i'],
        'ITLB misses probe the shared L2 TLB before the instruction page-table walker. ' +
        'The dedicated MMIO instruction-fetch translation path uses a separate walker.'),
      block(
        'dtlb', 'Data TLB', `${value('dtlb_entries')} entries · ${value('dtlb_ways')}-way`,
        616, 108, 204, 88, 'memory', ['rapt_tlb', 'rapt_l1d'],
        'Replicated load and store lookup tables receive shared fills. Each replica ' +
        'has the displayed capacity; replication is not extra distinct translations.',
        [
          ['Load replica', `${value('dtlb_entries')} entries`],
          ['Store replica', `${value('dtlb_entries')} entries`]]),
      block(
        'l1d', 'L1 data cache', `${value('l1d_kib')} KiB · ${value('l1d_ways')}-way · write-back`,
        860, 108, 240, 88, 'memory', ['rapt_l1d'],
        'Cacheable replayable loads translate and pass permission checks ' +
        'before allocating a miss. Same-line misses can share a refill.'),
      block(
        'pmp', 'Physical protection', `${value('pmp_usable')} usable PMP entries`, 60, 328, 188, 70,
        'backend', ['rapt_pmp', 'rapt_pmp_state'],
        'PMP checks instruction, data, and page-table accesses. Eight usable entries ' +
        'support TOR and NAPOT at the default 4 KiB grain; upper slots read as zero. ' +
        'NA4 requires an explicit four-byte-grain configuration.',
        [['PMP grain', `${value('pmp_grain_bytes')} bytes`]]),
      block(
        'attributes', 'Memory attributes', 'PMA · RV64 Svpbmt', 60, 436, 188, 70, 'backend',
        ['rapt_memory', 'rapt_ptw'],
        'Physical-region attributes and translated RV64 page-based ' +
        'memory types govern cacheability, ordering, and supported ' +
        'device accesses. Checks are not a serial pipeline stage.',
        [['Default PA bits', `RV32: ${value('paddr_bits')}; RV64: ${value('rv64_paddr_bits')}`]]),
      block(
        'l2tlb', 'Shared L2 TLB', `${value('l2tlb_entries')} entries · direct-mapped`,
        384, 328, 392, 70, 'memory', ['rapt_l2tlb', 'rapt_cached_ptw'],
        'Instruction and data translation misses share a second-level translation ' +
        'cache. A hit refills the requesting L1 TLB; only a miss proceeds to its walker.'),
      block(
        'iptw', 'Instruction walker', 'Sv32 / Sv39', 328, 436, 220, 70, 'memory',
        ['rapt_cached_ptw', 'rapt_ptw', 'rapt_l1i'],
        'The instruction-side walker obtains PTEs through the memory bus. A ' +
        'cancelled accepted read is drained without refilling translation caches.'),
      block(
        'dptw', 'Data walker', 'Shared by load & store', 596, 436, 220, 70, 'memory',
        ['rapt_cached_ptw', 'rapt_ptw', 'rapt_l1d'],
        'Load/store translation shares a data walker. A/D bits use software ' +
        'management (Svade); PTE access can require publication of dirty cache data.'),
      block(
        'mshr', 'Miss tracking', `${value('l1d_mshrs')} MSHRs · IOQ replay`, 908, 328, 192, 70,
        'memory', ['rapt_l1d_mshr'],
        'Tracks physical-line refills. Translated misses park in IOQ and replay ' +
        'after wakeup; demanded words can return before the last refill beat.'),
      block(
        'writeback', 'Dirty writeback', '2 full-line buffers', 908, 436, 192, 70, 'memory',
        ['rapt_l1d_writeback'],
        'Buffers capture dirty victims with per-word masks. Failed write ' +
        'responses retain dirty data; fences and coherence wait for publication.'),
      block(
        'bus', 'Core memory request arbitration', 'L1I + L1D + PTW → l2_client_if',
        60, 606, 1040, 60, 'memory', ['rapt_bus'],
        'Arbitrates cache and page-table traffic and maintains request ownership. ' +
        'Default write-back L1D bus writes retain ownership until the AXI B response.'),
      block(
        'axi', 'AXI4 adapter', 'XLEN-bit data / address · 4-bit ID', 60, 708, 300, 66, 'memory',
        ['rapt_axi_master'],
        'Converts the internal memory link to AXI. The adapter is ' +
        'inside the cluster-level rapt_l2_subsystem, before its optional cache. ' +
        'The subsystem owns AXI IDs and defaults to eight outstanding reads.'),
      block(
        'l2', 'L2 cache storage', v.l2_enabled ? 'Enabled in this preset' : 'Default: no cache',
        412, 708, 300, 66, 'optional', ['rapt_l2'],
        'The default preset bypasses L2 storage. The separate default-l2 preset enables a ' +
        '512 KiB, eight-way inclusive write-back cache; that capacity is not active here.',
        [
          ['Selected preset', v.l2_enabled ? 'L2 enabled' : 'L2 cache disabled'],
          ['default-l2 only', '512 KiB · 8-way · inclusive']]),
      block(
        'l2-port', 'L2 subsystem AXI port', 'Outer R buffer in default-l2', 764, 708, 336, 66,
        'memory', ['rapt_l2_subsystem', 'rapt_axi_r_buffer', 'rapt_memory', 'rapt_core'],
        'The optional outer AXI read-response buffer follows L2 storage. ' +
        'The core ends at l2_client_if; the L2 subsystem supplies AXI even without a cache.'),
      block(
        'router', 'Cluster address router', 'CLINT · PLIC · off-chip AXI', 400, 886, 360, 66,
        'platform', ['rapt_router', 'rapt'],
        'Routes the L2 subsystem AXI master to the shared interrupt devices or the ' +
        'external platform. CLINT and PLIC are parallel targets, not a chain.'),
      block(
        'clint', 'CLINT', 'mtime · mtimecmp · msip', 60, 996, 240, 64, 'platform', ['rapt_clint'],
        'Cluster-local timer and software interrupt state. ' +
        'Its counter also feeds the core time state.'),
      block(
        'plic', 'PLIC', '31 sources · M / S contexts', 340, 996, 240, 64, 'platform', ['rapt_plic'],
        'Cluster-local external interrupt controller. Ordinary ' +
        'accesses use naturally aligned 32-bit device loads and stores.'),
      block(
        'external', 'External memory & MMIO',
        'NPC or selected FPGA platform · RAM / UART / devices', 620, 996, 480, 64, 'platform',
        ['rapt'],
        'RAM, UART, and other external devices are supplied by the platform. Their addresses ' +
        'and capacities depend on the simulator profile or board, not on the core pipeline.'),
      block(
        'debug', 'JTAG + debug module', 'Hart halt / register access', 860, 886, 240, 66,
        'platform', ['rapt_dtm', 'rapt_dm'],
        'The DTM and Debug Module use the debug control path. They are ' +
        'not an extra memory-mapped target of the cluster AXI router.'),
    ],
    edges: [
      edge('l1i', 'itlb', 'translation', 'right', 'left'),
      edge('l1d', 'dtlb', 'translation', 'left', 'right'),
      edge('itlb', 'l2tlb', 'translation', 'bottom', 'top', [[442, 246], [580, 246]]),
      edge('dtlb', 'l2tlb', 'translation', 'bottom', 'top', [[718, 246], [580, 246]]),
      edge('l2tlb', 'iptw', 'translation', 'bottom', 'top', [[580, 418], [438, 418]]),
      edge('l2tlb', 'dptw', 'translation', 'bottom', 'top', [[580, 418], [706, 418]]),
      edge('l1d', 'mshr', 'memory', 'bottom', 'top', [[980, 246], [1004, 246]]),
      edge('l1d', 'writeback', 'memory', 'right', 'right', [[1116, 152], [1116, 471]]),
      edge('l1i', 'bus', 'memory', 'left', 'left', [[16, 152], [16, 636]]),
      ...[['iptw', 438], ['dptw', 706], ['writeback', 1004]].map(
        ([id, x]) => edge(id, 'bus', 'memory', 'bottom', 'top', [[x, 550], [580, 550]])),
      edge('mshr', 'bus', 'memory', 'right', 'right', [[1122, 363], [1122, 636]]),
      edge('bus', 'axi', 'memory', 'bottom', 'top', [[580, 688], [210, 688]]),
      edge('axi', 'l2', 'memory', 'right', 'left'),
      edge('l2', 'l2-port', 'memory', 'right', 'left'),
      edge('l2-port', 'router', 'memory', 'bottom', 'top', [[932, 820], [580, 820]]),
      ...[['clint', 180], ['plic', 460], ['external', 860]].map(
        ([id, x]) => edge('router', id, 'memory', 'bottom', 'top', [[580, 976], [x, 976]])),
    ],
  };
  // Each tab covers the same system. Collapse the other tab's detail into a
  // navigable block, keeping the architectural boundary connections visible.
  core.height = 1104;
  core.description +=
    ' The memory and platform overview below completes the system; ' +
    'open it for translation, interconnect, devices, and debug details.';
  core.groups.push(
    group(
      'SYSTEM CONTEXT',
      'L1 caches are expanded above; the remaining memory and platform functions are grouped here',
      24, 896, 1392, 184, 'memory'));
  core.nodes.push({
    ...block(
      'memory-system', 'Memory & platform',
      'TLBs & page walkers · memory bus · optional L2 · CLINT / PLIC · debug · external RAM / MMIO',
      48, 950, 1344, 104, 'memory',
      ['rapt_memory', 'rapt_l2_subsystem', 'rapt_router', 'rapt_clint',
        'rapt_plic', 'rapt_dm', 'rapt_dtm', 'rapt'],
      'Translation and protection serve instruction and data accesses. Cache ' +
      'and page-table traffic share the memory bus, AXI adapter, and optional ' +
      'L2 before the cluster router reaches interrupt devices and the external ' +
      'platform. Interrupts and debug also connect directly to the core.'),
    targetView: 'memory',
  });
  core.edges.push(
    edge(
      'icache', 'memory-system', 'memory', 'left', 'left', [[6, 240], [6, 1002]],
      'Instruction translation / refill path'),
    edge(
      'dcache', 'memory-system', 'memory', 'right', 'right', [[1438, 712], [1438, 1002]],
      'Data translation / external request path'),
    edge(
      'memory-system', 'csr', 'control', 'top', 'bottom', [[720, 880], [918, 880]],
      'Timer / software / external interrupts'),
    edge(
      'memory-system', 'dispatch', 'control', 'left', 'left', [[18, 1002], [18, 304]],
      'Hart debug / halt control (simplified)'),
  );

  const pipelineHeight = 200;
  memory.height += pipelineHeight;
  memory.groups.forEach((g) => { g.y += pipelineHeight; });
  memory.nodes.forEach((n) => { n.y += pipelineHeight; });
  memory.edges.forEach((e) => { e.via = e.via.map(([x, y]) => [x, y + pipelineHeight]); });
  memory.description =
    'The core pipeline overview supplies instruction and data requests and receives ' +
    'interrupts and debug control. Open it for pipeline detail. ' + memory.description;
  memory.groups.unshift(
    group(
      'CORE PIPELINE', 'Frontend · rename & dispatch · parallel execution · precise retirement',
      32, 48, 1096, 184, 'backend'));
  memory.nodes.unshift({
    ...block(
      'core-system', 'Core pipeline',
      `${widths} · ROB ${value('rob_entries')} · integer / FP / load-store execution`,
      60, 108, 1040, 104, 'backend',
      ['rapt_frontend', 'rapt_backend', 'rapt_csr', 'rapt_lsu_sq'],
      'Prediction, fetch, decode, rename, scheduling, execution, completion, and ' +
      'in-order retirement form the core pipeline. Fetch uses the instruction ' +
      'memory path; LSU and committed stores use the data path. Privilege state ' +
      'receives interrupts, and the debug module controls hart access.'),
    targetView: 'core',
  });
  memory.edges.push(
    edge(
      'core-system', 'l1i', 'memory', 'left', 'left', [[16, 160], [16, 352]],
      'Instruction fetch / response'),
    edge(
      'core-system', 'l1d', 'memory', 'right', 'right', [[1144, 160], [1144, 352]],
      'Load / store requests and responses'),
    edge(
      'debug', 'core-system', 'control', 'right', 'right', [[1136, 1119], [1136, 160]],
      'Hart debug control'),
    edge(
      'clint', 'core-system', 'control', 'left', 'left', [[24, 1228], [24, 160]],
      'Timer / software interrupts'),
    edge(
      'plic', 'core-system', 'control', 'bottom', 'left', [[460, 1298], [20, 1298], [20, 160]],
      'External interrupts'),
  );
  return { core, memory, widths, caches, preset: data.config.preset };
}

export function port(node, side) {
  if (side === 'left') return [node.x, node.y + node.h / 2];
  if (side === 'right') return [node.x + node.w, node.y + node.h / 2];
  if (side === 'top') return [node.x + node.w / 2, node.y];
  return [node.x + node.w / 2, node.y + node.h];
}

export function edgePoints(view, edge) {
  const byId = new Map(view.nodes.map((n) => [n.id, n]));
  return [port(byId.get(edge.from), edge.start), ...edge.via, port(byId.get(edge.to), edge.end)];
}
