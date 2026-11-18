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
// keeping the memory map + console + finisher behaviour aligned with sim.
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
  // Optional ebreak-based termination (RTL alignment with sim).
  // -----------------------------------------------------------------------------
  // The AM "npc" target (cpu-tests / coremark / microbench) signals completion
  // by committing an ebreak (sim hooks this through DPI npc_exu_ebreak).
  // The DPI-free TB taps the commit-stage ebreak strobe via a cross-module
  // reference so those binaries self-terminate, matching sim's default flow.
  //   * RTL only: the gate netlist (RAPT_TB_GLS) has no such signal, and real
  //     silicon / commercial post-sim must use the finisher MMIO instead.
  //   * Enable with +define+RAPT_TB_EBREAK_HALT (on by default for the RTL
  //     alignment flow). Exit code mirrors sim: ebreak == GOOD.
`ifndef RAPT_TB_GLS
`ifdef RAPT_TB_EBREAK_HALT
  logic ebreak_commit;
`ifdef RAPT_V_EXTENSION
  int vector_issued_count, vector_completed_count, vector_wait_store_cycles;
  int vector_branch_recoveries, vector_poison_issues;
  logic vector_hold_test_done = 1'b0;
  initial begin
    if ($test$plusargs("VECTOR_HOLD")) begin
      do
      @(posedge clock);
      while (reset || !u_dut.cpu.core.backend.vector_issue.valid ||
             !u_dut.cpu.core.backend.vector_command_ready);
      @(negedge clock);
      // Block the core's conditional grant without changing the SQ model.
      force u_dut.cpu.core.backend.vector_head_safe = 1'b0;
      repeat (12) begin
        @(posedge clock);
        if (u_dut.cpu.core.backend.vector_authorized
            || u_dut.cpu.core.backend.vector_response_valid
            || u_dut.cpu.core.backend.vector_mem_valid)
          $fatal(1, "vector work escaped while the head grant was blocked");
      end
      @(negedge clock);
      release u_dut.cpu.core.backend.vector_head_safe;
      vector_hold_test_done = 1'b1;
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      vector_issued_count <= 0;
      vector_completed_count <= 0;
      vector_wait_store_cycles <= 0;
      vector_branch_recoveries <= 0;
      vector_poison_issues <= 0;
    end else begin
      if (u_dut.cpu.core.backend.recovery.redirect_valid
          && u_dut.cpu.core.backend.recovery.target == 32'h8000002c)
        vector_branch_recoveries <= vector_branch_recoveries + 1;
      if (u_dut.cpu.core.backend.vector_issue.valid
          && u_dut.cpu.core.backend.vector_issue.uop.imm == 32'h0280b457)
        vector_poison_issues <= vector_poison_issues + 1;
      if (u_dut.cpu.core.backend.vector_issue.valid && u_dut.cpu.core.backend.vector_command_ready)
        vector_issued_count <= vector_issued_count + 1;
      if (u_dut.cpu.core.backend.vector_response_valid
          && u_dut.cpu.core.backend.g_completion_guard[rapt_pkg::IntegerSystemPort].accepted)
        vector_completed_count <= vector_completed_count + 1;
      if (u_dut.cpu.core.backend.vector_busy && !u_dut.cpu.core.backend.rou_lsu.sq_empty)
        vector_wait_store_cycles <= vector_wait_store_cycles + 1;
    end
  end
`endif
  always_comb begin
    ebreak_commit = 1'b0;
    for (int s = 0; s < rapt_pkg::CommitWidth; s++)
    ebreak_commit |= u_dut.cpu.core.backend.rou_cmu.slot[s].ebreak;
  end
  always_ff @(posedge clock) begin
    if (!reset && ebreak_commit) begin
