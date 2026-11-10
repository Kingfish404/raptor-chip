// =============================================================================
// rapt_tb_chip -- testbench for the pad-level chip top, memory behind the link
// -----------------------------------------------------------------------------
//   rapt_chip_pads --octal link pins--> rapt_xspi_target --AXI4--> rapt_tb_mem
//
// The same bench takes the behavioral pads (RTL) or a gate netlist of
// rapt_chip_pads (+define+RAPT_TB_GLS, +define+RAPT_TB_SDF), so only pins are
// used unless RAPT_TB_EBREAK_HALT selects the RTL-only ebreak tap.
// Plusargs match rapt_tb_top: +IMG= +MROM= +FLASH= +MAX_CYCLES= +WAVE= +SDF=
// +SDF_MTM=. Also: +JTAG_IDCODE reads the TAP IDCODE over the pins after reset;
// +LINK_TRACE prints every board-side AXI transaction.
// =============================================================================
`timescale 1ns / 1ps

module rapt_tb_chip;
  parameter realtime CLK_PERIOD = 10.0;
  parameter realtime TARGET_PERIOD = 5.0;
  parameter realtime TCK_PERIOD = 100.0;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [31:0] ExpectedIdcode = 32'h1000_1913;

  logic clock = 1'b0;
  logic target_clock = 1'b0;
  logic reset_n = 1'b0;
  logic reset;
  always #(CLK_PERIOD / 2.0) clock = ~clock;
  always #(TARGET_PERIOD / 2.0) target_clock = ~target_clock;
  assign reset = !reset_n;

  initial begin
    repeat (20) @(posedge clock);
    #1 reset_n = 1'b1;
  end

  logic jtag_tck = 1'b0, jtag_tms = 1'b1, jtag_tdi = 1'b1;
  wire jtag_tdo, sclk, cs_n, diag;
  wire [7:0] dq;
  logic [7:0] target_dq;
  logic target_oe;
  assign dq = target_oe ? target_dq : 8'hzz;

  // This fixture attaches a bridge. Shorten unused Flash startup timers, then
  // select the bridge through the actual pad JTAG path before running its ROM.
  rapt_chip_pads #(
      .FlashPowerupCycles(1),
      .FlashResetCycles(1),
      .FlashRecoveryCycles(1),
      .FlashPollCycles(1000)
  ) u_dut (
      .pad_clk(clock),
      .pad_reset_n(reset_n),
      .pad_irq(1'b0),
      .pad_xspi_sclk(sclk),
      .pad_xspi_cs_n(cs_n),
      .pad_xspi_dq(dq),
      .pad_jtag_tck(jtag_tck),
      .pad_jtag_tms(jtag_tms),
      .pad_jtag_tdi(jtag_tdi),
      .pad_jtag_tdo(jtag_tdo),
      .pad_diag(diag)
  );

  axi4_if #(.XLEN(XLEN)) board ();

  rapt_xspi_target #(
      .XLEN(XLEN)
  ) u_target (
      .clock(target_clock),
      .reset(reset),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .status_poll_o(),
      .axi(board)
  );

  logic sim_finish;
  logic [31:0] sim_exit_code;

  rapt_tb_mem #(
      .XLEN(XLEN),
      .IDW(4)
  ) u_mem (
      .clock(target_clock),
      .reset(reset),
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
      .rdata(board.rdata),
      .rresp(board.rresp),
      .rlast(board.rlast),
      .rvalid(board.rvalid),
      .rready(board.rready),
      .sim_finish(sim_finish),
      .sim_exit_code(sim_exit_code)
  );

  initial begin
    string path;
    int loaded;
    if ($value$plusargs("MROM=%s", path)) loaded = u_mem.load_bin(path, 32'h2000_0000);
    if ($value$plusargs("FLASH=%s", path)) loaded = u_mem.load_bin(path, 32'h3000_0000);
    if ($value$plusargs("IMG=%s", path)) loaded = u_mem.load_bin(path, 32'h8000_0000);
  end

`ifdef RAPT_TB_SDF
  initial begin
    string sdf_path, sdf_mtm;
    if ($value$plusargs("SDF=%s", sdf_path)) begin
      if (!$value$plusargs("SDF_MTM=%s", sdf_mtm)) sdf_mtm = "MAXIMUM";
      $sdf_annotate(sdf_path, u_dut,, "rapt_tb_sdf.log", sdf_mtm);
    end
  end
