`include "rapt.svh"
`include "rapt_debug_if.svh"

// Arbitrary DMI traffic and halt timing. The abstract hart supplies only actual
// halt edges and an applied-redirect acknowledgement. The AXI target can stall
// forever, return errors, or supply malformed read bursts. No fairness is assumed.
module formal_dm_debug #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PAddrBits = `RAPT_PADDR_BITS
) (
    input logic clock,
    input logic reset,
    input logic dmi_req,
    input logic dmi_wr,
    input logic [6:0] dmi_addr,
    input logic [31:0] dmi_wdata,
    input logic halted,
    input logic [XLEN-1:0] halt_pc,
    input logic [2:0] halt_cause,
    input logic [1:0] halt_prv,
    input logic resume_ack,
    input logic hart_reset,
    input logic unavailable,
    input logic arready,
    input logic [XLEN-1:0] rdata,
    input logic [1:0] rresp,
    input logic rlast,
    input logic rvalid,
    input logic awready,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid
);
  rapt_debug_if #(.XLEN(XLEN)) debug ();
  logic haltreq, gpr_we;
  assign debug.resume_ack = resume_ack;
  assign debug.cause = halt_cause;
  assign debug.prv = halt_prv;
  assign debug.fetch_block = 1'b0;
  logic past_valid = 0;
  always_ff @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    // Cluster availability cannot return before actual reset. The hart keeps
    // its drained halt boundary until a held resume has been applied.
    if (past_valid && !reset && !unavailable) begin
      if ($past(unavailable)) assume ($past(hart_reset));
    end
  end
  always_comb if (hart_reset) assume (unavailable);
  always_comb if (debug.resume_valid) assume (halted);

  rapt_dm #(
      .XLEN(XLEN),
      .PAddrBits(PAddrBits)
  ) dut (
      .clock,
      .reset,
      .dmi_req,
      .dmi_wr,
      .dmi_addr,
      .dmi_wdata,
      .dmi_rdata(),
      .dmi_resp(),
      .halted_i(halted),
      .hart_reset_i(hart_reset),
      .hart_unavailable_i(unavailable),
      .halt_pc_i(halt_pc),
      .debug(debug),
      .haltreq_o(haltreq),
      .resumereq_o(),
      .ndmreset_o(),
      .dbg_gpr_rdata_i('0),
      .dbg_gpr_we_o(gpr_we),
      .dbg_gpr_addr_o(),
      .dbg_gpr_wdata_o(),
      .sb_axi_araddr(),
      .sb_axi_arid(),
      .sb_axi_arlen(),
      .sb_axi_arsize(),
      .sb_axi_arburst(),
      .sb_axi_arcache(),
      .sb_axi_arvalid(),
      .sb_axi_arready(arready),
      .sb_axi_rdata(rdata),
      .sb_axi_rresp(rresp),
      .sb_axi_rlast(rlast),
      .sb_axi_rvalid(rvalid),
      .sb_axi_rready(),
      .sb_axi_awaddr(),
      .sb_axi_awid(),
      .sb_axi_awlen(),
      .sb_axi_awsize(),
      .sb_axi_awburst(),
      .sb_axi_awcache(),
      .sb_axi_awvalid(),
      .sb_axi_awready(awready),
      .sb_axi_wdata(),
      .sb_axi_wstrb(),
      .sb_axi_wlast(),
      .sb_axi_wvalid(),
      .sb_axi_wready(wready),
      .sb_axi_bresp(bresp),
      .sb_axi_bvalid(bvalid),
      .sb_axi_bready()
  );

  logic halted_prev;
  always_ff @(posedge clock) begin
    if (reset || !debug.enable || unavailable || hart_reset) halted_prev <= 1'b0;
    else halted_prev <= halted;
  end
  wire entering = debug.enable && halted && !halted_prev && !unavailable;
  wire writing_dpc = dut.cmd_accept && dut.cmd_transfer && dut.cmd_write && dut.cmd_is_dpc;
  wire stopped = reset || !debug.enable || unavailable || hart_reset;

  `RAPT_SVA_NEXT(clock, stopped, DM_PRECISE_DPC, entering && !writing_dpc, dut.dpc_q == $past
                 (halt_pc[XLEN-1:1]))
  `RAPT_SVA_NEXT(clock, stopped, DM_HALT_PRIVILEGE, entering, dut.dcsr_q[1:0] == $past(halt_prv))
  `RAPT_SVA_NEXT(clock, stopped, DM_PRIVILEGE_READ_ONLY, !entering, dut.dcsr_q[1:0] == $past
                 (dut.dcsr_q[1:0]))
  `RAPT_SVA(clock, reset, DM_VERSION_READ_ONLY, dut.dcsr_q[31:28] == 4)
  `RAPT_SVA_IMPLY(clock, reset, DM_HALT_DURING_STEP, debug.enable && dut.haltreq_q, haltreq)
  `RAPT_SVA_NEXT(clock, stopped, DM_RESUME_WAITS_FOR_HART, debug.resume_valid && !resume_ack,
                 haltreq)
  `RAPT_SVA_IMPLY(clock, reset, DM_ABSTRACT_GPR_DRAINED, gpr_we,
                  halted && !unavailable && !debug.resume_valid)
  `RAPT_COVER(clock, reset, DM_COVER_STEP_RESUME, debug.resume_valid && resume_ack && dut.dcsr_q[2])
  `RAPT_COVER(clock, reset, DM_COVER_STEP_HALT, entering && debug.step && halt_cause == 4)

  localparam int ByteBits = $clog2(XLEN / 8);
  wire read_done = dut.sb_axi_rready && rvalid && rlast;
  wire write_done = dut.sb_axi_bready && bvalid;
  wire bad_size = dut.sbaccess_q > ByteBits;
  wire bad_align = (dut.sb_start_addr & ((PAddrBits'(1) << dut.sbaccess_q) - 1)) != 0;
  wire starting = !dut.sb_busy && dut.sb_enabled && dut.sb_start;
  wire busy_access = dut.dmactive_q && dut.sb_busy
      && (dut.sb_address_write || dut.sb_data_access);
  wire read_error = read_done && rresp != 0 && dut.sberror_q == 0;
  wire write_error = write_done && bresp != 0 && dut.sberror_q == 0;
  wire incomplete = dut.sb_busy && !dut.sb_complete;
  wire increment = dut.sb_complete && dut.sb_success && dut.sbautoincrement_q;
  wire failed = dut.sb_complete && !dut.sb_success;
  wire rejected = !dut.sb_busy && dut.dmactive_q
      && (dut.sbbusyerror_q || dut.sberror_q != 0);
  wire [XLEN-1:0] read_value = rdata >> (dut.sbaddress_q[ByteBits-1:0] * 8);
  wire successful_read = read_done && dut.sb_success;
  wire [PAddrBits-1:0] next_address = dut.sbaddress_q + (PAddrBits'(1) << dut.sbaccess_q);
  for (genvar b = 0; b < XLEN / 8; b++) begin : g_strobe
    wire selected_byte = b >= dut.sbaddress_q[ByteBits-1:0]
        && b < int'(dut.sbaddress_q[ByteBits-1:0]) + (1 << dut.sbaccess_q);
    `RAPT_SVA_IMPLY(clock, reset, DM_SBA_BYTE_LANE, dut.sb_axi_wvalid,
                    dut.sb_axi_wstrb[b] == selected_byte)
  end

  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_ADDRESS, dut.sb_axi_arvalid && arready,
                 dut.sb_axi_rready)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_WAIT, dut.sb_axi_rready && !read_done, dut.sb_axi_rready)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_DEACTIVATE_DRAIN, incomplete && !dut.dmactive_q, dut.sb_busy)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_BUSY_ADDRESS, incomplete, $stable(dut.sbaddress_q) && $stable
                 (dut.sbaccess_q))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_BUSY_WRITE_DATA, incomplete && !dut.sb_axi_rready,
                 $stable(dut.sbdata_q))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_BUSY_ERROR, busy_access, dut.sbbusyerror_q)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_ERROR, read_error, dut.sberror_q == ($past(rresp)
                 == 3 ? 2 : 7))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_WRITE_ERROR, write_error, dut.sberror_q == ($past(bresp)
                 == 3 ? 2 : 7))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_MALFORMED, dut.sb_axi_rready && rvalid && !rlast,
                 dut.sberror_q == 7)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_INCREMENT, increment, dut.sbaddress_q == $past(next_address))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_ERROR_ADDRESS, failed, $stable(dut.sbaddress_q))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_UNSUPPORTED_SIZE, starting && bad_size,
                 !dut.sb_busy && dut.sberror_q == 4)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_MISALIGNED, starting && !bad_size && bad_align,
                 !dut.sb_busy && dut.sberror_q == 3)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_STICKY_GATE, rejected, !dut.sb_busy)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_AW_ONCE, dut.sb_axi_awvalid && awready, !dut.sb_axi_awvalid)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_W_ONCE, dut.sb_axi_wvalid && wready, !dut.sb_axi_wvalid)
  `RAPT_SVA_IMPLY(clock, reset, DM_SBA_B_AFTER_PAIR, dut.sb_axi_bready,
                  !dut.sb_axi_awvalid && !dut.sb_axi_wvalid)
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_BYTE, successful_read && dut.sbaccess_q == 0,
                 dut.sbdata_q == XLEN'($past(read_value[7:0])))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_HALF, successful_read && dut.sbaccess_q == 1,
                 dut.sbdata_q == XLEN'($past(read_value[15:0])))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_WORD, successful_read && dut.sbaccess_q == 2,
                 dut.sbdata_q[31:0] == $past(read_value[31:0]))
  if (XLEN == 64) begin : g_double
    `RAPT_SVA_NEXT(clock, reset, DM_SBA_READ_DOUBLE, successful_read && dut.sbaccess_q == 3,
                   dut.sbdata_q == $past(read_value))
  end

  `RAPT_COVER(clock, reset, DM_COVER_READ, successful_read)
  `RAPT_COVER(clock, reset, DM_COVER_WRITE, write_done && dut.sb_success)
  `RAPT_COVER(clock, reset, DM_COVER_DECERR, read_error && rresp == 3)
  `RAPT_COVER(clock, reset, DM_COVER_SLVERR, write_error && bresp == 2)
  `RAPT_COVER(clock, reset, DM_COVER_MALFORMED, dut.sb_axi_rready && rvalid && !rlast)
  `RAPT_COVER(clock, reset, DM_COVER_DEACTIVATE, incomplete && !dut.dmactive_q)
  `RAPT_COVER(clock, reset, DM_COVER_BUSY_ACCESS, busy_access)
  `RAPT_COVER(clock, reset, DM_COVER_INCREMENT, increment)
  `RAPT_COVER(clock, reset, DM_COVER_BAD_SIZE, starting && bad_size)
  `RAPT_COVER(clock, reset, DM_COVER_BAD_ALIGN, starting && !bad_size && bad_align)
  `RAPT_COVER(clock, reset, DM_COVER_W_BEFORE_AW, dut.sb_axi_awvalid && !dut.sb_axi_wvalid)
  `RAPT_COVER(clock, reset, DM_COVER_AW_BEFORE_W, !dut.sb_axi_awvalid && dut.sb_axi_wvalid)
  `RAPT_COVER(clock, reset, DM_COVER_SBA_DURING_RESET, dut.sb_busy && hart_reset)
endmodule
