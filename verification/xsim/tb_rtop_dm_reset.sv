`include "rapt.svh"

module tb_rtop_dm_reset #(
    parameter bit ExplicitHalt = 0
);
  localparam int Xlen = `RAPT_XLEN;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  logic dmi_req = 0, dmi_wr = 0;
  logic [6:0] dmi_addr = 0;
  logic [31:0] dmi_wdata = 0, dmi_rdata;
  logic [1:0] dmi_resp;
  logic halted = 0, commit_fire = 0;
  logic haltreq, resumereq, ndmreset, gpr_we;
  logic [4:0] gpr_addr;
  logic [Xlen-1:0] gpr_wdata;
  rapt_dm #(
      .XLEN(Xlen)
  ) dut (
      .clock(clock),
      .reset(reset),
      .dmi_req(dmi_req),
      .dmi_wr(dmi_wr),
      .dmi_addr(dmi_addr),
      .dmi_wdata(dmi_wdata),
      .dmi_rdata(dmi_rdata),
      .dmi_resp(dmi_resp),
      .halted_i(halted),
      .halt_pc_i(Xlen'(32'h80000000)),
      .commit_fire_i(commit_fire),
      .haltreq_o(haltreq),
      .resumereq_o(resumereq),
      .ndmreset_o(ndmreset),
      .dbg_gpr_rdata_i('0),
      .dbg_gpr_we_o(gpr_we),
      .dbg_gpr_addr_o(gpr_addr),
      .dbg_gpr_wdata_o(gpr_wdata)
  );
  task automatic write_dmi(input logic [6:0] addr, input logic [31:0] data);
    @(negedge clock);
    dmi_req = 1;
    dmi_wr = 1;
    dmi_addr = addr;
    dmi_wdata = data;
    @(negedge clock);
    dmi_req = 0;
    dmi_wr = 0;
  endtask
  initial begin
    repeat (3) @(negedge clock);
    reset = 0;
    write_dmi(7'h10, 32'h1);
    write_dmi(7'h10, 32'h80000001);
    if (!haltreq) $fatal(1, "initial halt request missing");
    halted = 1;
    write_dmi(7'h04, 32'h40000004);
    write_dmi(7'h17, 32'h002307b0);  // access_register: write dcsr.step
    write_dmi(7'h10, 32'h40000001);  // resume with step armed
    halted = 0;
    if (haltreq) $fatal(1, "single-step did not release halt");
    // Disable before any instruction retires, then re-enable the DM.
    if (!ExplicitHalt) begin
      write_dmi(7'h10, 32'h0);
      repeat (2) @(negedge clock);
      write_dmi(7'h10, 32'h1);
    end
    write_dmi(7'h10, 32'h80000001);
    if (!haltreq) $fatal(1, "pending step suppressed explicit halt (reset=%0d)", !ExplicitHalt);
    $display("PASS: DM cancels pending step RV%0d explicit_halt=%0d", Xlen, ExplicitHalt);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
