`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

module tb_tlb_ppn_fault;
  localparam int XLEN = `RAPT_XLEN;
  localparam int PpnBits = XLEN == 64 ? 44 : 22;
  localparam logic [XLEN-1:0] VA = 'h40001000;
  localparam logic [XLEN-1:0] PA = 'h80001000;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
  `include "tb_common.svh"
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS
  logic [XLEN-1:0] leaf;
  bit bare = 0;
  int cases = 0;
  assign l1d_bus.rready = 1;
  assign l1d_bus.idle = 1;
  assign l1d_bus.rerr = 0;
  assign l1d_bus.ptw_rerr = 0;
  assign l1d_bus.rlast = 1;
  assign l1d_bus.r_mshr = 0;
  assign l1d_bus.r_mshr_id = 0;
  assign l1d_bus.wready = 1;
  assign l1d_bus.werr = 0;
  assign l1d_bus.difftest_skip = 0;
  assign l1d_bus.posted_busy = 0;
  assign l1d_bus.posted_error = 0;
  assign l1d_bus.posted_error_addr = 0;
  always @(posedge clock) begin
    l1d_bus.rvalid <= 0;
    l1d_bus.ptw_rvalid <= 0;
    if (!reset && l1d_bus.arvalid && l1d_bus.rready) begin
      if (l1d_bus.ar_ptw) begin
        l1d_bus.rdata <= leaf;
        l1d_bus.ptw_rvalid <= 1;
      end else begin
        check(bare && l1d_bus.araddr == PA, "unsupported PPN escaped as a low-memory read");
        l1d_bus.rdata <= 'h12345678;
        l1d_bus.rvalid <= 1;
      end
    end
  end
  task automatic fence;
    @(negedge clock);
    cmu_bcast.fence_time = 1;
    cmu_bcast.sfence_valid = 1;
    cmu_bcast.sfence_all_vpn = 1;
    cmu_bcast.sfence_all_asid = 1;
    tick(1);
    @(negedge clock);
    cmu_bcast.fence_time = 0;
    cmu_bcast.sfence_valid = 0;
  endtask
  task automatic target(input bit store, input int high_bit, input logic [7:0] flags,
                        input int expected_cause, input int kind = 0);
    fence();
    csr_bcast.satp_ppn = `RAPT_CSR_SATP_PPN_W'('h80000)
        | (kind == 1 ? (`RAPT_CSR_SATP_PPN_W'(1) << high_bit) : '0);
    leaf = (XLEN'('h80000) << 10) | (kind == 1 ? XLEN'(0) : (XLEN'(1) << (high_bit + 10))) | XLEN'(flags);
    @(negedge clock);
    if (store) begin
      exu_l1d.mmu_en = 1;
      exu_l1d.vaddr = VA;
      exu_l1d.walu = `RAPT_SW_WSTRB;
      exu_l1d.valid = 1;
    end else begin
      lsu_l1d.raddr = VA;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1;
    end
    tick(1);
    for (int n = 0; n < 100 && !(store ? exu_l1d.ready : lsu_l1d.rready); n++) tick(1);
    check(store ? exu_l1d.ready : lsu_l1d.rready, "high-PPN translation timed out");
    check(store ? exu_l1d.trap : lsu_l1d.trap, "high PPN did not fault");
    check((store ? exu_l1d.cause : lsu_l1d.cause) == XLEN'(expected_cause),
          "high PPN changed access/page-fault priority");
    check(dut.rec_addr == VA, "high PPN changed virtual tval");
    check(dut.u_dtlb.valid == 0, "unsupported PPN entered compact data TLB");
    @(negedge clock);
    exu_l1d.valid = 0;
    exu_l1d.mmu_en = 0;
    lsu_l1d.rvalid = 0;
    tick(3);
    cases++;
  endtask
  task automatic bare_load(input logic [XLEN-1:0] address, input bit denied);
    @(negedge clock);
    lsu_l1d.raddr = address;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    tick(1);
    for (int n = 0; n < 100 && !lsu_l1d.rready; n++) tick(1);
    check(lsu_l1d.rready && lsu_l1d.trap == denied, "Bare alias/fault changed");
    if (denied) check(lsu_l1d.cause == 5 && dut.rec_addr == address, "Bare cause/tval changed");
    else check(lsu_l1d.rdata == 'h12345678, "Bare alias returned wrong data");
    @(negedge clock);
    lsu_l1d.rvalid = 0;
    tick(3);
    cases++;
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1d_bus.rvalid = 0;
    l1d_bus.ptw_rvalid = 0;
    l1d_bus.rdata = 0;
    tick(3);
    reset = 0;
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = 1;
    pmp_update.cfg_w = 1;
    pmp_update.mode_off = '1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot = 1;
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80000;
    check($bits(dut.u_dtlb.ptags[0]) == `RAPT_PADDR_BITS - 12, "data TLB stores excess PPN bits");
    for (int bit_idx = `RAPT_PADDR_BITS - 12; bit_idx < PpnBits; bit_idx++) begin
      target(0, bit_idx, 8'hcf, 5);
      target(1, bit_idx, 8'hcf, 7);
      target(0, bit_idx, 8'hc9, 13);  // X-only, MXR=0: page fault wins over high PA.
      target(1, bit_idx, 8'hc3, 15);  // Read-only leaf: store page fault wins.
      target(0, bit_idx, 8'h8f, 13);  // Svade: A=0 remains a page fault.
      target(0, bit_idx, 8'hcf, 5, 1);  // Unsupported SATP root.
      target(1, bit_idx, 8'hcf, 7, 1);
      target(0, bit_idx, 8'h01, 5, 2);  // Unsupported non-leaf PPN.
      target(1, bit_idx, 8'h01, 7, 2);
    end
    bare = 1;
    csr_bcast.dmmu_en = 0;
    csr_bcast.priv = `RAPT_PRIV_M;
    bare_load(PA, 0);
    if (XLEN == 64) begin
      bare_load(XLEN'(64'hffffffff80001000), 0);
      bare_load(XLEN'(64'h0000000180001000), 1);
    end
    $display(
        "PASS: PPN overflow cause/tval/permission priority and Bare aliases XLEN=%0d PA=%0d cases=%0d",
        XLEN, `RAPT_PADDR_BITS, cases);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "PPN fault timeout");
  end
endmodule
