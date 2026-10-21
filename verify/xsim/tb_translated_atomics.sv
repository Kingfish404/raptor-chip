`include "rapt.svh"
`include "rapt_if.svh"

// Real IOQ -> SQ -> L1D -> PTW chain, with delayed memory and MMIO reads.
module tb_translated_atomics;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] VA = XLEN'('h40001000);
  localparam logic [XLEN-1:0] PA = XLEN'('h80001000);
  localparam int TlbSlot = `RAPT_DTLB_WAYS == 0 ? 0 : 1;
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
  dpu_ioq_if disp_ioq ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t exu_ioq_bcast, producer;
  logic pmu_sq_full;
  for (genvar i = 0; i < rapt_pkg::CompletionPorts; i++) begin
    assign completion[i] = i == 0 ? producer : i == rapt_pkg::completion_memory_port(
        rapt_pkg::CoreConfig
    ) ? exu_ioq_bcast : '0;
  end
  rapt_pkg::completion_t local_fp_wake[rapt_pkg::CompletionPorts];
  assign local_fp_wake = '{default: '0};
  rapt_lsu dut (
      .wb_accept(1'b1),
      .*
  );
  rapt_l1d #(
      .LineRefill(0)
  ) cache (
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
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

  logic [7:0] memory_bytes[64];
  int delay_left = 0, cases = 0, owner = 1;
  bit pending_ptw;
  logic [XLEN-1:0] pending_data;
  assign l1d_bus.rready = delay_left == 0;
  assign l1d_bus.idle = delay_left == 0;
  assign l1d_bus.r_mshr = 0;
  assign l1d_bus.r_mshr_id = 0;
  assign l1d_bus.posted_busy = 0;
  assign l1d_bus.posted_error = 0;
  assign l1d_bus.posted_error_addr = 0;
  always @(posedge clock) begin
    if (reset) begin
      delay_left <= 0;
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      l1d_bus.rdata <= 0;
    end else begin
      l1d_bus.rvalid <= 0;
      l1d_bus.ptw_rvalid <= 0;
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        pending_ptw <= l1d_bus.ar_ptw;
        delay_left <= 3;
        if (l1d_bus.ar_ptw) pending_data <= XLEN'('h200000cf);
        else begin
          check(l1d_bus.araddr >= PA && l1d_bus.araddr < PA + 64,
                "atomic/split request used the wrong physical address");
          for (int b = 0; b < XLEN / 8; b++)
          pending_data[b*8+:8] <= memory_bytes[(int'(l1d_bus.araddr-PA)&~(XLEN/8-1))+b];
        end
      end else if (delay_left != 0) begin
        delay_left <= delay_left - 1;
        if (delay_left == 1) begin
          l1d_bus.rvalid <= !pending_ptw;
          l1d_bus.ptw_rvalid <= pending_ptw;
          l1d_bus.rdata <= pending_data;
        end
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        check(l1d_bus.awaddr >= PA && l1d_bus.awaddr < PA + 64,
              "atomic store used the wrong physical address");
        for (int b = 0; b < XLEN / 8; b++)
        if (l1d_bus.wstrb[b]) memory_bytes[int'(l1d_bus.awaddr-PA)+b] <= l1d_bus.wdata[b*8+:8];
      end
    end
  end

  task automatic operation(input logic [5:0] op, input bit load, store, atomic_op,
                           input logic [XLEN-1:0] addr, operand, expected,
                           input int expected_fault = 0);
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = load;
    dispatch[0].uop.execute.memory.store = store;
    dispatch[0].uop.execute.memory.atomic = atomic_op;
    dispatch[0].uop.execute.int_op.alu = op;
    dispatch[0].uop.execute.int_op.word = atomic_op;
    dispatch[0].uop.rd = 5;
    dispatch[0].prd = 9;
    dispatch[0].dest = $bits(dispatch[0].dest)'(owner);
    dispatch[0].op1 = addr;
    dispatch[0].op2 = operand;
    cmu_bcast.rob_head = $bits(cmu_bcast.rob_head)'(owner);
    disp_ioq.accept[0] = 1;
    tick(1);
    disp_ioq.accept[0] = 0;
    for (int n = 0; n < 200 && !exu_ioq_bcast.valid; n++) tick(1);
    check(exu_ioq_bcast.valid && exu_ioq_bcast.trap == (expected_fault != 0), $sformatf(
          "translated completion missing case=%0d op=%h cause=%h state=%h",
          cases,
          op,
          exu_ioq_bcast.cause,
          cache.l1d_state
          ));
    if (expected_fault != 0) begin
      check(exu_ioq_bcast.cause == XLEN'(expected_fault) && exu_ioq_bcast.tval == addr,
            "translated fault lost its cause or original virtual tval at completion");
    end else begin
      check(exu_ioq_bcast.result == expected, $sformatf(
            "translated op=%h returned %h, expected %h", op, exu_ioq_bcast.result, expected));
    end
    if (store) begin
      check(exu_ioq_bcast.wen && exu_ioq_bcast.sq_waddr == PA,
            "translated atomic lost its store handoff");
    end
    tick(1);
    if (store) begin
      rou_lsu.dest = $bits(rou_lsu.dest)'(owner);
      rou_lsu.sq_vaddr = addr;
      rou_lsu.valid = 1;
      rou_lsu.store = 1;
      tick(1);
      rou_lsu.valid = 0;
      rou_lsu.store = 0;
      for (int n = 0; n < 100 && !rou_lsu.sq_empty; n++) tick(1);
      check(rou_lsu.sq_empty, "translated atomic store did not drain");
    end
    tick(4);
    check(!exu_ioq_bcast.valid, "translated operation completed twice");
    owner++;
    cases++;
  endtask

  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b1);
    producer = '0;
    foreach (dispatch[i]) dispatch[i] = '0;
    disp_ioq.accept[0] = 0;
    disp_ioq.accept[1] = 0;
    fpr.ioq_rdata = 0;
    fpr.ioq_rvalid = 1'b1;
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
    for (int b = 0; b < 64; b++) memory_bytes[b] = 0;
    memory_bytes[0] = 7;
    for (int b = 0; b < 16; b++) memory_bytes[16+b] = 8'((b + 1) * 17);
    operation(`RAPT_ATO_LR__, 1, 0, 1, VA, 0, 7);
    check(exu_l1d.reservation_valid && exu_l1d.reservation == PA,
          "LR reserved its VA instead of its PA");
    operation(`RAPT_ATO_SC__, 0, 1, 1, VA, 9, 0);
    check(!exu_l1d.reservation_valid, "SC retained its reservation");
    operation(`RAPT_ALU_LW__, 1, 0, 0, VA, 0, 9);
    operation(`RAPT_ATO_ADD_, 1, 1, 1, VA, 3, 9);
    operation(`RAPT_ALU_LW__, 1, 0, 0, VA, 0, 12);
    operation(`RAPT_ALU_LW__, 1, 0, 0, VA + 16 + XLEN / 8 - 1, 0,
              XLEN == 64 ? XLEN'(64'hffffffffbbaa9988) : XLEN'('h77665544));
    // A resident translation and cached word must not bypass PMP. Observe
    // cause and tval at the real IOQ completion, not only the L1D trap owner.
    pmp_update.cfg_r = 0;
    pmp_update.cfg_we = 1;
    tick(1);
    pmp_update.cfg_we = 0;
    operation(`RAPT_ALU_LW__, 1, 0, 0, VA, 0, 0, 5);
    cache.u_dtlb.valid[TlbSlot] = 1;
    cache.u_dtlb.verdicts[TlbSlot] = '0;
    cache.u_dtlb.ptes[TlbSlot][3] = 1;
    operation(`RAPT_ALU_LW__, 1, 0, 0, VA, 0, 0, 13);
    $display("PASS: translated IOQ/SQ/L1D LR/SC/AMO/split XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule
