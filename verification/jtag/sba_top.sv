`include "rapt.svh"
`include "rapt_soc_if.svh"

// Exercise the production chip's sampled JTAG and octal link. The board model
// is outside ndmreset, just as external RAM and boot ROM are on the real board.
module sba_top (
    input  logic clock,
    input  logic reset,
    input  logic tck,
    input  logic tms,
    input  logic tdi,
    output logic tdo,
    output logic good_trap,
    output logic bad_trap
);
  localparam int Xlen = `RAPT_XLEN;
  logic sclk, cs_n, board_oe, diag;
  logic [7:0] chip_dq, board_dq, dq, chip_oe;
  axi4_if #(.XLEN(Xlen)) board ();
  assign dq = (&chip_oe) ? chip_dq : board_oe ? board_dq : 8'hff;

  // No NOR is attached. Keep the same finite failure path as silicon, with
  // explicit accelerated startup/poll waits so cold recovery fits simulation.
  rapt_chip #(
      .FlashPowerupCycles(2000),
      .FlashResetCycles(32),
      .FlashRecoveryCycles(4000),
      .FlashPollCycles(4096)
  ) dut (
      .clk_i(clock),
      .rst_ni(!reset),
      .irq_i(1'b0),
      .xspi_sclk_o(sclk),
      .xspi_cs_no(cs_n),
      .xspi_ds_i(1'b0),
      .diag_oe_o(),
      .xspi_dq_i(dq),
      .xspi_dq_o(chip_dq),
      .xspi_dq_oe_o(chip_oe),
      .jtag_tck_i(tck),
      .jtag_tms_i(tms),
      .jtag_tdi_i(tdi),
      .jtag_tdo_o(tdo),
      .diag_o(diag)
  );
  rapt_xspi_target #(
      .XLEN(Xlen)
  ) target (
      .clock,
      .reset(reset || dut.boot_flash),
      .sclk_i(sclk),
      .cs_n_i(cs_n || dut.boot_flash),
      .dq_i(dq),
      .dq_o(board_dq),
      .dq_oe_o(board_oe),
      .status_poll_o(),
      .axi(board)
  );
  // The shared memory model logs invalid reads but returns OKAY. Inject the
  // board's decode error on the explicit unmapped test window.
  logic [1:0] memory_rresp;
  logic [Xlen-1:0] memory_rdata;
  logic mmio_read_q;
  int unsigned mmio_reads, mmio_writes;
  localparam logic [Xlen-1:0] TestMmio = Xlen'(32'h1000_1000);
  logic unmapped_read_q;
  always_ff @(posedge clock) begin
    if (reset) unmapped_read_q <= 0;
    else if (board.arvalid && board.arready)
      unmapped_read_q <= board.araddr == Xlen'(32'h6000_0000) || ($test$plusargs(
          "STEP_FAULTS"
      ) && board.arid != 4'hf && board.araddr == Xlen'(32'h8000_3f00));
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      mmio_read_q <= 0;
      mmio_reads  <= 0;
      mmio_writes <= 0;
    end else begin
      if (board.arvalid && board.arready) begin
        mmio_read_q <= board.araddr == TestMmio;
        if (board.araddr == TestMmio && board.arid != 4'hf) mmio_reads <= mmio_reads + 1;
      end
      if (board.awvalid && board.awready && board.awaddr == TestMmio && board.awid != 4'hf)
        mmio_writes <= mmio_writes + 1;
    end
  end
  assign board.rdata = mmio_read_q ? Xlen'(mmio_reads) : memory_rdata;
  assign board.rresp = unmapped_read_q ? 2'b11 : memory_rresp;
  logic sim_finish;
  logic [31:0] sim_exit_code;
  rapt_tb_mem #(
      .XLEN(Xlen)
  ) memory (
      .clock,
      .reset,
      .awid(board.awid),
      .awaddr(board.awaddr),
      .awlen(board.awlen),
      .awsize(board.awsize),
      .awburst(board.awburst),
      .awvalid(board.awvalid),
      .awready(board.awready),
      .wdata(board.wdata),
      .wstrb(board.wstrb),
      .wlast(board.wlast),
      .wvalid(board.wvalid),
      .wready(board.wready),
      .bid(board.bid),
      .bresp(board.bresp),
      .bvalid(board.bvalid),
      .bready(board.bready),
      .arid(board.arid),
      .araddr(board.araddr),
      .arlen(board.arlen),
      .arsize(board.arsize),
      .arburst(board.arburst),
      .arvalid(board.arvalid),
      .arready(board.arready),
      .rid(board.rid),
      .rdata(memory_rdata),
      .rresp(memory_rresp),
      .rlast(board.rlast),
      .rvalid(board.rvalid),
      .rready(board.rready),
      .sim_finish,
      .sim_exit_code
  );
  // Immutable test boot trampoline: LUI t0,0x80000; JALR zero,t0.
  // RAM initially spins; all test program bytes must arrive over JTAG SBA.
  initial begin
    memory.store[32'h2000_0000] = 8'hb7;
    memory.store[32'h2000_0001] = 8'h02;
    memory.store[32'h2000_0002] = 8'h00;
    memory.store[32'h2000_0003] = 8'h80;
    memory.store[32'h2000_0004] = 8'h67;
    memory.store[32'h2000_0005] = 8'h80;
    memory.store[32'h2000_0006] = 8'h02;
    memory.store[32'h2000_0007] = 8'h00;
    memory.store[32'h8000_0000] = 8'h6f;
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      good_trap <= 0;
      bad_trap  <= 0;
    end else if (sim_finish) begin
      if (sim_exit_code == 0) good_trap <= 1;
      else bad_trap <= 1;
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, JTAG_NO_DQ_CONTENTION, chip_oe, !board_oe)
  `RAPT_SVA_IMPLY(clock, reset, JTAG_RESET_DRAIN, dut.u_cluster.ndmreset_active_q,
                  dut.u_cluster.core_bus_idle)

  // Independent witnesses: a fault exits the ROB but does not increment
  // architectural instret. The debugger must not use DPC as a retire counter.
  longint unsigned retire_total, commit_total, admit_total;
  logic halted_prev;
  always_ff @(posedge clock) begin
    if (reset) begin
      retire_total <= 0;
      commit_total <= 0;
      admit_total  <= 0;
      halted_prev  <= 0;
    end else begin
      retire_total <= retire_total + 64'(dut.u_cluster.core.backend.rou_csr.retire_count);
      commit_total <= commit_total + 64'(dut.u_cluster.core.backend.rou.commit_count);
      admit_total  <= admit_total + 64'(dut.u_cluster.core.backend.rou.enqueue_count);
      halted_prev  <= dut.u_cluster.dm_halted;
      if (dut.u_cluster.dm_halted && !halted_prev) begin
        $display(
            "DEBUG_HALT pc=%h retire=%0d commit=%0d admit=%0d cause=%0d prv=%0d reads=%0d writes=%0d",
            dut.u_cluster.dm_halt_pc, retire_total, commit_total, admit_total,
            dut.u_cluster.debug.cause, dut.u_cluster.debug.prv, mmio_reads, mmio_writes);
      end
      if ($test$plusargs("DEBUG_TRACE") && dut.u_cluster.dm_commit_fire) begin
        $display(
            "DEBUG_COMMIT pc=%h npc=%h shadow=%h count=%0d resume=%b step=%b",
            dut.u_cluster.core.backend.rou.rou_cmu.slot[0].pc,
            dut.u_cluster.core.backend.rou.rou_cmu.slot[0].npc,
            dut.u_cluster.core.backend.rou.rob_entry[dut.u_cluster.core.backend.rou.rob_head].npc,
            dut.u_cluster.core.backend.rou.commit_count, dut.u_cluster.debug.resume_valid,
            dut.u_cluster.debug.step);
      end
    end
  end
  // Sample both cache arrays after each register update, including SBA writes.
  always @(negedge clock) begin
    if (!reset && !dut.reset) begin
      if (dut.u_cluster.core.memory_subsystem.l1d_cache.u_data.g_bank[0].u_sram.sram_ctrl_i
          !== dut.sram_ctrl)
        $fatal(1, "SBA SRAM control did not reach L1D");
      if (dut.u_cluster.core.memory_subsystem.l1i_cache.u_data.sram_ctrl_i !== dut.sram_ctrl)
        $fatal(1, "SBA SRAM control did not reach L1I");
      if (!cs_n && (board.araddr == Xlen'(32'h0010_0804) || board.awaddr == Xlen'(32'h0010_0804)))
        $fatal(1, "Local SRAM control reached link pins");
    end
  end
endmodule