`endif

  initial begin
    int wave_en;
    if ($value$plusargs("WAVE=%d", wave_en) && wave_en != 0) begin
      $dumpfile("rapt_tb_chip.vcd");
      $dumpvars(0, rapt_tb_chip);
    end
  end

  bit link_trace = $test$plusargs("LINK_TRACE");
  always @(posedge target_clock)
    if (link_trace) begin
      if (board.arvalid && board.arready)
        $display(
            "[link] %0t AR %h len=%0d size=%0d", $time, board.araddr, board.arlen, board.arsize
        );
      if (board.rvalid && board.rready)
        $display("[link] %0t R  %h resp=%0d last=%b", $time, board.rdata, board.rresp, board.rlast);
      if (board.awvalid && board.awready)
        $display(
            "[link] %0t AW %h len=%0d size=%0d", $time, board.awaddr, board.awlen, board.awsize
        );
      if (board.wvalid && board.wready)
        $display("[link] %0t W  %h strb=%b", $time, board.wdata, board.wstrb);
      if (board.bvalid && board.bready) $display("[link] %0t B  resp=%0d", $time, board.bresp);
    end

  // DIAG must toggle at clock / 1024 once reset is released.
  int diag_edges = 0;
  always @(posedge diag) diag_edges++;

  task automatic jtag_cycle(input logic tms, input logic tdi, output logic tdo);
    jtag_tms = tms;
    jtag_tdi = tdi;
    #(TCK_PERIOD / 2.0);
    tdo = jtag_tdo;
    jtag_tck = 1'b1;
    #(TCK_PERIOD / 2.0);
    jtag_tck = 1'b0;
  endtask

  // Reset the TAP, then shift the 32-bit IDCODE selected by reset.
  task automatic jtag_read_idcode(output logic [31:0] idcode);
    logic tdo;
    repeat (6) jtag_cycle(1'b1, 1'b1, tdo);
    jtag_cycle(1'b0, 1'b1, tdo);
    jtag_cycle(1'b1, 1'b1, tdo);
    jtag_cycle(1'b0, 1'b1, tdo);
    jtag_cycle(1'b0, 1'b1, tdo);
    for (int i = 0; i < 32; i++) begin
      jtag_cycle(i == 31, 1'b1, tdo);
      idcode[i] = tdo;
    end
    jtag_cycle(1'b1, 1'b1, tdo);
    jtag_cycle(1'b0, 1'b1, tdo);
  endtask

  bit boot_ready = 0;
  task automatic boot_scan(input bit instruction, input logic [40:0] value, input int width,
                           output logic [40:0] result);
    logic discarded;
    jtag_cycle(1, 0, discarded);
    if (instruction) jtag_cycle(1, 0, discarded);
    jtag_cycle(0, 0, discarded);
    jtag_cycle(0, 0, discarded);
    result = 0;
    for (int i = 0; i < width; i++) jtag_cycle(i == width - 1, value[i], result[i]);
    jtag_cycle(1, 0, discarded);
    jtag_cycle(0, 0, discarded);
  endtask

  task automatic boot_dmi(input logic [6:0] address, input logic [31:0] value,
                          input logic [1:0] operation, output logic [31:0] result);
    logic [40:0] shifted;
    boot_scan(1, 41'h11, 5, shifted);
    boot_scan(0, {address, value, operation}, 41, shifted);
    boot_scan(0, 0, 41, shifted);
    if (shifted[1:0] != 0) $fatal(1, "Boot DMI failed");
    result = shifted[33:2];
  endtask

  initial begin
    logic [31:0] value;
    @(posedge reset_n);
    #(TCK_PERIOD * 4);
    jtag_read_idcode(value);
    if (value != ExpectedIdcode) $fatal(1, "Boot IDCODE failed");
    boot_dmi(7'h10, 1, 2, value);
    boot_dmi(7'h10, 32'h80000001, 2, value);
    do boot_dmi(7'h11, 0, 1, value); while ((value & 32'h300) != 32'h300);
    boot_dmi(7'h38, 32'h40000, 2, value);
    boot_dmi(7'h39, 32'h00100808, 2, value);
    boot_dmi(7'h3c, 0, 2, value);
    do boot_dmi(7'h38, 0, 1, value); while (value[21]);
    if (value[14:12] != 0) $fatal(1, "Boot SBA failed");
    boot_dmi(7'h10, 32'h80000003, 2, value);
    do boot_dmi(7'h11, 0, 1, value); while ((value & 32'h3300) != 32'h3000);
    boot_dmi(7'h10, 32'h80000001, 2, value);
    do boot_dmi(7'h11, 0, 1, value); while ((value & 32'h3300) != 32'h300);
    boot_dmi(7'h10, 32'h40000001, 2, value);
    boot_ready = 1;
  end

  initial
    if ($test$plusargs("JTAG_IDCODE")) begin
      logic [31:0] idcode;
      wait (boot_ready);
      #(TCK_PERIOD * 4);
      jtag_read_idcode(idcode);
      if (idcode !== ExpectedIdcode) $fatal(1, "JTAG IDCODE %h, want %h", idcode, ExpectedIdcode);
      $display("[rapt_tb_chip] JTAG IDCODE %h ok", idcode);
    end

  longint unsigned cycles = 0;
  longint unsigned max_cycles = 100_000_000;
  initial if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100_000_000;

`ifdef RAPT_TB_EBREAK_HALT
  logic ebreak_commit;
  always_comb begin
    ebreak_commit = 1'b0;
    for (int s = 0; s < rapt_pkg::CommitWidth; s++)
    ebreak_commit |= u_dut.u_chip.u_cluster.core.backend.rou_cmu.slot[s].ebreak;
  end
`endif

  task automatic finish_report(input logic good, input logic [31:0] code);
    if (diag_edges == 0 && cycles > 4096) $fatal(1, "DIAG never toggled");
    if (good) $display("[rapt_tb_chip] HIT GOOD TRAP after %0d cycles", cycles);
    else $display("[rapt_tb_chip] HIT BAD TRAP (code=%0d) after %0d cycles", code, cycles);
    $finish;
  endtask

  always @(posedge clock) begin
    cycles <= cycles + 1;
    if (cycles >= max_cycles) begin
      $display("[rapt_tb_chip] TIMEOUT after %0d cycles", cycles);
      $fatal(1, "timeout");
    end
`ifdef RAPT_TB_EBREAK_HALT
    if (reset_n && ebreak_commit) finish_report(1'b1, 32'd0);
`endif
    if (sim_finish) finish_report(sim_exit_code == 0, sim_exit_code);
  end
endmodule
