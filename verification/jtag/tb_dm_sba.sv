`include "rapt_debug_if.svh"
`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_dm_sba;
  localparam int Xlen = `RAPT_XLEN;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  logic dmi_req = 0, dmi_wr = 0;
  logic [6:0] dmi_addr = 0;
  logic [31:0] dmi_wdata = 0, dmi_rdata;
  logic [1:0] dmi_resp;
  logic hart_reset = 0, unavailable = 0, halted = 0;
  logic haltreq, resumereq, ndmreset;
  axi4_if #(.XLEN(Xlen)) bus ();

  rapt_debug_if debug ();
  logic ack_allow = 1;
  logic [2:0] halt_cause = 3'd3;
  logic [Xlen-1:0] halt_pc = Xlen'(32'h2000_0000);
  assign debug.resume_ack = debug.resume_valid && ack_allow;
  assign debug.cause = halt_cause;
  assign debug.prv = 2'd3;
  assign debug.fetch_block = 1'b0;

  rapt_dm dut (
      .clock,
      .reset,
      .dmi_req,
      .dmi_wr,
      .dmi_addr,
      .dmi_wdata,
      .dmi_rdata,
      .dmi_resp,
      .halted_i(halted),
      .debug(debug),
      .hart_reset_i(hart_reset),
      .hart_unavailable_i(unavailable),
      .halt_pc_i(halt_pc),
      .haltreq_o(haltreq),
      .resumereq_o(resumereq),
      .ndmreset_o(ndmreset),
      .dbg_gpr_rdata_i('0),
      .dbg_gpr_we_o(),
      .dbg_gpr_addr_o(),
      .dbg_gpr_wdata_o(),
      .sb_axi_araddr(bus.araddr),
      .sb_axi_arid(bus.arid),
      .sb_axi_arlen(bus.arlen),
      .sb_axi_arsize(bus.arsize),
      .sb_axi_arburst(bus.arburst),
      .sb_axi_arcache(bus.arcache),
      .sb_axi_arvalid(bus.arvalid),
      .sb_axi_arready(bus.arready),
      .sb_axi_rdata(bus.rdata),
      .sb_axi_rresp(bus.rresp),
      .sb_axi_rlast(bus.rlast),
      .sb_axi_rvalid(bus.rvalid),
      .sb_axi_rready(bus.rready),
      .sb_axi_awaddr(bus.awaddr),
      .sb_axi_awid(bus.awid),
      .sb_axi_awlen(bus.awlen),
      .sb_axi_awsize(bus.awsize),
      .sb_axi_awburst(bus.awburst),
      .sb_axi_awcache(bus.awcache),
      .sb_axi_awvalid(bus.awvalid),
      .sb_axi_awready(bus.awready),
      .sb_axi_wdata(bus.wdata),
      .sb_axi_wstrb(bus.wstrb),
      .sb_axi_wlast(bus.wlast),
      .sb_axi_wvalid(bus.wvalid),
      .sb_axi_wready(bus.wready),
      .sb_axi_bresp(bus.bresp),
      .sb_axi_bvalid(bus.bvalid),
      .sb_axi_bready(bus.bready)
  );

  task automatic write_dmi(input logic [6:0] addr, input logic [31:0] data);
    @(negedge clock);
    dmi_req = 1;
    dmi_wr = 1;
    dmi_addr = addr;
    dmi_wdata = data;
    @(negedge clock);
    dmi_req = 0;
    dmi_wr  = 0;
  endtask

  task automatic read_dmi(input logic [6:0] addr, output logic [31:0] data);
    @(negedge clock);
    dmi_req  = 1;
    dmi_wr   = 0;
    dmi_addr = addr;
    #1 data = dmi_rdata;
    @(negedge clock);
    dmi_req = 0;
  endtask

  task automatic check_reg(input logic [6:0] addr, input logic [31:0] expected,
                           input logic [31:0] mask = '1);
    logic [31:0] value;
    read_dmi(addr, value);
    if ((value & mask) != (expected & mask))
      $fatal(1, "DMI %h got %h expected %h mask %h", addr, value, expected, mask);
  endtask

  task automatic return_read(input logic [Xlen-1:0] data, input logic [1:0] resp = 0);
    @(negedge clock);
    bus.arready = 1;
    @(negedge clock);
    bus.arready = 0;
    bus.rvalid  = 1;
    bus.rlast   = 1;
    bus.rdata   = data;
    bus.rresp   = resp;
    @(negedge clock);
    bus.rvalid = 0;
  endtask

  task automatic return_write(input logic [1:0] resp = 0, input bit data_first = 0);
    @(negedge clock);
    bus.awready = !data_first;
    bus.wready  = data_first;
    @(negedge clock);
    bus.awready = 0;
    bus.wready  = 0;
    repeat (3) @(negedge clock);
    if (data_first ? !bus.awvalid || bus.wvalid : !bus.wvalid || bus.awvalid)
      $fatal(1, "independent AW/W bookkeeping lost");
    bus.awready = data_first;
    bus.wready  = !data_first;
    @(negedge clock);
    bus.awready = 0;
    bus.wready  = 0;
    bus.bvalid  = 1;
    bus.bresp   = resp;
    @(negedge clock);
    bus.bvalid = 0;
  endtask

  initial begin
    logic [31:0] value;
    bus.arready = 0;
    bus.rvalid  = 0;
    bus.rlast   = 1;
    bus.rdata   = 0;
    bus.rresp   = 0;
    bus.awready = 0;
    bus.wready  = 0;
    bus.bvalid  = 0;
    bus.bresp   = 0;
    repeat (3) @(negedge clock);
    reset = 0;
    write_dmi(7'h10, 1);
    check_reg(7'h38, 32'h2004_0007 | (`RAPT_PADDR_BITS << 5) | (Xlen == 64 ? 8 : 0));
    check_reg(7'h11, 32'h000c_0000, 32'h000c_0000);
    write_dmi(7'h10, 32'h1000_0001);
    check_reg(7'h11, 0, 32'h000c_0000);

    // Byte lane selection and successful autoincrement; AW-before-W.
    write_dmi(7'h38, 32'h0001_0000);
    write_dmi(7'h39, 32'h8000_0103);
    write_dmi(7'h3c, 32'h0000_00a5);
    if (bus.wstrb != (Xlen / 8)'(8) || bus.wdata != Xlen'(32'ha500_0000)) $fatal(1, "byte lanes");
    return_write();
    check_reg(7'h39, 32'h8000_0104);

    // 16-bit read-on-address + read-on-data pipeline, with increment after completion.
    write_dmi(7'h38, 32'h0013_8000);
    write_dmi(7'h39, 32'h8000_0102);
    if (!bus.arvalid || bus.arsize != 1) $fatal(1, "read-on-address");
    check_reg(7'h38, 32'h0020_0000, 32'h0020_0000);
    return_read(Xlen'(32'hbeef_1234));
    read_dmi(7'h3c, value);
    if (value != 32'hbeef || !bus.arvalid) $fatal(1, "read-on-data");
    return_read(Xlen == 64 ? Xlen'(64'h7654_3210_0000_0000) : Xlen'(32'h7654_3210));
    write_dmi(7'h38, 32'h0002_0000);
    check_reg(7'h39, 32'h8000_0106);
    check_reg(7'h3c, 32'h3210);

    // Busy collision must neither overwrite payload nor issue another transaction.
    write_dmi(7'h39, 32'h8000_0200);
    write_dmi(7'h3c, 32'h1234_5678);
    write_dmi(7'h39, 32'h8000_0300);
    write_dmi(7'h3c, 32'hdead_beef);
    check_reg(7'h38, 32'h0060_0000, 32'h0060_0000);
    if (bus.awaddr != Xlen'(32'h8000_0200) || bus.wdata != Xlen'(32'h1234_5678))
      $fatal(1, "busy payload changed");
    return_write(0, 1);  // W-before-AW
    write_dmi(7'h3c, 0);
    if (bus.awvalid) $fatal(1, "busyerror did not inhibit launch");
    write_dmi(7'h38, 32'h0044_0000);

    // Misalignment, unsupported size and sticky W1C errors.
    write_dmi(7'h39, 32'h8000_0001);
    write_dmi(7'h3c, 0);
    check_reg(7'h38, 32'h0000_3000, 32'h0000_7000);
    if (bus.awvalid) $fatal(1, "misaligned AXI request");
    write_dmi(7'h38, 32'h0008_7000);
    write_dmi(7'h3c, 0);
    check_reg(7'h38, 32'h0000_4000, 32'h0000_7000);
    write_dmi(7'h38, 32'h0014_7000);
    write_dmi(7'h39, 32'h6000_0000);
    return_read(0, 3);
    check_reg(7'h38, 32'h0000_2000, 32'h0000_7000);
    check_reg(7'h39, 32'h6000_0000);
    write_dmi(7'h38, 32'h0004_7000);
    write_dmi(7'h3c, 0);
    return_write(2);
    check_reg(7'h38, 32'h0000_7000, 32'h0000_7000);
    write_dmi(7'h38, 32'h0004_7000);

    if (Xlen == 64) begin
      // OpenOCD probes 64-bit abstract transfers to discover RV64.
      halted = 1;
      repeat (2) @(negedge clock);
      write_dmi(7'h04, 32'h89ab_cdef);
      write_dmi(7'h05, 32'h0123_4567);
      write_dmi(7'h17, 32'h0033_07b2);
      write_dmi(7'h04, 0);
      write_dmi(7'h05, 0);
      write_dmi(7'h17, 32'h0032_07b2);
      check_reg(7'h04, 32'h89ab_cdef);
      check_reg(7'h05, 32'h0123_4567);
      write_dmi(7'h10, 32'h4000_0001);
      halted = 0;
      write_dmi(7'h38, 32'h0006_0000);
      write_dmi(7'h39, 32'h8000_0040);
      write_dmi(7'h3d, 32'hfedc_ba98);
      if (bus.awvalid) $fatal(1, "sbdata1 started write");
      write_dmi(7'h3c, 32'h7654_3210);
      if (bus.wdata != Xlen'(64'hfedc_ba98_7654_3210) || bus.wstrb != '1) $fatal(1, "64-bit write");
      return_write();
      write_dmi(7'h38, 32'h0016_0000);
      write_dmi(7'h39, 32'h8000_0040);
      return_read(Xlen'(64'h0123_4567_89ab_cdef));
      check_reg(7'h3d, 32'h0123_4567);
      check_reg(7'h3c, 32'h89ab_cdef);
    end

    if (`RAPT_PADDR_BITS > 32) begin
      write_dmi(7'h38, 32'h0004_0000);
      write_dmi(7'h3a, 5);
      write_dmi(7'h39, 32'h8000_0040);
      write_dmi(7'h3c, 32'h1234_5678);
      if (bus.awaddr != Xlen'(64'h0000_0005_8000_0040)) $fatal(1, "physical address high");
      return_write();
      check_reg(7'h3a, 5);
      write_dmi(7'h3a, 0);
    end

    // A disabled DM must finish an offered transfer rather than orphan AXI.
    write_dmi(7'h38, 32'h0004_0000);
    write_dmi(7'h39, 32'h8000_0000);
    write_dmi(7'h3c, 32'h1234);
    write_dmi(7'h10, 0);
    repeat (3) @(negedge clock);
    if (!bus.awvalid || !bus.wvalid) $fatal(1, "dmactive abandoned AXI");
    return_write();
    repeat (3) @(negedge clock);
    write_dmi(7'h10, 1);
    check_reg(7'h39, 0);
    check_reg(7'h38, 0, 32'h0060_7000);

    // Reset-halt and reset acknowledgement: reset indication wins over ack.
    write_dmi(7'h10, 32'h0000_0009);
    hart_reset  = 1;
    unavailable = 1;
    repeat (3) @(negedge clock);
    if (!haltreq) $fatal(1, "reset halt not held");
    check_reg(7'h11, 32'h0100_3000, 32'h0100_3f00);
    write_dmi(7'h10, 32'h1000_0001);
    check_reg(7'h11, 32'h000c_0000, 32'h000c_0000);
    hart_reset = 0;
    unavailable = 0;
    halted = 1;
    repeat (3) @(negedge clock);
    check_reg(7'h11, 32'h000c_0300, 32'h000c_0f00);
    write_dmi(7'h10, 32'h1000_0001);
    check_reg(7'h11, 0, 32'h000c_0000);
    // DPC capture uses actual halt edges, independent of the request latch.
    // A deliberately stalled resume must hold the PC and keep dispatch stopped.
    ack_allow = 0;
    write_dmi(7'h04, 32'hffff_ffff);
    write_dmi(7'h17, 32'h0023_07b0);
    write_dmi(7'h17, 32'h0022_07b0);
    check_reg(7'h04, 32'h4000_b947);
    write_dmi(7'h04, 32'h8000_0103);
    write_dmi(7'h17, 32'h0023_07b1);
    write_dmi(7'h10, 32'h4000_0001);
    repeat (5) begin
      @(negedge clock);
      if (!haltreq || !debug.resume_valid || debug.resume_pc != 'h8000_0102 || debug.step)
        $fatal(1, "resume did not hold until redirect acknowledgement");
    end
    ack_allow = 1;
    repeat (2) @(negedge clock);
    halted = 0;
    if (haltreq || !debug.step) $fatal(1, "redirect ack did not release single-step");
    check_reg(7'h11, 32'h0003_0000, 32'h0003_0000);
    halt_pc = Xlen'(32'h8000_0104);
    halt_cause = 4;
    halted = 1;
    repeat (2) @(negedge clock);
    write_dmi(7'h17, 32'h0022_07b1);
    check_reg(7'h04, 32'h8000_0104);
    write_dmi(7'h17, 32'h0022_07b0);
    check_reg(7'h04, 32'h4000_b907);
    // The next resume uses the captured PC, even without a DPC write.
    ack_allow = 0;
    write_dmi(7'h10, 32'h4000_0001);
    if (debug.resume_pc != 'h8000_0104) $fatal(1, "resume lost captured DPC");
    ack_allow = 1;
    repeat (2) @(negedge clock);
    halted = 0;
    repeat (2) @(negedge clock);
    write_dmi(7'h10, 32'h8000_0001);
    if (!haltreq || debug.step) $fatal(1, "haltreq failed to cancel pending step");
    halt_pc = Xlen'(32'h8000_0200);
    halt_cause = 3;
    halted = 1;
    repeat (2) @(negedge clock);
    write_dmi(7'h17, 32'h0022_07b1);
    check_reg(7'h04, 32'h8000_0200);
    if (Xlen == 64) begin
      // Canonical negative PCs retain both transfer words and halfword alignment.
      write_dmi(7'h04, 32'hffff_f123);
      write_dmi(7'h05, 32'hffff_ffff);
      write_dmi(7'h17, 32'h0033_07b1);
      write_dmi(7'h17, 32'h0032_07b1);
      check_reg(7'h04, 32'hffff_f122);
      check_reg(7'h05, 32'hffff_ffff);
      // A nonrepresentable address must remain invalid after PC legalization,
      // rather than aliasing the valid low 32-bit RAM address.
      write_dmi(7'h04, 32'h8000_0000);
      write_dmi(7'h05, 32'h0000_0100);
      write_dmi(7'h17, 32'h0033_07b1);
      write_dmi(7'h17, 32'h0032_07b1);
      check_reg(7'h04, 32'h8000_0000);
      check_reg(7'h05, `RAPT_PC_BITS_OF(Xlen) == 40 ? 32'h40 : 32'h100);
    end
    $display("PASS: DM SBA, reset, DPC, WARL DCSR and stalled resume handshake RV%0d", Xlen);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