`ifdef RAPT_V_EXTENSION
      if ($test$plusargs("VECTOR_TRAP")) begin
        if (u_dut.cpu.core.backend.rf[10] != 10 || u_dut.cpu.core.backend.rf[20] != 3
            || vector_issued_count != 4 || vector_completed_count != 4)
          $fatal(
              1,
              "RVV trap program result=%h traps=%h issued=%0d completed=%0d",
              u_dut.cpu.core.backend.rf[10],
              u_dut.cpu.core.backend.rf[20],
              vector_issued_count,
              vector_completed_count
          );
        $display("PASS vector VS/CSR traps=3 and mret");
      end
      if ($test$plusargs("VECTOR_PROGRAM")) begin
        if (u_dut.cpu.core.backend.rf[10] != 10 || vector_issued_count < 9
            || vector_issued_count != vector_completed_count)
          $fatal(
              1,
              "RVV program result=%h issued=%0d completed=%0d",
              u_dut.cpu.core.backend.rf[10],
              vector_issued_count,
              vector_completed_count
          );
        $display("PASS compiled RVV program result=10 issued=%0d completed=%0d",
                 vector_issued_count, vector_completed_count);
      end
      if ($test$plusargs("VECTOR_SMOKE")) begin
        if (u_dut.cpu.core.backend.rf[5] != 3 || u_dut.cpu.core.backend.rf[10] != 12
            || u_dut.cpu.core.backend.rf[11] != 13)
          $fatal(
              1,
              "vector core smoke x5=%h x10=%h x11=%h",
              u_dut.cpu.core.backend.rf[5],
              u_dut.cpu.core.backend.rf[10],
              u_dut.cpu.core.backend.rf[11]
          );
        if (vector_issued_count != 4 || vector_completed_count != 4)
          $fatal(
              1,
              "vector core lifetime issued=%0d completed=%0d",
              vector_issued_count,
              vector_completed_count
          );
        if ($test$plusargs("VECTOR_HOLD") && !vector_hold_test_done)
          $fatal(1, "vector conditional-grant hold was not exercised");
        if (vector_poison_issues != 0 || vector_branch_recoveries == 0)
          $fatal(
              1,
              "wrong-path vector issue=%0d branch recovery=%0d",
              vector_poison_issues,
              vector_branch_recoveries
          );
        $display(
            "PASS vector core x5=3 x10=12 x11=13 issued=%0d completed=%0d store_wait=%0d recovery=%0d",
            vector_issued_count, vector_completed_count, vector_wait_store_cycles,
            vector_branch_recoveries);
      end
`endif
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
  int unsigned retired_this_cycle;
  always_comb begin
    retired_this_cycle = 0;
    for (int s = 0; s < rapt_pkg::CommitWidth; s++)
    retired_this_cycle += u_dut.cpu.core.backend.rou_cmu.slot[s].valid;
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      commit_count <= 64'd0;
    end else begin
      if (retired_this_cycle != 0) commit_count <= commit_count + retired_this_cycle;
      for (int s = 0; s < rapt_pkg::CommitWidth; s++) begin
        if (u_dut.cpu.core.backend.rou_cmu.slot[s].valid && (commit_trace_en != 0))
          $display(
              "[commit_trace] cyc=%0d commit=%0d slot=%0d pc=0x%08h inst=0x%08h npc=0x%08h",
              cyc,
              commit_count + s,
              s,
              u_dut.cpu.core.backend.rou_cmu.slot[s].pc,
              u_dut.cpu.core.backend.rou_cmu.slot[s].inst,
              u_dut.cpu.core.backend.rou_cmu.slot[s].npc
          );
        if ((syscall_trace_en != 0) && u_dut.cpu.core.backend.rou_cmu.slot[s].valid
            && u_dut.cpu.core.backend.rou_cmu.slot[s].inst == 32'h0000_0073)
          $display(
              "[ecall] cyc=%0d slot=%0d pc=0x%08h",
              cyc,
              s,
              u_dut.cpu.core.backend.rou_cmu.slot[s].pc
          );
        if ((fatal_trace_en != 0) && u_dut.cpu.core.backend.rou_cmu.slot[s].valid
            && (u_dut.cpu.core.backend.rou_cmu.slot[s].npc == fatal_pc
                || u_dut.cpu.core.backend.rou_cmu.slot[s].pc == fatal_pc))
          $display(
              "[fatal_trace] cyc=%0d slot=%0d call_pc=0x%08h inst=0x%08h npc=0x%08h",
              cyc,
              s,
              u_dut.cpu.core.backend.rou_cmu.slot[s].pc,
              u_dut.cpu.core.backend.rou_cmu.slot[s].inst,
              u_dut.cpu.core.backend.rou_cmu.slot[s].npc
          );
      end

      if ((trap_trace_en != 0) && u_dut.cpu.core.backend.rou_csr.valid &&
          (u_dut.cpu.core.backend.rou_csr.trap || u_dut.cpu.core.backend.rou_csr.ecall ||
           u_dut.cpu.core.backend.rou_csr.ebreak || u_dut.cpu.core.backend.rou_csr.mret ||
           u_dut.cpu.core.backend.rou_csr.sret)) begin
        $display(
            "[trap_trace] cyc=%0d pc=0x%08h trap=%0d ecall=%0d ebreak=%0d mret=%0d sret=%0d cause=0x%08h tval=0x%08h priv=%0d tvec=0x%08h mtvec=0x%08h mmu_i=%0d mmu_d=%0d",
            cyc, u_dut.cpu.core.backend.rou_csr.pc, u_dut.cpu.core.backend.rou_csr.trap,
            u_dut.cpu.core.backend.rou_csr.ecall, u_dut.cpu.core.backend.rou_csr.ebreak,
            u_dut.cpu.core.backend.rou_csr.mret, u_dut.cpu.core.backend.rou_csr.sret,
            u_dut.cpu.core.backend.rou_csr.cause, u_dut.cpu.core.backend.rou_csr.tval,
            u_dut.cpu.core.csr_bcast.priv, u_dut.cpu.core.csr_bcast.tvec,
            u_dut.cpu.core.csr_bcast.mtvec, u_dut.cpu.core.csr_bcast.immu_en,
            u_dut.cpu.core.csr_bcast.dmmu_en);
      end

      if ((pc_trace_en != 0) && (cyc != 0) && ((cyc % 64'd500000) == 0)) begin
        $display(
            "[pc_trace] heartbeat cyc=%0d commits=%0d v0=%0d pc0=0x%08h inst0=0x%08h npc0=0x%08h ifu_pc=0x%08h ifu_idu_ready=%0d l1i_state=%0d inv=%0d wait_inv=%0d flush=%0d mmu=%0d pmp_fault=%0d hit=%0d hit_next=%0d sram_ready=%0d i_raddr_valid=%0d lsu_store_state=%0d lsu_ma_state=%0d lsu_rvalid=%0d lsu_rready=%0d lsu_wvalid=%0d lsu_wready=%0d l1d_state=%0d l1d_hit=%0d l1d_data_hit=%0d l1d_arvalid=%0d l1d_rvalid=%0d l1d_rready=%0d arvalid=%0d arready=%0d rvalid=%0d rready=%0d",
            cyc, commit_count, u_dut.cpu.core.backend.rou_cmu.slot[0].valid,
            u_dut.cpu.core.backend.rou_cmu.slot[0].pc, u_dut.cpu.core.backend.rou_cmu.slot[0].inst,
            u_dut.cpu.core.backend.rou_cmu.slot[0].npc, u_dut.cpu.core.frontend.ifu.pc_ifu,
            u_dut.cpu.core.frontend.fqu_idu.ready[0],
            u_dut.cpu.core.memory_subsystem.l1i_cache.l1i_state,
            u_dut.cpu.core.memory_subsystem.l1i_cache.invalid_l1i,
            u_dut.cpu.core.memory_subsystem.l1i_cache.wait_invalid,
            u_dut.cpu.core.cmu_bcast.flush_pipe, u_dut.cpu.core.memory_subsystem.l1i_cache.mmu_en,
            u_dut.cpu.core.memory_subsystem.l1i_cache.pmp_fetch_fault,
            u_dut.cpu.core.memory_subsystem.l1i_cache.hit,
            u_dut.cpu.core.memory_subsystem.l1i_cache.hit_next,
            u_dut.cpu.core.memory_subsystem.l1i_cache.sram_data_ready,
            u_dut.cpu.core.memory_subsystem.l1i_cache.raddr_valid,
            u_dut.cpu.core.backend.lsu.u_sq.state_store, u_dut.cpu.core.backend.lsu.u_sq.ma_state,
            u_dut.cpu.core.lsu_l1d.rvalid, u_dut.cpu.core.lsu_l1d.rready,
            u_dut.cpu.core.lsu_l1d.wvalid, u_dut.cpu.core.lsu_l1d.wready,
            u_dut.cpu.core.memory_subsystem.l1d_cache.l1d_state,
            u_dut.cpu.core.memory_subsystem.l1d_cache.tag_hit,
            u_dut.cpu.core.memory_subsystem.l1d_cache.data_hit,
            u_dut.cpu.core.memory_subsystem.l1d_bus.arvalid,
            u_dut.cpu.core.memory_subsystem.l1d_bus.rvalid,
            u_dut.cpu.core.memory_subsystem.l1d_bus.rready, rnp_arvalid, rnp_arready, rnp_rvalid,
            rnp_rready);
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

`include "rapt.svh"
`include "rapt_soc_if.svh"
// Direct AXI composition for RV64; the RNP board adapter is fixed to RV32.
module tb_vector_axi;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  logic core_reset_unused, writeback_error, jtag_tdo_unused;
  logic sim_finish;
  logic [31:0] sim_exit_code;
  axi4_if #(.XLEN(XLEN)) axi ();
  int unsigned cycles, max_cycles, issued, completed, device_reads, device_writes;
  logic [15:0] device_read_mask, device_write_mask, device_read_error_mask;
  logic [15:0] device_write_error_mask;
  int unsigned device_repeat;
  always #5 clock = ~clock;

  rapt dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock(clock),
      .reset(reset),
      .writeback_error_o(writeback_error),
      .core_reset_o(core_reset_unused),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .io_master_arcache(axi.arcache),
      .io_master_arburst(axi.arburst),
      .io_master_arsize(axi.arsize),
      .io_master_arlen(axi.arlen),
      .io_master_arid(axi.arid),
      .io_master_araddr(axi.araddr),
      .io_master_arvalid(axi.arvalid),
      .io_master_arready(axi.arready),
      .io_master_rid(axi.rid),
      .io_master_rlast(axi.rlast),
      .io_master_rdata(axi.rdata),
      .io_master_rresp(axi.rresp),
      .io_master_rvalid(axi.rvalid),
      .io_master_rready(axi.rready),
      .io_master_awcache(axi.awcache),
      .io_master_awburst(axi.awburst),
      .io_master_awsize(axi.awsize),
      .io_master_awlen(axi.awlen),
      .io_master_awid(axi.awid),
      .io_master_awaddr(axi.awaddr),
      .io_master_awvalid(axi.awvalid),
      .io_master_awready(axi.awready),
      .io_master_wlast(axi.wlast),
      .io_master_wdata(axi.wdata),
      .io_master_wstrb(axi.wstrb),
      .io_master_wvalid(axi.wvalid),
      .io_master_wready(axi.wready),
      .io_master_bid(axi.bid),
      .io_master_bresp(axi.bresp),
      .io_master_bvalid(axi.bvalid),
      .io_master_bready(axi.bready),
      .io_interrupt(vector_irq),
      .ext_irq_i('0),
      .jtag_trst_n(1'b0),
      .jtag_tck_en(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b0),
      .jtag_tdo(jtag_tdo_unused)
  );

  rapt_tb_mem #(
      .XLEN(XLEN)
  ) memory_model (
      .clock(clock),
      .reset(reset),
      .awid(axi.awid),
      .awaddr(axi.awaddr),
      .awlen(axi.awlen),
      .awsize(axi.awsize),
      .awburst(axi.awburst),
      .awvalid(axi.awvalid),
      .awready(axi.awready),
      .wdata(axi.wdata),
      .wstrb(axi.wstrb),
      .wlast(axi.wlast),
      .wvalid(axi.wvalid),
      .wready(axi.wready),
      .bid(axi.bid),
      .bresp(axi.bresp),
      .bvalid(axi.bvalid),
      .bready(axi.bready),
      .arid(axi.arid),
      .araddr(axi.araddr),
      .arlen(axi.arlen),
      .arsize(axi.arsize),
      .arburst(axi.arburst),
      .arvalid(axi.arvalid),
      .arready(axi.arready),
      .rid(axi.rid),
      .rdata(axi.rdata),
      .rresp(axi.rresp),
      .rlast(axi.rlast),
      .rvalid(axi.rvalid),
      .rready(axi.rready),
      .sim_finish(sim_finish),
      .sim_exit_code(sim_exit_code)
  );

  logic vector_irq, vector_irq_injected;
  always_ff @(posedge clock) begin
    if (reset) begin
      vector_irq <= 1'b0;
      vector_irq_injected <= 1'b0;
    end else begin
`ifdef RAPT_V_EXTENSION
      if ($test$plusargs("VECTOR_INTERRUPT")) begin
        if (!vector_irq_injected && dut.core.backend.vector_authorized
          && dut.core.backend.vector_busy && dut.core.backend.csrs.mstatus_mie) begin
          vector_irq <= 1'b1;
          vector_irq_injected <= 1'b1;
        end else if (dut.core.backend.csrs.trap_enter && dut.core.backend.rou_csr.valid
                   && dut.core.backend.csrs.trap_cause[XLEN-1]) begin
          vector_irq <= 1'b0;
        end
      end
`endif
    end
  end

  initial begin
    string image_path, boot_path;
    int loaded;
    if (!$value$plusargs("IMG=%s", image_path)) $fatal(1, "+IMG required");
    if (!$value$plusargs("MROM=%s", boot_path)) $fatal(1, "+MROM required");
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100000;
    if (!$value$plusargs("VD_READ_MASK=%h", device_read_mask)) device_read_mask = 0;
    if (!$value$plusargs("VD_WRITE_MASK=%h", device_write_mask)) device_write_mask = 0;
    if (!$value$plusargs("VD_READ_ERROR_MASK=%h", device_read_error_mask))
      device_read_error_mask = 0;
    if (!$value$plusargs("VD_WRITE_ERROR_MASK=%h", device_write_error_mask))
      device_write_error_mask = 0;
    if (!$value$plusargs("VD_REPEAT=%d", device_repeat)) device_repeat = 1;
    if (device_repeat == 0) $fatal(1, "VD_REPEAT must be nonzero");
    loaded = memory_model.load_bin(image_path, 32'h80000000);
    if (loaded <= 0) $fatal(1, "cannot load program");
    loaded = memory_model.load_bin(boot_path, 32'h20000000);
    if (loaded <= 0) $fatal(1, "cannot load boot ROM");
    repeat (5) @(negedge clock);
    reset = 0;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      cycles <= 0;
      issued <= 0;
      completed <= 0;
      device_reads <= 0;
      device_writes <= 0;
    end else begin
      cycles <= cycles + 1;
      if (axi.arvalid && axi.arready && axi.araddr[31:4] == 28'h1000000)
        device_reads <= device_reads + 1;
      if (axi.awvalid && axi.awready && axi.awaddr[31:4] == 28'h1000000)
        device_writes <= device_writes + 1;
`ifdef RAPT_V_EXTENSION
      if (dut.core.backend.vector_issue.valid && dut.core.backend.vector_command_ready)
        issued <= issued + 1;
      if (dut.core.backend.vector_response_valid
          && dut.core.backend.g_completion_guard[rapt_pkg::IntegerSystemPort].accepted)
        completed <= completed + 1;
`endif
      if (cycles >= max_cycles) $fatal(1, "RVV AXI core timeout after %0d cycles", cycles);
      if ($test$plusargs("VECTOR_ACT4") && cycles[15:0] == 0) begin
        $display("ACT4 progress cycles=%0d issued=%0d completed=%0d pc=%h", cycles, issued,
                 completed, dut.core.backend.rou_cmu.next_pc);
        $fflush();
      end
      if (sim_finish) begin
        if (!$test$plusargs("VECTOR_ACT4") || sim_exit_code != 0 || issued != completed)
          $fatal(
              1,
              "test finisher status=%h issued=%0d completed=%0d",
              sim_exit_code,
              issued,
              completed
          );
        $display("PASS RV%0d ACT4 vector test issued=%0d completed=%0d cycles=%0d", XLEN, issued,
                 completed, cycles);
        $finish;
      end
      for (int s = 0; s < rapt_pkg::CommitWidth; s++) begin
        if (dut.core.backend.rou_cmu.slot[s].ebreak && !$test$plusargs("VECTOR_ACT4")) begin
          if (dut.core.backend.rf[10] != XLEN'(10) || issued != completed)
            $fatal(
                1,
                "RVV AXI result=%h issued=%0d completed=%0d",
                dut.core.backend.rf[10],
                issued,
                completed
            );
          if ($test$plusargs("VECTOR_TRAP") && (dut.core.backend.rf[20] != XLEN'(3) || issued != 4))
            $fatal(1, "RVV AXI trap count=%h issued=%0d", dut.core.backend.rf[20], issued);
          if ($test$plusargs(
                  "VECTOR_DISABLED"
              ) && (rapt_pkg::VectorEnable || issued != 0 || dut.core.backend.rf[20] != XLEN'(4)))
            $fatal(1, "disabled V did not trap all four vector instruction classes");
          if ($test$plusargs("VECTOR_PROGRAM") && issued < 20)
            $fatal(1, "RVV AXI program issued only %0d vector commands", issued);
          if ($test$plusargs("VECTOR_RESTART") && dut.core.backend.rf[20] != XLEN'(1))
            $fatal(1, "RVV AXI restart trap count=%h", dut.core.backend.rf[20]);
          if ($test$plusargs(
                  "VECTOR_INTERRUPT"
              ) && (!vector_irq_injected || dut.core.backend.rf[20] != XLEN'(1)))
            $fatal(1, "vector interrupt was not delivered exactly once");
          if ($test$plusargs("VECTOR_PROBE") && (device_reads != 0 || device_writes != 0))
            $fatal(
                1,
                "vector probe performed %0d device reads, %0d writes",
                device_reads,
                device_writes
            );
`ifdef RAPT_V_EXTENSION
          if ($test$plusargs("VECTOR_DEVICE_TEST")) begin
            for (int i = 0; i < 16; i++) begin
              if (memory_model.vector_device_read_effects[i]
                      != int'(device_read_mask[i]) * device_repeat
                  || memory_model.vector_device_read_attempts[i]
                      != int'(device_read_mask[i]) * device_repeat + int'(device_read_error_mask[i])
                  || memory_model.vector_device_write_effects[i]
                      != int'(device_write_mask[i]) * device_repeat
                  || memory_model.vector_device_write_attempts[i]
                      != int'(device_write_mask[i]) * device_repeat
                          + int'(device_write_error_mask[i]))
                $fatal(
                    1,
                    "device word %0d read effects/attempts=%0d/%0d write=%0d/%0d",
                    i,
                    memory_model.vector_device_read_effects[i],
                    memory_model.vector_device_read_attempts[i],
                    memory_model.vector_device_write_effects[i],
                    memory_model.vector_device_write_attempts[i]
                );
              if (device_write_mask[i]
                  && memory_model.vector_device_write_data[i]
                      != 32'h4141_0000 + 32'(i) + ((device_repeat - 1) << 8))
                $fatal(
                    1, "device word %0d write data=%h", i, memory_model.vector_device_write_data[i]
                );
            end
            $display("PASS side-effect device read=%h write=%h read_errors=%h write_errors=%h",
                     device_read_mask, device_write_mask, device_read_error_mask,
                     device_write_error_mask);
          end
`endif
          $display("PASS RV%0d AXI RVV program issued=%0d completed=%0d cycles=%0d", XLEN, issued,
                   completed, cycles);
          $finish;
        end
      end
    end
  end
endmodule
