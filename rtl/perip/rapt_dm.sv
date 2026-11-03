`include "rapt.svh"
`include "rapt_debug_if.svh"

// rapt_dm: single-hart RISC-V Debug Module with independent AXI4 SBA.
//
// SBA (Debug Specification 1.0): sbcs (0x38), sbaddress0 (0x39),
// sbaddress1 (0x3a, PA > 32), sbdata0 (0x3c), sbdata1 (0x3d, RV64).
// Supports naturally aligned 8/16/32-bit and RV64 64-bit physical accesses,
// one transaction at a time, including while the hart is held in ndmreset.
// Sticky busy/error flags suppress new transactions until explicitly cleared.
// AXI errors become sberror=2 (DECERR) or 7 (other); no bus timeout is imposed.
// Deactivating the DM drains an issued SBA transaction before clearing its state.
// SBA bypasses all caches. Halt cleans L1D and resume invalidates L1I; L2 and
// cached data writes still need firmware cache maintenance. See docs/chip.md.
//
// ndmreset resets the non-debug domain through the cluster's drain controller.
// hart_reset_i records actual reset; hart_unavailable_i covers drain and reset.
// havereset is sticky until ackhavereset. haltreq and setresethaltreq support
// reset halt; DTM/DM and the SBA bus path stay in the external-reset domain.
//
// Register file (DTM-side compliance probe):
//   - dmcontrol  (RW: dmactive, ndmreset, haltreq, resumereq)
//   - dmstatus   (RO: version=3, authenticated=1, {any,all}{halted,running,resumeack})
//   - hartinfo   (RO: 0)
//   - abstractcs (R: progbufsize=0, datacount=XLEN/32, cmderr; W1C cmderr)
//   - command    (W:  abstract `access_register` for GPR + selected CSRs)
//   - data0/1    (RW: abstract transfer buffer; data1 exists on RV64)
//
// Halt path: `haltreq_o` is consumed by rapt_core/ROU which gates
// dispatch; `halted_i` (= ROB drained while haltreq) is reflected in
// dmstatus. A sticky DM halt state retains the request until resume;
// `{any,all}resumeack` latches when the hart applies the resume redirect.
// The hart owns precise single-instruction admission and debug entry. Resume
// holds halt until the hart acknowledges applying the DPC redirect.
//
// Abstract `access_register`: aarsize=2 (32-bit), plus 3 (64-bit) on RV64:
//   - regno 0x1000..0x101F : GPR x0..x31 via the cluster debug GPR bus
//                            (`dbg_gpr_rdata_i` / `dbg_gpr_we_o`)
//   - regno 0x07B0         : dcsr      (DM-internal storage)
//   - regno 0x07B1         : dpc       (DM-internal storage)
//   - regno 0x07B2         : dscratch0 (DM-internal storage)
//   - regno 0x07B3         : dscratch1 (DM-internal storage)
//   - regno 0x0301         : MISA      (read-only constant `RAPT_MISA`)
//   - regno 0x07A0..0x07A5 : tselect/tdata1-3/tinfo/tcontrol -- RAZ/WI so
//                            OpenOCD's trigger probe concludes "no triggers"
//                            without disabling abstract-command CSR access
//                            (needed for the dcsr.step write before `si`).
//   - regno 0x07A8 / 0x5A8 : mcontext / scontext            -- RAZ/WI
//   - any other regno      : cmderr=2 (not supported)
// Command preconditions: cmderr is 0 on entry (sticky-clear required first),
// halted_i==1 (else cmderr=4), cmdtype==0, supported aarsize, no aarpostincrement,
// no postexec; otherwise cmderr=2.
//
// NOT IMPLEMENTED (TODO):
//   - abstract access_memory (use SBA instead)
//   - progbuf execution (progbufsize=0)
//   - real Debug Mode FSM (fetch redirect to dm_haltaddr, dret)
//
// The DMI bus is a single-clock 0-busy variant: dmi_rdata is combinational
// (on dmi_addr) and writes commit on the rising edge while dmi_req is high.
// dmi_resp is hardwired to OK.
module rapt_dm #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PAddrBits = `RAPT_PADDR_BITS
) (
    input logic clock,
    input logic reset,

    // DMI from DTM
    input  logic        dmi_req,
    input  logic        dmi_wr,
    input  logic [ 6:0] dmi_addr,
    input  logic [31:0] dmi_wdata,
    output logic [31:0] dmi_rdata,
    output logic [ 1:0] dmi_resp,

    // Halted status from the core (level: 1 = ROB drained while haltreq
    // asserted). Drives dmstatus.allhalted/anyhalted.
    input logic                       halted_i,
    input logic                       hart_reset_i,
    input logic                       hart_unavailable_i,
    // Resume PC at the halt boundary (= npc of the youngest committed
    // instruction). Captured into dpc on the halted_i rising edge.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic            [XLEN-1:0] halt_pc_i,                  // bit 0 is hardwired zero in dpc
    /* verilator lint_on UNUSEDSIGNAL */
    rapt_debug_if.dm            debug,

    // Halt/resume/reset request lines to the cluster.
    output logic haltreq_o,
    output logic resumereq_o,
    output logic ndmreset_o,

    // Debug GPR bus to the core (committed view + write port). Caller-side
    // (rapt_prf) must hold halted_i before honouring `dbg_gpr_we_o`.
    // Combinational response to dbg_gpr_addr_o; no extra command cycle.
    input  logic [XLEN-1:0] dbg_gpr_rdata_i,
    output logic            dbg_gpr_we_o,
    output logic [     4:0] dbg_gpr_addr_o,
    output logic [XLEN-1:0] dbg_gpr_wdata_o,

    // Independent AXI4 master. Flat ports keep standalone DM probes compatible.
    output logic [XLEN-1:0] sb_axi_araddr,
    output logic [3:0] sb_axi_arid,
    output logic [7:0] sb_axi_arlen,
    output logic [2:0] sb_axi_arsize,
    output logic [1:0] sb_axi_arburst,
    output logic [3:0] sb_axi_arcache,
    output logic sb_axi_arvalid,
    input logic sb_axi_arready,
    input logic [XLEN-1:0] sb_axi_rdata,
    input logic [1:0] sb_axi_rresp,
    input logic sb_axi_rlast,
    input logic sb_axi_rvalid,
    output logic sb_axi_rready,
    output logic [XLEN-1:0] sb_axi_awaddr,
    output logic [3:0] sb_axi_awid,
    output logic [7:0] sb_axi_awlen,
    output logic [2:0] sb_axi_awsize,
    output logic [1:0] sb_axi_awburst,
    output logic [3:0] sb_axi_awcache,
    output logic sb_axi_awvalid,
    input logic sb_axi_awready,
    output logic [XLEN-1:0] sb_axi_wdata,
    output logic [XLEN/8-1:0] sb_axi_wstrb,
    output logic sb_axi_wlast,
    output logic sb_axi_wvalid,
    input logic sb_axi_wready,
    input logic [1:0] sb_axi_bresp,
    input logic sb_axi_bvalid,
    output logic sb_axi_bready
);

  localparam logic [6:0] AddrData0 = 7'h04;
  localparam logic [6:0] AddrData1 = 7'h05;
  localparam logic [3:0] AbstractDataCount = XLEN == 64 ? 4'd2 : 4'd1;
  localparam logic [6:0] AddrDmcontrol = 7'h10;
  localparam logic [6:0] AddrDmstatus = 7'h11;
  localparam logic [6:0] AddrHartinfo = 7'h12;
  localparam logic [6:0] AddrAbstractcs = 7'h16;
  localparam logic [6:0] AddrCommand = 7'h17;

  localparam logic [6:0] AddrSbcs = 7'h38;
  localparam logic [6:0] AddrSbaddress0 = 7'h39;
  localparam logic [6:0] AddrSbaddress1 = 7'h3a;
  localparam logic [6:0] AddrSbdata0 = 7'h3c;
  localparam logic [6:0] AddrSbdata1 = 7'h3d;

  // ----------------------------------------------------------
  // State
  // ----------------------------------------------------------
  logic havereset_q;
  logic resethaltreq_q, reset_halt_q;
  logic dmactive_q;
  logic ndmreset_q;
  logic haltreq_q;
  logic resumereq_q;
  // Sticky acknowledgement of the hart's applied resume redirect.
  logic resumeack_q;
  // Sticky halted state inside the DM. Per Debug Spec 1.0 Sec.3.5: once a
  // hart enters Debug Mode it stays halted independent of haltreq, until
  // a resumereq (or, equivalently here, dret in a real Debug Mode FSM).
  // Because we don't yet have a real Debug Mode FSM, we keep haltreq_o
  // asserted to the core whenever this bit is set, which forces the
  // ROU dispatch gate to keep blocking. Set when halted_i pulses high;
  // cleared only after the requested resume redirect is acknowledged.
  logic dm_halt_state_q;
  logic halted_prev_q;
  logic resume_pending_q;
  logic [31:0] data0_q, data1_q;
  logic [XLEN-1:0] abstract_wdata;
  logic            cmd_size_supported;
  logic [     2:0] cmderr_q;

  // Debug-only CSR storage (RV-Debug 1.0 Sec.4). Only written via abstract
  // access_register; the running core never sees these via csrr/csrw
  // (no architectural Debug Mode entry implemented yet).
  logic [    31:0] dcsr_q;  // dcsr is fixed 32-bit per spec
  logic [XLEN-1:1] dpc_q;
  wire  [XLEN-1:0] dpc_value = {dpc_q, 1'b0};
  localparam int PcBits = `RAPT_PC_BITS_OF(XLEN);
  wire  [PcBits-1:0] dpc_write_pc = `RAPT_PC_LEGALIZE(XLEN, PcBits, abstract_wdata);
  wire  [  XLEN-1:0] dpc_write_value = `RAPT_PC_SEXT(XLEN, dpc_write_pc);
  logic [  XLEN-1:0] dscratch0_q;
  logic [  XLEN-1:0] dscratch1_q;

  // The hart owns instruction admission and trap/retirement entry. Keep step
  // asserted from resume acknowledgement until the actual halt boundary.
  logic              step_pending_q;

  // ----------------------------------------------------------
  // Abstract command decode (combinational on the in-flight DMI write)
  // ----------------------------------------------------------
  // Field layout from `command` per Debug Spec 1.0 Sec.3.6:
  //   [31:24] cmdtype, [22:20] aarsize, [19] aarpostincrement,
  //   [18] postexec, [17] transfer, [16] write, [15:0] regno.
  logic [       7:0] cmd_cmdtype;
  logic [       2:0] cmd_aarsize;
  logic              cmd_aarpostinc;
  logic              cmd_postexec;
  logic              cmd_transfer;
  logic              cmd_write;
  logic [      15:0] cmd_regno;
  assign cmd_cmdtype        = dmi_wdata[31:24];
  assign cmd_aarsize        = dmi_wdata[22:20];
  assign cmd_aarpostinc     = dmi_wdata[19];
  assign cmd_postexec       = dmi_wdata[18];
  assign cmd_transfer       = dmi_wdata[17];
  assign cmd_write          = dmi_wdata[16];
  assign cmd_regno          = dmi_wdata[15:0];

  assign abstract_wdata     = cmd_aarsize == 3'd3 ? XLEN'({data1_q, data0_q}) : XLEN'(data0_q);
  assign cmd_size_supported = cmd_aarsize == 3'd2 || (XLEN == 64 && cmd_aarsize == 3'd3);

  logic cmd_is_gpr, cmd_is_misa, cmd_is_dcsr, cmd_is_dpc;
  logic cmd_is_dscr0, cmd_is_dscr1;
  // Trigger CSRs: read as zero, writes ignored. This advertises "no
  // triggers" to OpenOCD without it disabling abstract-command CSR access
  // (which would block the dcsr.step write needed for `stepi`).
  logic       cmd_is_trig_raz;
  logic [4:0] cmd_gpr_idx;
  assign cmd_is_gpr = (cmd_regno >= 16'h1000) && (cmd_regno < 16'h1020);
  assign cmd_gpr_idx = cmd_regno[4:0];
  assign cmd_is_misa = (cmd_regno == 16'h0301);
  assign cmd_is_dcsr = (cmd_regno == 16'h07B0);
  assign cmd_is_dpc = (cmd_regno == 16'h07B1);
  assign cmd_is_dscr0 = (cmd_regno == 16'h07B2);
  assign cmd_is_dscr1 = (cmd_regno == 16'h07B3);
  // tselect (7A0), tdata1/2/3 (7A1/2/3), tinfo (7A4), tcontrol (7A5),
  // mcontext (7A8), scontext (5A8) -- all reported as zero.
  assign cmd_is_trig_raz = (cmd_regno == 16'h07A0)
                        || (cmd_regno == 16'h07A1)
                        || (cmd_regno == 16'h07A2)
                        || (cmd_regno == 16'h07A3)
                        || (cmd_regno == 16'h07A4)
                        || (cmd_regno == 16'h07A5)
                        || (cmd_regno == 16'h07A8)
                        || (cmd_regno == 16'h05A8);
  logic cmd_reg_supported;
  assign cmd_reg_supported = cmd_is_gpr || cmd_is_misa
                           || cmd_is_dcsr || cmd_is_dpc
                           || cmd_is_dscr0 || cmd_is_dscr1
                           || cmd_is_trig_raz;

  // Read mux (XLEN-wide; data0/data1 carry the selected transfer).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] reg_rdata;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    reg_rdata = '0;
    if (cmd_is_gpr) reg_rdata = dbg_gpr_rdata_i;
    else if (cmd_is_misa) reg_rdata = `RAPT_MISA;
    else if (cmd_is_dcsr) reg_rdata = XLEN'(dcsr_q);
    else if (cmd_is_dpc) reg_rdata = dpc_value;
    else if (cmd_is_dscr0) reg_rdata = dscratch0_q;
    else if (cmd_is_dscr1) reg_rdata = dscratch1_q;
    // cmd_is_trig_raz: zero (default).
  end

  // Validity gates for issuing the command this cycle.
  logic cmd_write_now;  // DMI write to AddrCommand on this rising edge
  logic cmd_accept;  // command passes all preconditions -> execute
  logic cmd_unsupported;  // accept but unsupported reg/aarsize -> cmderr=2
  logic cmd_halt_err;  // not halted -> cmderr=4
  // Abstract transfers require the actual drained hart, with no redirect in
  // flight. A sticky request alone does not make architectural state accessible.
  logic halted_eff;
  assign halted_eff = halted_i && !hart_unavailable_i && !resume_pending_q;

  assign cmd_write_now   = dmactive_q && dmi_req && dmi_wr
                         && (dmi_addr == AddrCommand)
                         && (cmderr_q == 3'd0);
  assign cmd_halt_err = cmd_write_now && !halted_eff;
  assign cmd_unsupported = cmd_write_now && halted_eff
                         && ((cmd_cmdtype != 8'd0)
                             || !cmd_size_supported
                             || cmd_aarpostinc || cmd_postexec
                             || (cmd_transfer && !cmd_reg_supported));
  assign cmd_accept      = cmd_write_now && halted_eff
                         && (cmd_cmdtype == 8'd0)
                         && cmd_size_supported
                         && !cmd_aarpostinc && !cmd_postexec
                         && (!cmd_transfer || cmd_reg_supported);

  // ----------------------------------------------------------
  // Sequential
  // ----------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      dmactive_q       <= 1'b0;
      resethaltreq_q   <= 1'b0;
      reset_halt_q     <= 1'b0;
      ndmreset_q       <= 1'b0;
      haltreq_q        <= 1'b0;
      resumereq_q      <= 1'b0;
      resumeack_q      <= 1'b0;
      dm_halt_state_q  <= 1'b0;
      halted_prev_q    <= 1'b0;
      resume_pending_q <= 1'b0;
      data0_q          <= '0;
      data1_q          <= '0;
      cmderr_q         <= 3'd0;
      dcsr_q           <= 32'h4000_0000;  // xdebugver=4, all else 0
      dpc_q            <= '0;
      dscratch0_q      <= '0;
      dscratch1_q      <= '0;
      step_pending_q   <= 1'b0;
    end else if (!dmactive_q) begin
      // dmactive=0 holds DM in reset except for dmactive itself.
      resethaltreq_q   <= 1'b0;
      reset_halt_q     <= 1'b0;
      ndmreset_q       <= 1'b0;
      haltreq_q        <= 1'b0;
      resumereq_q      <= 1'b0;
      resumeack_q      <= 1'b0;
      dm_halt_state_q  <= 1'b0;
      halted_prev_q    <= 1'b0;
      resume_pending_q <= 1'b0;
      data0_q          <= '0;
      data1_q          <= '0;
      cmderr_q         <= 3'd0;
      step_pending_q   <= 1'b0;
      // dcsr/dpc/dscratch are NOT cleared by dmactive=0 per spec; only by
      // hard reset.
      if (dmi_req && dmi_wr && dmi_addr == AddrDmcontrol) begin
        dmactive_q <= dmi_wdata[0];
      end
    end else begin
      halted_prev_q <= halted_i && !hart_unavailable_i;
      // Per-DMI-write side-effects.
      if (dmi_req && dmi_wr) begin
        unique case (dmi_addr)
          AddrDmcontrol: begin
            dmactive_q  <= dmi_wdata[0];
            ndmreset_q  <= dmi_wdata[1];
            resumereq_q <= dmi_wdata[30];
            haltreq_q   <= dmi_wdata[31];
            if (dmi_wdata[2]) resethaltreq_q <= 1'b0;
            if (dmi_wdata[3]) resethaltreq_q <= 1'b1;
            // Per spec: writing haltreq=1 clears resumeack; writing
            // resumereq=1 (with haltreq=0) starts a fresh ack window.
            if (dmi_wdata[31]) begin
              resumeack_q <= 1'b0;
              // An explicit halt must also stop a step stalled before retirement.
              step_pending_q <= 1'b0;
            end
            if (dmi_wdata[30] && !dmi_wdata[31]) resumeack_q <= 1'b0;
          end
          AddrData0: data0_q <= dmi_wdata;
          AddrData1: if (XLEN == 64) data1_q <= dmi_wdata;
          AddrAbstractcs: begin
            // cmderr is W1C (write 1s to clear)
            cmderr_q <= cmderr_q & ~dmi_wdata[10:8];
          end
          AddrCommand: begin
            // See cmd_accept/cmd_halt_err/cmd_unsupported logic below.
            if (cmd_halt_err) cmderr_q <= 3'd4;  // halt/resume error
            else if (cmd_unsupported) cmderr_q <= 3'd2;
          end
          default:   ;
        endcase
      end

      // Apply an accepted abstract command. transfer=0 with a write to
      // AddrCommand is a no-op (regno-only update; we don't track regno).
      if (cmd_accept && cmd_transfer) begin
        if (cmd_write) begin
          // data0 -> register. GPR writes are sourced via dbg_gpr_we_o
          // below; CSR-class targets latch here.
          if (cmd_is_dcsr) begin
            // Only implemented controls are writable. cause/xdebugver and
            // the observed privilege remain read-only.
            dcsr_q <= (dcsr_q & ~32'h0000_b804) | (data0_q & 32'h0000_b804);
          end else if (cmd_is_dpc) dpc_q <= dpc_write_value[XLEN-1:1];
          else if (cmd_is_dscr0) dscratch0_q <= abstract_wdata;
          else if (cmd_is_dscr1) dscratch1_q <= abstract_wdata;
          // cmd_is_misa: read-only, silently dropped (spec allows either).
        end else begin
          // register -> abstract data, high word for a 64-bit transfer.
          data0_q <= reg_rdata[31:0];
          if (XLEN == 64 && cmd_aarsize == 3'd3) data1_q <= 32'(reg_rdata >> 32);
        end
      end

      // Latch resume-ack only after the hart applies the requested redirect;
      // independent of DMI write activity.
      if (resume_pending_q && debug.resume_ack) begin
        resumeack_q <= 1'b1;
        resume_pending_q <= 1'b0;
        dm_halt_state_q <= 1'b0;
        reset_halt_q <= 1'b0;
        step_pending_q <= dcsr_q[2];
      end

      // Sticky DM halt state: latch on any halted_i pulse so the abstract
      // command path keeps working after host deasserts haltreq, and the
      // core stays halted (haltreq_o stays high) until a resumereq write.
      if (halted_i && !halted_prev_q && !hart_unavailable_i) begin
        dm_halt_state_q <= 1'b1;
        reset_halt_q <= 1'b0;
      end
      // On the rising edge of halted_i (entering halt), capture the
      // resume PC into dpc so OpenOCD/GDB can read it back.
      if (halted_i && !halted_prev_q && !hart_unavailable_i) begin
        if (!(cmd_accept && cmd_transfer && cmd_write && cmd_is_dpc)) dpc_q <= halt_pc_i[XLEN-1:1];
        dcsr_q[8:6] <= reset_halt_q && !haltreq_q ? 3'd5 : debug.cause;
        dcsr_q[1:0] <= debug.prv;
        step_pending_q <= 1'b0;
      end
      if (dmi_req && dmi_wr && dmi_addr == AddrDmcontrol
          && dmi_wdata[30] && !dmi_wdata[31] && halted_eff) begin
        // Keep the hart halted until its DPC redirect has been applied.
        resume_pending_q <= 1'b1;
      end
      if (hart_reset_i) begin
        dm_halt_state_q <= 1'b0;
        resumeack_q <= 1'b0;
        step_pending_q <= 1'b0;
        halted_prev_q <= 1'b0;
        resume_pending_q <= 1'b0;
        reset_halt_q <= resethaltreq_q;
      end
    end
  end

  // SBA owns its payload until the final response, including across dmactive=0.
  // Never withdraw an AXI VALID or discard half of an accepted AW/W pair.
  localparam int ByteOffBits = $clog2(XLEN / 8);
  typedef enum logic [1:0] {
    SbIdle,
    SbReadAddr,
    SbReadData,
    SbWrite
  } sb_state_t;
  sb_state_t sb_state_q;
  logic [PAddrBits-1:0] sbaddress_q, sb_start_addr;
  logic [XLEN-1:0] sbdata_q;
  logic [2:0] sbaccess_q, sberror_q;
  logic sbreadonaddr_q, sbreadondata_q, sbautoincrement_q, sbbusyerror_q;
  logic sb_aw_pending_q, sb_w_pending_q;
  logic sb_busy, sb_address_write, sb_data_access, sb_start, sb_start_write;
  logic sb_enabled, sb_complete, sb_success;
  logic [31:0] sbcs_rd;
  logic [XLEN/8-1:0] sb_byte_mask;
  logic [XLEN-1:0] sb_read_value;

  assign sb_busy = sb_state_q != SbIdle;
  assign sb_enabled = dmactive_q && !sbbusyerror_q && sberror_q == 0;
  assign sb_address_write = dmi_req && dmi_wr
      && (dmi_addr == AddrSbaddress0 || (PAddrBits > 32 && dmi_addr == AddrSbaddress1));
  assign sb_data_access = dmi_req
      && (dmi_addr == AddrSbdata0 || (XLEN == 64 && dmi_addr == AddrSbdata1));
  assign sb_start_write = dmi_req && dmi_wr && dmi_addr == AddrSbdata0;
  assign sb_start = sb_start_write
      || (dmi_req && dmi_wr && dmi_addr == AddrSbaddress0 && sbreadonaddr_q)
      || (dmi_req && !dmi_wr && dmi_addr == AddrSbdata0 && sbreadondata_q);
  assign sb_start_addr = dmi_wr && dmi_addr == AddrSbaddress0
      ? (sbaddress_q & ~(PAddrBits'(32'hffff_ffff))) | PAddrBits'(dmi_wdata)
      : sbaddress_q;

  always_comb begin
    sbcs_rd = '0;
    sbcs_rd[31:29] = 3'd1;
    sbcs_rd[22] = sbbusyerror_q;
    sbcs_rd[21] = sb_busy;
    sbcs_rd[20] = sbreadonaddr_q;
    sbcs_rd[19:17] = sbaccess_q;
    sbcs_rd[16] = sbautoincrement_q;
    sbcs_rd[15] = sbreadondata_q;
    sbcs_rd[14:12] = sberror_q;
    sbcs_rd[11:5] = 7'(PAddrBits);
    sbcs_rd[3:0] = {XLEN == 64, 3'b111};
  end

  assign sb_axi_araddr = XLEN'(sbaddress_q);
  assign sb_axi_arid = 4'hf;
  assign sb_axi_arlen = '0;
  assign sb_axi_arsize = sbaccess_q;
  assign sb_axi_arburst = 2'b01;
  assign sb_axi_arcache = '0;
  assign sb_axi_arvalid = sb_state_q == SbReadAddr;
  assign sb_axi_rready = sb_state_q == SbReadData;
  assign sb_axi_awaddr = XLEN'(sbaddress_q);
  assign sb_axi_awid = 4'hf;
  assign sb_axi_awlen = '0;
  assign sb_axi_awsize = sbaccess_q;
  assign sb_axi_awburst = 2'b01;
  assign sb_axi_awcache = '0;
  assign sb_axi_awvalid = sb_state_q == SbWrite && sb_aw_pending_q;
  assign sb_byte_mask = (XLEN / 8)'('1) >> ((XLEN / 8) - (1 << sbaccess_q));
  assign sb_axi_wdata = sbdata_q << (sbaddress_q[ByteOffBits-1:0] * 8);
  assign sb_axi_wstrb = sb_byte_mask << sbaddress_q[ByteOffBits-1:0];
  assign sb_axi_wlast = 1'b1;
  assign sb_axi_wvalid = sb_state_q == SbWrite && sb_w_pending_q;
  assign sb_axi_bready = sb_state_q == SbWrite && !sb_aw_pending_q && !sb_w_pending_q;
  assign sb_read_value = sb_axi_rdata >> (sbaddress_q[ByteOffBits-1:0] * 8);
  assign sb_complete = (sb_axi_rready && sb_axi_rvalid && sb_axi_rlast)
      || (sb_axi_bready && sb_axi_bvalid);
  assign sb_success = sberror_q == 0
      && (sb_state_q == SbReadData ? sb_axi_rresp == 0 : sb_axi_bresp == 0);

  always_ff @(posedge clock) begin
    if (reset || (!dmactive_q && !sb_busy)) begin
      sb_state_q <= SbIdle;
      sbaddress_q <= '0;
      sbdata_q <= '0;
      sbaccess_q <= 3'd2;
      sbreadonaddr_q <= 1'b0;
      sbreadondata_q <= 1'b0;
      sbautoincrement_q <= 1'b0;
      sbbusyerror_q <= 1'b0;
      sberror_q <= '0;
      sb_aw_pending_q <= 1'b0;
      sb_w_pending_q <= 1'b0;
    end else begin
      if (sb_axi_arvalid && sb_axi_arready) sb_state_q <= SbReadData;
      if (sb_axi_awvalid && sb_axi_awready) sb_aw_pending_q <= 1'b0;
      if (sb_axi_wvalid && sb_axi_wready) sb_w_pending_q <= 1'b0;
      // A malformed multi-beat response is drained, then reported as other.
      if (sb_axi_rvalid && sb_axi_rready && !sb_axi_rlast) sberror_q <= 3'd7;
      if (sb_complete) begin
        sb_state_q <= SbIdle;
        if (!sb_success) begin
          if (sberror_q == 0)
            sberror_q <= (sb_state_q == SbReadData ? sb_axi_rresp : sb_axi_bresp)
                == 2'b11 ? 3'd2 : 3'd7;
        end else begin
          if (sb_state_q == SbReadData) begin
            case (sbaccess_q)
              3'd0: sbdata_q <= XLEN'(sb_read_value[7:0]);
              3'd1: sbdata_q <= XLEN'(sb_read_value[15:0]);
              default: sbdata_q <= sb_read_value;
            endcase
          end
          if (sbautoincrement_q) sbaddress_q <= sbaddress_q + (PAddrBits'(1) << sbaccess_q);
        end
      end
      if (dmactive_q) begin
        if (dmi_req && dmi_wr && dmi_addr == AddrSbcs && !sb_busy) begin
          sbbusyerror_q <= sbbusyerror_q && !dmi_wdata[22];
          sberror_q <= sberror_q & ~dmi_wdata[14:12];
          sbreadonaddr_q <= dmi_wdata[20];
          sbaccess_q <= dmi_wdata[19:17];
          sbautoincrement_q <= dmi_wdata[16];
          sbreadondata_q <= dmi_wdata[15];
        end
        if (sb_busy && (sb_address_write || sb_data_access)) sbbusyerror_q <= 1'b1;
        if (!sb_busy && sb_address_write) begin
          if (dmi_addr == AddrSbaddress0) sbaddress_q <= sb_start_addr;
          else
            sbaddress_q <= (sbaddress_q & PAddrBits'(32'hffff_ffff))
              | (PAddrBits'(dmi_wdata) << 32);
        end
        if (!sb_busy && sb_enabled) begin
          if (sb_data_access && dmi_wr) begin
            if (dmi_addr == AddrSbdata0)
              sbdata_q <= (sbdata_q & ~(XLEN'(32'hffff_ffff))) | XLEN'(dmi_wdata);
            else sbdata_q <= (sbdata_q & XLEN'(32'hffff_ffff)) | (XLEN'(dmi_wdata) << 32);
          end
          if (sb_start) begin
            if (sbaccess_q > 3'(ByteOffBits)) sberror_q <= 3'd4;
            else if ((sb_start_addr & ((PAddrBits'(1) << sbaccess_q) - 1)) != 0) sberror_q <= 3'd3;
            else if (sb_start_write) begin
              sb_state_q <= SbWrite;
              sb_aw_pending_q <= 1'b1;
              sb_w_pending_q <= 1'b1;
            end else sb_state_q <= SbReadAddr;
          end
        end
      end
    end
  end

`ifdef RAPT_SVA_ACTIVE
  logic [XLEN+2:0] sb_ar_payload, sb_aw_payload;
  logic [XLEN+XLEN/8-1:0] sb_w_payload;
  assign sb_ar_payload = {sb_axi_araddr, sb_axi_arsize};
  assign sb_aw_payload = {sb_axi_awaddr, sb_axi_awsize};
  assign sb_w_payload  = {sb_axi_wdata, sb_axi_wstrb};
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_AR_STABLE, sb_axi_arvalid && !sb_axi_arready,
                 sb_axi_arvalid && $stable(sb_ar_payload))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_AW_STABLE, sb_axi_awvalid && !sb_axi_awready,
                 sb_axi_awvalid && $stable(sb_aw_payload))
  `RAPT_SVA_NEXT(clock, reset, DM_SBA_W_STABLE, sb_axi_wvalid && !sb_axi_wready,
                 sb_axi_wvalid && $stable(sb_w_payload))
`endif

  // ----------------------------------------------------------
  // Combinational read mux
  // ----------------------------------------------------------
  logic [31:0] dmstatus_val;
  // Layout (Debug Spec 1.0 dmstatus):
  //   [3:0]   version       = 3 (1.0)
  //   [7]     authenticated = 1
  //   [8]     anyhalted     = halted_i
  //   [9]     allhalted     = halted_i
  //   [10]    anyrunning    = !halted_i
  //   [11]    allrunning    = !halted_i
  //   [16]    anyresumeack  = resumeack_q
  //   [17]    allresumeack  = resumeack_q
  always_comb begin
    dmstatus_val = 32'h0000_00a3;  // version=3, authenticated, hasresethaltreq
    dmstatus_val[9:8] = {2{halted_eff}};
    dmstatus_val[11:10] = {2{!halted_eff && !hart_unavailable_i}};
    dmstatus_val[13:12] = {2{hart_unavailable_i}};
    dmstatus_val[17:16] = {2{resumeack_q && !hart_unavailable_i}};
    dmstatus_val[19:18] = {2{havereset_q}};
    dmstatus_val[24] = ndmreset_q || hart_unavailable_i;
  end

  always_ff @(posedge clock) begin
    if (reset || hart_reset_i) havereset_q <= 1'b1;
    else if (dmactive_q && dmi_req && dmi_wr && dmi_addr == AddrDmcontrol && dmi_wdata[28])
      havereset_q <= 1'b0;
  end

  logic [31:0] dmcontrol_rd;
  assign dmcontrol_rd = {
    haltreq_q,  // [31] R: shows last-written haltreq
    resumereq_q,  // [30] R: ditto
    28'b0,  // [29:2] omitted (hartreset, hasel, hartsel, etc. = 0)
    ndmreset_q,  // [1]
    dmactive_q  // [0]
  };

  logic [31:0] abstractcs_rd;
  // [3:0] datacount=XLEN/32, [10:8] cmderr, [12] busy=0, [28:24] progbufsize=0
  assign abstractcs_rd = {3'b0, 5'd0, 10'b0, 1'b0, 1'b0, 1'b0, cmderr_q, 4'b0, AbstractDataCount};

  always_comb begin
    dmi_rdata = '0;
    unique case (dmi_addr)
      AddrData0:      dmi_rdata = data0_q;
      AddrData1:      dmi_rdata = XLEN == 64 ? data1_q : '0;
      AddrDmcontrol:  dmi_rdata = dmcontrol_rd;
      AddrDmstatus:   dmi_rdata = dmstatus_val;
      AddrHartinfo:   dmi_rdata = '0;
      AddrAbstractcs: dmi_rdata = abstractcs_rd;
      AddrCommand:    dmi_rdata = '0;  // RAZ
      AddrSbcs:       dmi_rdata = sbcs_rd;
      AddrSbaddress0: dmi_rdata = 32'(sbaddress_q);
      AddrSbaddress1: dmi_rdata = 32'(sbaddress_q >> 32);
      AddrSbdata0:    dmi_rdata = sbdata_q[31:0];
      AddrSbdata1:    dmi_rdata = XLEN == 64 ? 32'(sbdata_q >> 32) : '0;
      default:        dmi_rdata = '0;
    endcase
  end

  assign dmi_resp = 2'b00;  // always OK
  // A pending step never suppresses an explicit halt request. Release halt
  // only after the resume redirect has been acknowledged by the hart.
  assign haltreq_o = (haltreq_q | dm_halt_state_q | reset_halt_q | resume_pending_q) & dmactive_q;
  assign resumereq_o = resumereq_q & dmactive_q;
  assign ndmreset_o = ndmreset_q & dmactive_q;
  assign debug.enable = dmactive_q;
  assign debug.step = step_pending_q && dmactive_q;
  assign debug.stepie = dcsr_q[11];
  assign debug.ebreak = dmactive_q ? {dcsr_q[15], dcsr_q[13:12]} : '0;
  assign debug.resume_valid = resume_pending_q && dmactive_q && !hart_unavailable_i;
  assign debug.resume_pc = PcBits'(dpc_value);

  `RAPT_SVA_NEXT(clock, reset || !dmactive_q || hart_unavailable_i, DM_RESUME_STABLE,
                 debug.resume_valid && !debug.resume_ack, debug.resume_valid && $stable
                 (debug.resume_pc))
  `RAPT_SVA_IMPLY(clock, reset, DM_GPR_WRITE_HALTED, dbg_gpr_we_o, halted_eff)

  // Drive the debug-GPR write port for one cycle when an accepted abstract
  // command issues a transfer-write to a GPR target. rapt_prf samples this
  // on the same rising edge that latches the new dcsr_q / dpc_q above, so
  // the architectural and DM views stay in sync.
  assign dbg_gpr_we_o = cmd_accept && cmd_transfer && cmd_write && cmd_is_gpr;
  assign dbg_gpr_addr_o = cmd_gpr_idx;
  assign dbg_gpr_wdata_o = abstract_wdata;

endmodule
