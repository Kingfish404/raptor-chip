// =============================================================================
// rapt_tb_top — unified testbench for the raptor chip (soc_pad / rng_chip)
// -----------------------------------------------------------------------------
// One harness, three flows (selected by `define`s passed on the sim cmdline):
//
//   * RTL functional sim ......... default (no define): DUT = rng_chip
//   * Gate-level / post sim ...... +define+RAPT_TB_GLS: DUT = soc_pad netlist
//   * SDF back-annotation ........ +define+RAPT_TB_SDF  (+ +SDF=<file>)
//
// Works under VCS, Xcelium (xrun), Questa (vsim) and Verilator (--binary).
// The chip talks to the outside world over the rnp bus; this TB converts it
// back to AXI4 with `rnp2axi` and attaches the DPI-free `rapt_tb_mem` model,
// keeping the memory map + console + finisher behaviour aligned with nsim.
//
// Runtime plusargs:
//   +IMG=<path>        raw .bin loaded into PMEM   @ 0x80000000 (program)
//   +MROM=<path>       raw .bin loaded into MROM    @ 0x20000000 (trampoline)
//   +FLASH=<path>      raw .bin loaded into FLASH   @ 0x30000000 (optional)
//   +MAX_CYCLES=<n>    watchdog timeout in clock cycles (default 100_000_000)
//   +WAVE              enable waveform dump (VCD: rapt_tb.vcd)
//   +PC_TRACE=<0|1>    print RTL retire/IFU heartbeat diagnostics
//   +TRAP_TRACE         print RTL trap/exception diagnostics
//   +SDF=<path>        SDF file to back-annotate (requires +define+RAPT_TB_SDF)
//   +SDF_MTM=<m>       SDF corner: MINIMUM | TYPICAL | MAXIMUM (default MAXIMUM)
// =============================================================================
`timescale 1ns / 1ps

module rapt_tb_top;

  // Clock period in ns. Override with -pvalue/-G for GLS to match the SDF.
  parameter realtime CLK_PERIOD = 10.0;

  // ---------------------------------------------------------------------------
  // Clock / reset generation.
  // ---------------------------------------------------------------------------
  logic clock = 1'b0;
  logic reset = 1'b1;

  always #(CLK_PERIOD / 2.0) clock = ~clock;

  initial begin
    reset = 1'b1;
    repeat (20) @(posedge clock);
    reset = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // rnp bus between the chip (master end) and the host bridge (slave end).
  //   chip drives:  cdata / arvalid / awvalid / wvalid / wstrb / rready /
  //                 bready / rwstate
  //   host drives:  mdata / arready / rvalid / awready / wready / bvalid
  // ---------------------------------------------------------------------------
  logic [31:0] rnp_mdata;  // host -> chip (read data)
  logic [31:0] rnp_cdata;  // chip -> host (addr / write data)
  logic rnp_arvalid, rnp_arready;
  logic rnp_rvalid, rnp_rready;
  logic rnp_awvalid, rnp_awready;
  logic [3:0] rnp_wstrb;
  logic rnp_wvalid, rnp_wready;
  logic rnp_bvalid, rnp_bready;
  logic [1:0] rnp_rwstate;

  // ---------------------------------------------------------------------------
  // DUT instantiation.
  // ---------------------------------------------------------------------------
`ifdef RAPT_TB_GLS
  // Gate-level netlist top (soc_pad) has bit-blasted rnp pins.
  soc_pad u_dut (
      .pad_rnp_mdata_31 (rnp_mdata[31]),
      .pad_rnp_mdata_30 (rnp_mdata[30]),
      .pad_rnp_mdata_29 (rnp_mdata[29]),
      .pad_rnp_mdata_28 (rnp_mdata[28]),
      .pad_rnp_mdata_27 (rnp_mdata[27]),
      .pad_rnp_mdata_26 (rnp_mdata[26]),
      .pad_rnp_mdata_25 (rnp_mdata[25]),
      .pad_rnp_mdata_24 (rnp_mdata[24]),
      .pad_rnp_mdata_23 (rnp_mdata[23]),
      .pad_rnp_mdata_22 (rnp_mdata[22]),
      .pad_rnp_mdata_21 (rnp_mdata[21]),
      .pad_rnp_mdata_20 (rnp_mdata[20]),
      .pad_rnp_mdata_19 (rnp_mdata[19]),
      .pad_rnp_mdata_18 (rnp_mdata[18]),
      .pad_rnp_mdata_17 (rnp_mdata[17]),
      .pad_rnp_mdata_16 (rnp_mdata[16]),
      .pad_rnp_mdata_15 (rnp_mdata[15]),
      .pad_rnp_mdata_14 (rnp_mdata[14]),
      .pad_rnp_mdata_13 (rnp_mdata[13]),
      .pad_rnp_mdata_12 (rnp_mdata[12]),
      .pad_rnp_mdata_11 (rnp_mdata[11]),
      .pad_rnp_mdata_10 (rnp_mdata[10]),
      .pad_rnp_mdata_9  (rnp_mdata[9]),
      .pad_rnp_mdata_8  (rnp_mdata[8]),
      .pad_rnp_mdata_7  (rnp_mdata[7]),
      .pad_rnp_mdata_6  (rnp_mdata[6]),
      .pad_rnp_mdata_5  (rnp_mdata[5]),
      .pad_rnp_mdata_4  (rnp_mdata[4]),
      .pad_rnp_mdata_3  (rnp_mdata[3]),
      .pad_rnp_mdata_2  (rnp_mdata[2]),
      .pad_rnp_mdata_1  (rnp_mdata[1]),
      .pad_rnp_mdata_0  (rnp_mdata[0]),
      .pad_rnp_cdata_31 (rnp_cdata[31]),
      .pad_rnp_cdata_30 (rnp_cdata[30]),
      .pad_rnp_cdata_29 (rnp_cdata[29]),
      .pad_rnp_cdata_28 (rnp_cdata[28]),
      .pad_rnp_cdata_27 (rnp_cdata[27]),
      .pad_rnp_cdata_26 (rnp_cdata[26]),
      .pad_rnp_cdata_25 (rnp_cdata[25]),
      .pad_rnp_cdata_24 (rnp_cdata[24]),
      .pad_rnp_cdata_23 (rnp_cdata[23]),
      .pad_rnp_cdata_22 (rnp_cdata[22]),
      .pad_rnp_cdata_21 (rnp_cdata[21]),
      .pad_rnp_cdata_20 (rnp_cdata[20]),
      .pad_rnp_cdata_19 (rnp_cdata[19]),
      .pad_rnp_cdata_18 (rnp_cdata[18]),
      .pad_rnp_cdata_17 (rnp_cdata[17]),
      .pad_rnp_cdata_16 (rnp_cdata[16]),
      .pad_rnp_cdata_15 (rnp_cdata[15]),
      .pad_rnp_cdata_14 (rnp_cdata[14]),
      .pad_rnp_cdata_13 (rnp_cdata[13]),
      .pad_rnp_cdata_12 (rnp_cdata[12]),
      .pad_rnp_cdata_11 (rnp_cdata[11]),
      .pad_rnp_cdata_10 (rnp_cdata[10]),
      .pad_rnp_cdata_9  (rnp_cdata[9]),
      .pad_rnp_cdata_8  (rnp_cdata[8]),
      .pad_rnp_cdata_7  (rnp_cdata[7]),
      .pad_rnp_cdata_6  (rnp_cdata[6]),
      .pad_rnp_cdata_5  (rnp_cdata[5]),
      .pad_rnp_cdata_4  (rnp_cdata[4]),
      .pad_rnp_cdata_3  (rnp_cdata[3]),
      .pad_rnp_cdata_2  (rnp_cdata[2]),
      .pad_rnp_cdata_1  (rnp_cdata[1]),
      .pad_rnp_cdata_0  (rnp_cdata[0]),
      .pad_rnp_arvalid  (rnp_arvalid),
      .pad_rnp_arready  (rnp_arready),
      .pad_rnp_rvalid   (rnp_rvalid),
      .pad_rnp_rready   (rnp_rready),
      .pad_rnp_awvalid  (rnp_awvalid),
      .pad_rnp_awready  (rnp_awready),
      .pad_rnp_wstrb_3  (rnp_wstrb[3]),
      .pad_rnp_wstrb_2  (rnp_wstrb[2]),
      .pad_rnp_wstrb_1  (rnp_wstrb[1]),
      .pad_rnp_wstrb_0  (rnp_wstrb[0]),
      .pad_rnp_wvalid   (rnp_wvalid),
      .pad_rnp_wready   (rnp_wready),
      .pad_rnp_bvalid   (rnp_bvalid),
      .pad_rnp_bready   (rnp_bready),
      .pad_rnp_rwstate_1(rnp_rwstate[1]),
      .pad_rnp_rwstate_0(rnp_rwstate[0]),
      .clock            (clock),
      .pad_reset        (reset)
  );
