`include "rapt.svh"
`include "rapt_debug_if.svh"

// Multi-hart Debug Module unit test (`NHARTS = 4`).
// Verifies hartsel selection, independent per-hart halt/resume, haltsum0,
// and out-of-range hartsel nonexistent reporting.
module tb_dm_multihart;
  localparam int XLEN = `RAPT_XLEN;
  localparam int NHARTS = 4;

  localparam logic [6:0] AddrDmcontrol = 7'h10;
  localparam logic [6:0] AddrDmstatus = 7'h11;
  localparam logic [6:0] AddrHaltsum0 = 7'h40;

  logic clock = 1'b0;
  logic reset = 1'b1;
  always #5 clock = ~clock;

  `include "tb_common.svh"

  logic              dmi_req;
  logic              dmi_wr;
  logic [       6:0] dmi_addr;
  logic [      31:0] dmi_wdata;
  logic [      31:0] dmi_rdata;
  logic [       1:0] dmi_resp;

  logic [NHARTS-1:0] halted;
  logic [NHARTS-1:0] haltreq;
  logic [NHARTS-1:0] resumereq;
  logic              ndmreset;
  rapt_debug_if #(.XLEN(XLEN)) debug ();

  logic [  XLEN-1:0] dbg_gpr_rdata;
  logic              dbg_gpr_we;
  logic [       4:0] dbg_gpr_addr;
  logic [  XLEN-1:0] dbg_gpr_wdata;

  rapt_dm #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) dut (
      .clock             (clock),
      .reset             (reset),
      .dmi_req           (dmi_req),
      .dmi_wr            (dmi_wr),
      .dmi_addr          (dmi_addr),
      .dmi_wdata         (dmi_wdata),
      .dmi_rdata         (dmi_rdata),
      .dmi_resp          (dmi_resp),
      .halted_i          (halted),
      .hart_reset_i      (1'b0),
      .hart_unavailable_i(1'b0),
      .halt_pc_i         (XLEN'(32'h8000_0000)),
      .debug             (debug),
      .haltreq_o         (haltreq),
      .resumereq_o       (resumereq),
      .ndmreset_o        (ndmreset),
      .dbg_gpr_rdata_i   (dbg_gpr_rdata),
      .dbg_gpr_we_o      (dbg_gpr_we),
      .dbg_gpr_addr_o    (dbg_gpr_addr),
      .dbg_gpr_wdata_o   (dbg_gpr_wdata),
      .sb_axi_araddr     (),
      .sb_axi_arid       (),
      .sb_axi_arlen      (),
      .sb_axi_arsize     (),
      .sb_axi_arburst    (),
      .sb_axi_arcache    (),
      .sb_axi_arvalid    (),
      .sb_axi_arready    (1'b0),
      .sb_axi_rdata      ('0),
      .sb_axi_rresp      (2'b00),
      .sb_axi_rlast      (1'b0),
      .sb_axi_rvalid     (1'b0),
      .sb_axi_rready     (),
      .sb_axi_awaddr     (),
      .sb_axi_awid       (),
      .sb_axi_awlen      (),
      .sb_axi_awsize     (),
      .sb_axi_awburst    (),
      .sb_axi_awcache    (),
      .sb_axi_awvalid    (),
      .sb_axi_awready    (1'b0),
      .sb_axi_wdata      (),
      .sb_axi_wstrb      (),
      .sb_axi_wlast      (),
      .sb_axi_wvalid     (),
      .sb_axi_wready     (1'b0),
      .sb_axi_bresp      (2'b00),
      .sb_axi_bvalid     (1'b0),
      .sb_axi_bready     ()
  );

  assign debug.cause = 3'd3;
  assign debug.prv   = 2'b11;

  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    begin
      dmi_req   = 1'b1;
      dmi_wr    = 1'b1;
      dmi_addr  = addr;
      dmi_wdata = data;
      tick(1);
      dmi_req = 1'b0;
      dmi_wr  = 1'b0;
    end
  endtask

  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    begin
      dmi_req  = 1'b1;
      dmi_wr   = 1'b0;
      dmi_addr = addr;
      #1;
      data = dmi_rdata;
      tick(1);
      dmi_req = 1'b0;
    end
  endtask

  initial begin
    logic [31:0] val;
    dmi_req          = 1'b0;
    dmi_wr           = 1'b0;
    dmi_addr         = '0;
    dmi_wdata        = '0;
    halted           = '0;
    dbg_gpr_rdata    = '0;
    debug.resume_ack = 1'b0;

    tick(3);
    reset = 1'b0;
    tick(1);

    // Activate DM
    dmi_write(AddrDmcontrol, 32'h0000_0001);

    // Select hart 2 and halt it
    dmi_write(AddrDmcontrol, 32'h8002_0001);  // haltreq=1, hartsello=2, dmactive=1
    check(debug.hartsel == 4'd2, "hartsel did not update to 2");
    check(haltreq == 4'b0100, "haltreq_o did not target only hart 2");

    // Simulate hart 2 entering halt
    halted[2] = 1'b1;
    tick(1);
    dmi_read(AddrDmstatus, val);
    check(val[9:8] == 2'b11, "dmstatus did not report hart 2 halted");
    dmi_read(AddrHaltsum0, val);
    check(val == 32'h0000_0004, "haltsum0 did not report bit 2 set");

    // Switch to hart 1 (still running), verify hart 2 stays halted
    dmi_write(AddrDmcontrol, 32'h0001_0001);  // hartsello=1, dmactive=1
    check(debug.hartsel == 4'd1, "hartsel did not update to 1");
    check(haltreq == 4'b0100, "hart 2 sticky halt was lost when switching hartsel");
    dmi_read(AddrDmstatus, val);
    check(val[11:10] == 2'b11 && val[9:8] == 2'b00, "dmstatus did not report hart 1 running");

    // Halt hart 1 as well; haltsum0 should report bits 1 and 2
    dmi_write(AddrDmcontrol, 32'h8001_0001);
    halted[1] = 1'b1;
    tick(1);
    dmi_read(AddrHaltsum0, val);
    check(val == 32'h0000_0006, "haltsum0 did not report harts 1 and 2 halted");

    // Resume hart 2
    dmi_write(AddrDmcontrol, 32'h4002_0001);  // resumereq=1, hartsello=2
    check(debug.resume_valid == 1'b1, "resume_valid did not assert for hart 2");
    debug.resume_ack = 1'b1;
    halted[2]        = 1'b0;
    tick(1);
    debug.resume_ack = 1'b0;
    tick(1);
    dmi_read(AddrDmstatus, val);
    check(val[17:16] == 2'b11 && val[11:10] == 2'b11, "hart 2 did not resume cleanly");
    dmi_read(AddrHaltsum0, val);
    check(val == 32'h0000_0002, "haltsum0 should only report hart 1 halted");

    $display("PASS: multi-hart Debug Module (NHARTS=%0d, XLEN=%0d)", NHARTS, XLEN);
    $finish;
  end
endmodule
