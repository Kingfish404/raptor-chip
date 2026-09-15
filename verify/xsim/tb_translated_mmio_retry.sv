`include "rapt.svh"
`include "rapt_if.svh"

// Real IOQ -> SQ -> L1D -> PTW chain, with delayed memory and MMIO reads.
module tb_translated_mmio_retry;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] IoVA = XLEN'('h40000000);
  localparam logic [XLEN-1:0] IoPA = XLEN'('h10000000);
  localparam logic [XLEN-1:0] RamVA = XLEN'('h80001000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  l1d_bus_if l1d_bus ();
  rou_cmu_if rou_cmu ();
  rou_lsu_if rou_lsu ();
  fpr_if fpr ();
  load_fast_if load_fast ();
  dpu_ioq_if disp_ioq ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t exu_ioq_bcast, producer;
  logic pmu_sq_full;
  for (genvar i = 0; i < rapt_pkg::CompletionPorts; i++) begin
    assign completion[i] = i == 0 ? producer : i == 3 ? exu_ioq_bcast : '0;
  end
  rapt_lsu dut (
      .wb_accept(1'b1),
      .*
  );
  rapt_l1d #(
      .LineRefill(0)
  ) cache (
      .clock,
      .reset,
      .cmu_bcast,
      .lsu_l1d,
      .l1d_bus,
      .csr_bcast,
      .pmp_update,
      .exu_l1d
  );
  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  int delay_left, mmio_reads, ram_reads, retries, commits;
  logic pending_ptw;
  logic [XLEN-1:0] pending_data;
  assign l1d_bus.rready = l1d_bus.arvalid && delay_left == 0;
  function automatic logic [XLEN-1:0] pte(input logic [XLEN-1:0] addr);
    if (XLEN == 32) begin
      case (addr)
        XLEN'('h80001400): return (IoPA >> 2) | XLEN'('hcf);
        XLEN'('h80001800): return XLEN'('h200000cf);
        default: return '0;
      endcase
    end else begin
      case (addr)
        XLEN'('h80001008): return XLEN'('h20000801); // next level at 80002000
        XLEN'('h80002000): return (IoPA >> 2) | XLEN'('hcf);
        XLEN'('h80001010): return XLEN'('h200000cf);
        default: return '0;
      endcase
    end
  endfunction
  always @(posedge clock) begin
    if (reset) begin
      delay_left <= 0;
      mmio_reads <= 0;
      ram_reads <= 0;
      retries <= 0;
      commits <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        pending_data <= l1d_bus.ar_ptw ? pte(l1d_bus.araddr)
            : l1d_bus.araddr == IoPA ? XLEN'(7) : XLEN'('h12345678);
        delay_left <= 3;
        if (!l1d_bus.ar_ptw) begin
          if (l1d_bus.araddr == IoPA) begin
            check(lsu_l1d.ordered && cmu_bcast.rob_head == 4 && commits == 1,
                  "MMIO side effect before the older load completed");
            mmio_reads <= mmio_reads + 1;
          end else begin
            check(l1d_bus.araddr == RamVA, "unexpected data address");
            ram_reads <= ram_reads + 1;
          end
        end
      end else if (delay_left != 0) begin
        delay_left <= delay_left - 1;
        if (delay_left == 1) begin
          l1d_bus.rvalid <= !pending_ptw;
          l1d_bus.ptw_rvalid <= pending_ptw;
          l1d_bus.rdata <= pending_data;
        end
      end
      if (lsu_l1d.rretry) begin
        check(!lsu_l1d.rready && !load_fast.valid && !exu_ioq_bcast.valid,
              "retry produced a completion");
        check(dut.exu_lsu.rretry, "SQ failed to propagate retry");
        retries <= retries + 1;
      end
      if (exu_ioq_bcast.valid) begin
        check(!exu_ioq_bcast.trap, "translated load trapped");
        check(exu_ioq_bcast.dest == (commits == 0 ? 3 : 4), "completion order changed");
        check(exu_ioq_bcast.result == (commits == 0 ? XLEN'('h12345678) : XLEN'(7)),
              "completion data mismatch");
        commits <= commits + 1;
      end
    end
  end

  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b1);
    producer = '0;
    foreach (dispatch[i]) dispatch[i] = '0;
    disp_ioq.accept[0] = 0;
    disp_ioq.accept[1] = 0;
    fpr.ioq_rdata = 0;
    rou_lsu.store = 0;
    rou_lsu.dest = 0;
    rou_lsu.sq_vaddr = 0;
    rou_lsu.pc = 0;
    rou_lsu.valid = 0;
    rou_cmu.slot = '{default:'0};
    rou_cmu.atomic_sc = 0;
    rou_cmu.fence_time = 0;
    rou_cmu.cbo_inval = 0;
    rou_cmu.cbo_block = '0;
    rou_cmu.flush_pipe = 0;
    pmp_update.addr_we = 0;
    pmp_update.addr_idx = 0;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 0;
    pmp_update.cfg_r = 1;
    pmp_update.cfg_w = 1;
    pmp_update.cfg_x = 1;
    pmp_update.cfg_l = 0;
    pmp_update.mode_off = '1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_tor = 0;
    pmp_update.mode_na4 = 0;
    pmp_update.mode_napot = 1;
    l1d_bus.rerr = 0;
    l1d_bus.ptw_rerr = 0;
    l1d_bus.rlast = 1;
    l1d_bus.difftest_skip = 0;
    l1d_bus.wready = 1;
    l1d_bus.werr = 0;
    l1d_bus.ptw_wready = 0;
    l1d_bus.ptw_werr = 0;
    tick(3);
    reset = 0;
    pmp_update.addr_we = 1;
    pmp_update.cfg_we = 1;
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
    csr_bcast.mprv = 1;
    csr_bcast.mpp = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80001;
    csr_bcast.menvcfg_pbmte = 0;
    cmu_bcast.rob_head = 3;
    for (int i = 0; i < 2; i++) begin
      dispatch[i].uop.execute.memory.load = 1;
      dispatch[i].uop.execute.int_op.alu = `RAPT_ALU_LW__;
      dispatch[i].uop.rd = 5'(10+i);
      dispatch[i].prd = $bits(dispatch[i].prd)'(10+i);
      dispatch[i].dest = $bits(dispatch[i].dest)'(3+i);
    end
    dispatch[0].pr1 = 9;
    dispatch[1].op1 = IoVA;
    disp_ioq.accept[0] = 1;
    disp_ioq.accept[1] = 1;
    tick(1);
    disp_ioq.accept[0] = 0;
    disp_ioq.accept[1] = 0;
    for (int c = 0; c < 20 && !dut.exu_lsu.rvalid; c++) tick(1);
    check(dut.exu_lsu.rvalid && dut.exu_lsu.raddr == IoVA && !dut.exu_lsu.ordered,
          "younger translated load did not own request A");
    producer.valid = 1;
    producer.prd = 9;
    producer.result = RamVA;
    tick(1);
    producer.valid = 0;
    if ($test$plusargs("FLUSH_RETRY")) begin
      for (int c = 0; c < 100 && !lsu_l1d.rretry; c++) tick(1);
      check(lsu_l1d.rretry, "retry/flush collision not reached");
      cmu_bcast.flush_pipe = 1;
      #1;
      check(!lsu_l1d.rretry && !dut.exu_lsu.rretry, "flush did not suppress retry");
      tick(1);
      cmu_bcast.flush_pipe = 0;
      tick(20);
      check(
          commits == 0 && mmio_reads == 0 && !dut.exu_lsu.rvalid
            && dut.u_ioq.ioq_valid == 0 && dut.u_ioq.ioq_needs_ordered == 0,
          "retry/flush collision left a request or completion");
      $display("PASS: translated retry/flush collision XLEN=%0d", XLEN);
      $finish;
    end
    for (int c = 0; c < 150 && commits == 0; c++) tick(1);
    check(commits == 1 && retries == 1 && ram_reads == 1 && mmio_reads == 0,
          "older RAM load did not escape translated MMIO blocking");
    tick(5);
    check(!dut.exu_lsu.rvalid && mmio_reads == 0, "MMIO retried before ROB head");
    if ($test$plusargs("FLUSH_DEFERRED")) begin
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      cmu_bcast.rob_head = 4;
      tick(20);
      check(
          commits == 1 && mmio_reads == 0 && !dut.exu_lsu.rvalid
            && dut.u_ioq.ioq_valid == 0 && dut.u_ioq.ioq_needs_ordered == 0,
          "flushed deferred MMIO survived recovery");
      $display("PASS: translated deferred-load flush XLEN=%0d", XLEN);
      $finish;
    end
    cmu_bcast.rob_head = 4;
    for (int c = 0; c < 100 && commits != 2; c++) tick(1);
    check(commits == 2 && retries == 1 && mmio_reads == 1,
          "MMIO did not complete exactly once after ordered replay");
    tick(5);
    check(mmio_reads == 1 && commits == 2, "duplicate completion or MMIO read");
    $display("PASS: real IOQ/SQ/L1D translated MMIO replay XLEN=%0d", XLEN);
    $finish;
  end
endmodule