`else
  // RTL functional top with vectorised rnp ports.
  rng_chip u_dut (
      .clock      (clock),
      .rnp_mdata  (rnp_mdata),
      .rnp_cdata  (rnp_cdata),
      .rnp_arvalid(rnp_arvalid),
      .rnp_arready(rnp_arready),
      .rnp_rvalid (rnp_rvalid),
      .rnp_rready (rnp_rready),
      .rnp_awvalid(rnp_awvalid),
      .rnp_awready(rnp_awready),
      .rnp_wstrb  (rnp_wstrb),
      .rnp_wvalid (rnp_wvalid),
      .rnp_wready (rnp_wready),
      .rnp_bvalid (rnp_bvalid),
      .rnp_bready (rnp_bready),
      .rnp_rwstate(rnp_rwstate),
      .reset      (reset)
  );
`endif

  // ---------------------------------------------------------------------------
  // Host bridge: rnp -> AXI4 master.
  // ---------------------------------------------------------------------------
  logic [3:0] axi_arid, axi_rid, axi_awid, axi_bid;
  logic [31:0] axi_araddr, axi_awaddr, axi_rdata, axi_wdata;
  logic [7:0] axi_arlen, axi_awlen;
  logic [2:0] axi_arsize, axi_awsize;
  logic [1:0] axi_arburst, axi_awburst, axi_rresp, axi_bresp;
  logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast;
  logic axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_wlast;
  logic [3:0] axi_wstrb;
  logic axi_bvalid, axi_bready;

  rnp2axi #(
      .XLEN(32)
  ) u_rnp2axi (
      .clk        (clock),
      .reset      (reset),
      .axi_arburst(axi_arburst),
      .axi_arsize (axi_arsize),
      .axi_arlen  (axi_arlen),
      .axi_arid   (axi_arid),
      .axi_araddr (axi_araddr),
      .axi_arvalid(axi_arvalid),
      .axi_arready(axi_arready),
      .axi_rid    (axi_rid),
      .axi_rlast  (axi_rlast),
      .axi_rdata  (axi_rdata),
      .axi_rresp  (axi_rresp),
      .axi_rvalid (axi_rvalid),
      .axi_rready (axi_rready),
      .axi_awburst(axi_awburst),
      .axi_awsize (axi_awsize),
      .axi_awlen  (axi_awlen),
      .axi_awid   (axi_awid),
      .axi_awaddr (axi_awaddr),
      .axi_awvalid(axi_awvalid),
      .axi_awready(axi_awready),
      .axi_wlast  (axi_wlast),
      .axi_wdata  (axi_wdata),
      .axi_wstrb  (axi_wstrb),
      .axi_wvalid (axi_wvalid),
      .axi_wready (axi_wready),
      .axi_bid    (axi_bid),
      .axi_bresp  (axi_bresp),
      .axi_bvalid (axi_bvalid),
      .axi_bready (axi_bready),
      .rnp_mdata  (rnp_mdata),
      .rnp_cdata  (rnp_cdata),
      .rnp_arvalid(rnp_arvalid),
      .rnp_arready(rnp_arready),
      .rnp_rvalid (rnp_rvalid),
      .rnp_rready (rnp_rready),
      .rnp_awvalid(rnp_awvalid),
      .rnp_awready(rnp_awready),
      .rnp_wstrb  (rnp_wstrb),
      .rnp_wvalid (rnp_wvalid),
      .rnp_wready (rnp_wready),
      .rnp_bvalid (rnp_bvalid),
      .rnp_bready (rnp_bready),
      .rnp_rwstate(rnp_rwstate)
  );

  // ---------------------------------------------------------------------------
  // DPI-free memory + MMIO model.
  // ---------------------------------------------------------------------------
  logic        sim_finish;
  logic [31:0] sim_exit_code;

  rapt_tb_mem #(
      .XLEN(32),
      .IDW (4)
  ) u_mem (
      .clock        (clock),
      .reset        (reset),
      .awid         (axi_awid),
      .awaddr       (axi_awaddr),
      .awlen        (axi_awlen),
      .awsize       (axi_awsize),
      .awburst      (axi_awburst),
      .awvalid      (axi_awvalid),
      .awready      (axi_awready),
      .wdata        (axi_wdata),
      .wstrb        (axi_wstrb),
      .wlast        (axi_wlast),
      .wvalid       (axi_wvalid),
      .wready       (axi_wready),
      .bid          (axi_bid),
      .bresp        (axi_bresp),
      .bvalid       (axi_bvalid),
      .bready       (axi_bready),
      .arid         (axi_arid),
      .araddr       (axi_araddr),
      .arlen        (axi_arlen),
      .arsize       (axi_arsize),
      .arburst      (axi_arburst),
      .arvalid      (axi_arvalid),
      .arready      (axi_arready),
      .rid          (axi_rid),
      .rdata        (axi_rdata),
      .rresp        (axi_rresp),
      .rlast        (axi_rlast),
      .rvalid       (axi_rvalid),
      .rready       (axi_rready),
      .sim_finish   (sim_finish),
      .sim_exit_code(sim_exit_code)
  );

  // ---------------------------------------------------------------------------
  // Image loading (before reset is released).
  // ---------------------------------------------------------------------------
  string img_path, mrom_path, flash_path;
  int dummy;

  initial begin
    if ($value$plusargs("MROM=%s", mrom_path)) dummy = u_mem.load_bin(mrom_path, 32'h2000_0000);
    if ($value$plusargs("FLASH=%s", flash_path)) dummy = u_mem.load_bin(flash_path, 32'h3000_0000);
    if ($value$plusargs("IMG=%s", img_path)) dummy = u_mem.load_bin(img_path, 32'h8000_0000);
    else $display("[rapt_tb_top] NOTE: no +IMG=<bin> given; PMEM is empty");
  end

  // ---------------------------------------------------------------------------
  // SDF back-annotation (gate-level only). Verilator ignores $sdf_annotate.
  // ---------------------------------------------------------------------------
`ifdef RAPT_TB_SDF
  string sdf_path, sdf_mtm;
  initial begin
    if ($value$plusargs("SDF=%s", sdf_path)) begin
      if (!$value$plusargs("SDF_MTM=%s", sdf_mtm)) sdf_mtm = "MAXIMUM";
      $display("[rapt_tb_top] SDF annotate '%s' (%s) -> u_dut", sdf_path, sdf_mtm);
      $sdf_annotate(sdf_path, u_dut,, "rapt_tb_sdf.log", sdf_mtm);
    end else begin
      $display("[rapt_tb_top] WARN: RAPT_TB_SDF defined but no +SDF=<file> given");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Waveform dump.
  // ---------------------------------------------------------------------------
  initial begin
    int wave_en;
    if ($value$plusargs("WAVE=%d", wave_en) && (wave_en != 0)) begin
`ifdef RAPT_TB_FSDB
      $fsdbDumpfile("rapt_tb.fsdb");
      $fsdbDumpvars(0, rapt_tb_top);
`else
      $dumpfile("rapt_tb.vcd");
      $dumpvars(0, rapt_tb_top);
`endif
    end
  end

  // ---------------------------------------------------------------------------
  // Optional ebreak-based termination (RTL alignment with nsim).
  // -----------------------------------------------------------------------------
  // The AM "npc" target (cpu-tests / coremark / microbench) signals completion
  // by committing an ebreak (nsim hooks this through DPI npc_exu_ebreak).
  // The DPI-free TB taps the commit-stage ebreak strobe via a cross-module
  // reference so those binaries self-terminate, matching nsim's default flow.
  //   * RTL only: the gate netlist (RAPT_TB_GLS) has no such signal, and real
  //     silicon / commercial post-sim must use the finisher MMIO instead.
  //   * Enable with +define+RAPT_TB_EBREAK_HALT (on by default for the RTL
  //     alignment flow). Exit code mirrors nsim: ebreak == GOOD.
`ifndef RAPT_TB_GLS
`ifdef RAPT_TB_EBREAK_HALT
  logic ebreak_commit;
  assign ebreak_commit = u_dut.cpu.core.rou_cmu.ebreak_a | u_dut.cpu.core.rou_cmu.ebreak_b;
  always_ff @(posedge clock) begin
    if (!reset && ebreak_commit) begin
      $display("[rapt_tb_top] HIT GOOD TRAP (ebreak) after %0d cycles", cyc);
      $finish;
    end
  end
`endif
`endif

  // ---------------------------------------------------------------------------
  // Exit + watchdog.
  // ---------------------------------------------------------------------------
  longint unsigned max_cycles;
  longint unsigned cyc;
  int pc_trace_en;
  int commit_trace_en;
  int syscall_trace_en;
  int trap_trace_en;
  logic [31:0] fatal_pc;
  int fatal_trace_en;

  initial begin
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 64'd100_000_000;
    if (!$value$plusargs("PC_TRACE=%d", pc_trace_en)) pc_trace_en = 0;
    if (!$value$plusargs("COMMIT_TRACE=%d", commit_trace_en)) commit_trace_en = 0;
    syscall_trace_en = $test$plusargs("SYSCALL_TRACE");
    trap_trace_en = $test$plusargs("TRAP_TRACE");
    fatal_trace_en = $value$plusargs("FATAL_PC=%h", fatal_pc);
  end

`ifndef RAPT_TB_GLS
  longint unsigned commit_count;
  always_ff @(posedge clock) begin
    if (reset) begin
      commit_count <= 64'd0;
    end else begin
      if (u_dut.cpu.core.rou_cmu.valid_a) begin
        commit_count <= commit_count + 64'd1 + (u_dut.cpu.core.rou_cmu.valid_b ? 64'd1 : 64'd0);
      end
      if (u_dut.cpu.core.rou_cmu.valid_a && (commit_trace_en != 0)) begin
        $display("[pc_trace] cyc=%0d commit=%0d pc_a=0x%08h inst_a=0x%08h npc_a=0x%08h pc_b=0x%08h inst_b=0x%08h npc_b=0x%08h vb=%0d",
                 cyc, commit_count, u_dut.cpu.core.rou_cmu.pc_a,
                 u_dut.cpu.core.rou_cmu.inst_a, u_dut.cpu.core.rou_cmu.npc_a,
                 u_dut.cpu.core.rou_cmu.pc_b, u_dut.cpu.core.rou_cmu.inst_b,
                 u_dut.cpu.core.rou_cmu.npc_b, u_dut.cpu.core.rou_cmu.valid_b);
      end

      if (syscall_trace_en != 0) begin
        if (u_dut.cpu.core.rou_cmu.valid_a && u_dut.cpu.core.rou_cmu.inst_a == 32'h0000_0073)
          $display("[ecall] cyc=%0d pc=0x%08h", cyc, u_dut.cpu.core.rou_cmu.pc_a);
`ifdef RAPT_DUAL_ISSUE
        if (u_dut.cpu.core.rou_cmu.valid_b && u_dut.cpu.core.rou_cmu.inst_b == 32'h0000_0073)
          $display("[ecall] cyc=%0d pc=0x%08h", cyc, u_dut.cpu.core.rou_cmu.pc_b);
`endif
      end

      if ((trap_trace_en != 0) && u_dut.cpu.core.rou_csr.valid &&
          (u_dut.cpu.core.rou_csr.trap || u_dut.cpu.core.rou_csr.ecall ||
           u_dut.cpu.core.rou_csr.ebreak || u_dut.cpu.core.rou_csr.mret ||
           u_dut.cpu.core.rou_csr.sret)) begin
        $display("[trap_trace] cyc=%0d pc=0x%08h trap=%0d ecall=%0d ebreak=%0d mret=%0d sret=%0d cause=0x%08h tval=0x%08h priv=%0d tvec=0x%08h mtvec=0x%08h mmu_i=%0d mmu_d=%0d",
                 cyc,
                 u_dut.cpu.core.rou_csr.pc,
                 u_dut.cpu.core.rou_csr.trap,
                 u_dut.cpu.core.rou_csr.ecall,
                 u_dut.cpu.core.rou_csr.ebreak,
                 u_dut.cpu.core.rou_csr.mret,
                 u_dut.cpu.core.rou_csr.sret,
                 u_dut.cpu.core.rou_csr.cause,
                 u_dut.cpu.core.rou_csr.tval,
                 u_dut.cpu.core.csr_bcast.priv,
                 u_dut.cpu.core.csr_bcast.tvec,
                 u_dut.cpu.core.csr_bcast.mtvec,
                 u_dut.cpu.core.csr_bcast.immu_en,
                 u_dut.cpu.core.csr_bcast.dmmu_en);
      end

      if ((fatal_trace_en != 0) && u_dut.cpu.core.rou_cmu.valid_a &&
          (u_dut.cpu.core.rou_cmu.npc_a == fatal_pc || u_dut.cpu.core.rou_cmu.pc_a == fatal_pc)) begin
        $display("[fatal_trace] cyc=%0d call_pc=0x%08h inst=0x%08h npc=0x%08h",
                 cyc, u_dut.cpu.core.rou_cmu.pc_a,
                 u_dut.cpu.core.rou_cmu.inst_a,
                 u_dut.cpu.core.rou_cmu.npc_a);
      end

      if ((pc_trace_en != 0) && (cyc != 0) && ((cyc % 64'd500000) == 0)) begin
          $display("[pc_trace] heartbeat cyc=%0d commits=%0d va=%0d pc_a=0x%08h inst_a=0x%08h npc_a=0x%08h ifu_pc=0x%08h ifu_state=%0d ifu_idu_ready=%0d l1i_state=%0d inv=%0d wait_inv=%0d flush=%0d mmu=%0d pmp_fault=%0d hit=%0d hit_next=%0d sram_ready=%0d i_raddr_valid=%0d lsu_store_state=%0d lsu_ma_state=%0d lsu_rvalid=%0d lsu_rready=%0d lsu_wvalid=%0d lsu_wready=%0d l1d_state=%0d l1d_hit=%0d l1d_data_hit=%0d l1d_arvalid=%0d l1d_rvalid=%0d l1d_rready=%0d arvalid=%0d arready=%0d rvalid=%0d rready=%0d",
                     cyc, commit_count, u_dut.cpu.core.rou_cmu.valid_a,
            u_dut.cpu.core.rou_cmu.pc_a,
            u_dut.cpu.core.rou_cmu.inst_a,
            u_dut.cpu.core.rou_cmu.npc_a,
                   u_dut.cpu.core.ifu.pc_ifu, u_dut.cpu.core.ifu.state_ifu,
           u_dut.cpu.core.ifu_idu.ready,
           u_dut.cpu.core.l1i_cache.l1i_state,
           u_dut.cpu.core.l1i_cache.invalid_l1i,
           u_dut.cpu.core.l1i_cache.wait_invalid,
           u_dut.cpu.core.cmu_bcast.flush_pipe,
           u_dut.cpu.core.l1i_cache.mmu_en,
           u_dut.cpu.core.l1i_cache.pmp_fetch_fault,
           u_dut.cpu.core.l1i_cache.hit,
           u_dut.cpu.core.l1i_cache.hit_next,
           u_dut.cpu.core.l1i_cache.sram_data_ready,
           u_dut.cpu.core.l1i_cache.raddr_valid,
           u_dut.cpu.core.lsu.state_store,
           u_dut.cpu.core.lsu.ma_state,
           u_dut.cpu.core.lsu_l1d.rvalid,
           u_dut.cpu.core.lsu_l1d.rready,
           u_dut.cpu.core.lsu_l1d.wvalid,
           u_dut.cpu.core.lsu_l1d.wready,
           u_dut.cpu.core.l1d_cache.l1d_state,
           u_dut.cpu.core.l1d_cache.tag_hit,
           u_dut.cpu.core.l1d_cache.data_hit,
           u_dut.cpu.core.l1d_bus.arvalid,
           u_dut.cpu.core.l1d_bus.rvalid,
           u_dut.cpu.core.l1d_bus.rready,
           rnp_arvalid, rnp_arready, rnp_rvalid, rnp_rready);
      end
    end
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      cyc <= '0;
    end else begin
      cyc <= cyc + 1;
      if (sim_finish) begin
        if (sim_exit_code == 0) $display("[rapt_tb_top] HIT GOOD TRAP after %0d cycles", cyc);
        else $display("[rapt_tb_top] HIT BAD TRAP (code=%0d) after %0d cycles", sim_exit_code, cyc);
        $finish;
      end
      if (cyc >= max_cycles) begin
        $display("[rapt_tb_top] TIMEOUT after %0d cycles", cyc);
        $fatal(1, "watchdog timeout");
      end
    end
  end

endmodule
