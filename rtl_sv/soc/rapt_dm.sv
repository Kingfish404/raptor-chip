`include "rapt.svh"

// rapt_dm: minimal RISC-V Debug Module.
//
// Register file (DTM-side compliance probe):
//   - dmcontrol  (RW: dmactive, ndmreset, haltreq, resumereq)
//   - dmstatus   (RO: version=3, authenticated=1, {any,all}{halted,running,resumeack})
//   - hartinfo   (RO: 0)
//   - abstractcs (R: progbufsize=0, datacount=1, cmderr; W1C cmderr)
//   - command    (W:  abstract `access_register` for GPR + selected CSRs)
//   - data0      (RW: 32-bit transfer buffer for abstract commands)
//
// Halt path (Phase 1): `haltreq_o` is consumed by rapt_core/ROU which gates
// dispatch; `halted_i` (= ROB drained while haltreq) is reflected in
// dmstatus. `resumereq_o` is currently a hint --- ROU resumes automatically
// when haltreq deasserts, and `{any,all}resumeack` latches when the core
// leaves halted with resumereq pending.
//
// Abstract `access_register` (Phase 3, RV32 only, aarsize=2 / 32-bit):
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
// halted_i==1 (else cmderr=4), cmdtype==0, aarsize==2, no aarpostincrement,
// no postexec; otherwise cmderr=2.
//
// NOT IMPLEMENTED (TODO):
//   - access_memory / SBA (sbcs/sbaddr/sbdata/sbcs busy)
//   - progbuf execution (progbufsize=0)
//   - dcsr.{ebreakm,ebreaks,ebreaku,step} side-effects (storage only)
//   - aarsize=3 (RV64) -- needs data1 pairing
//   - real Debug Mode FSM (fetch redirect to dm_haltaddr, dret)
//
// The DMI bus is a single-clock 0-busy variant: dmi_rdata is combinational
// (on dmi_addr) and writes commit on the rising edge while dmi_req is high.
// dmi_resp is hardwired to OK.
module rapt_dm #(
    parameter int XLEN = `RAPT_XLEN
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
    input logic            halted_i,
    // Resume PC at the halt boundary (= npc of the youngest committed
    // instruction). Captured into dpc on the halted_i rising edge.
    input logic [XLEN-1:0] halt_pc_i,
    // Single-cycle pulse from the core: at least one instruction retired
    // this cycle. Used to count instructions while dcsr.step=1 so a
    // single-step resume halts again after exactly one retire.
    input logic            commit_fire_i,

    // Halt/resume/reset request lines to the cluster.
    output logic haltreq_o,
    output logic resumereq_o,
    output logic ndmreset_o,

    // Debug GPR bus to the core (committed view + write port). Caller-side
    // (rapt_prf) must hold halted_i before honouring `dbg_gpr_we_o`.
    input  logic [XLEN-1:0] dbg_gpr_rdata_i[32],
    output logic            dbg_gpr_we_o,
    output logic [     4:0] dbg_gpr_addr_o,
    output logic [XLEN-1:0] dbg_gpr_wdata_o
);

  localparam logic [6:0] AddrData0 = 7'h04;
  localparam logic [6:0] AddrDmcontrol = 7'h10;
  localparam logic [6:0] AddrDmstatus = 7'h11;
  localparam logic [6:0] AddrHartinfo = 7'h12;
  localparam logic [6:0] AddrAbstractcs = 7'h16;
  localparam logic [6:0] AddrCommand = 7'h17;

  // ----------------------------------------------------------
  // State
  // ----------------------------------------------------------
  logic            dmactive_q;
  logic            ndmreset_q;
  logic            haltreq_q;
  logic            resumereq_q;
  // Sticky resume-ack: latched when the core deasserts halted_i after a
  // resumereq pulse; cleared by the next haltreq=1 write.
  logic            resumeack_q;
  // Sticky halted state inside the DM. Per Debug Spec 1.0 §3.5: once a
  // hart enters Debug Mode it stays halted independent of haltreq, until
  // a resumereq (or, equivalently here, dret in a real Debug Mode FSM).
  // Because we don't yet have a real Debug Mode FSM, we keep haltreq_o
  // asserted to the core whenever this bit is set, which forces the
  // ROU dispatch gate to keep blocking. Set when halted_i pulses high;
  // cleared on a `resumereq=1, haltreq=0` dmcontrol write.
  logic            dm_halt_state_q;
  logic [    31:0] data0_q;
  logic [     2:0] cmderr_q;

  // Debug-only CSR storage (RV-Debug 1.0 §4). Only written via abstract
  // access_register; the running core never sees these via csrr/csrw
  // (no architectural Debug Mode entry implemented yet).
  logic [    31:0] dcsr_q;  // dcsr is fixed 32-bit per spec
  logic [XLEN-1:0] dpc_q;
  logic [XLEN-1:0] dscratch0_q;
  logic [XLEN-1:0] dscratch1_q;

  // Single-step bookkeeping. When the host issues a resumereq with
  // dcsr.step=1, we set step_pending_q, release the core, and on the
  // first `commit_fire_i` pulse re-assert the sticky halt latch and
  // populate dcsr.cause = 4 (step). This emulates Debug Mode single-step
  // without a real Debug Mode FSM (good enough for GDB `si`).
  logic            step_pending_q;

  // ----------------------------------------------------------
  // Abstract command decode (combinational on the in-flight DMI write)
  // ----------------------------------------------------------
  // Field layout from `command` per Debug Spec 1.0 §3.6:
  //   [31:24] cmdtype, [22:20] aarsize, [19] aarpostincrement,
  //   [18] postexec, [17] transfer, [16] write, [15:0] regno.
  logic [     7:0] cmd_cmdtype;
  logic [     2:0] cmd_aarsize;
  logic            cmd_aarpostinc;
  logic            cmd_postexec;
  logic            cmd_transfer;
  logic            cmd_write;
  logic [    15:0] cmd_regno;
  assign cmd_cmdtype    = dmi_wdata[31:24];
  assign cmd_aarsize    = dmi_wdata[22:20];
  assign cmd_aarpostinc = dmi_wdata[19];
  assign cmd_postexec   = dmi_wdata[18];
  assign cmd_transfer   = dmi_wdata[17];
  assign cmd_write      = dmi_wdata[16];
  assign cmd_regno      = dmi_wdata[15:0];

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

  // Read mux (XLEN-wide; data0 takes the low 32 bits).
  logic [XLEN-1:0] reg_rdata;
  always_comb begin
    reg_rdata = '0;
    if (cmd_is_gpr) reg_rdata = dbg_gpr_rdata_i[cmd_gpr_idx];
    else if (cmd_is_misa) reg_rdata = `RAPT_MISA;
    else if (cmd_is_dcsr) reg_rdata = XLEN'(dcsr_q);
    else if (cmd_is_dpc) reg_rdata = dpc_q;
    else if (cmd_is_dscr0) reg_rdata = dscratch0_q;
    else if (cmd_is_dscr1) reg_rdata = dscratch1_q;
    // cmd_is_trig_raz: zero (default).
  end

  // Validity gates for issuing the command this cycle.
  logic cmd_write_now;  // DMI write to AddrCommand on this rising edge
  logic cmd_accept;  // command passes all preconditions -> execute
  logic cmd_unsupported;  // accept but unsupported reg/aarsize -> cmderr=2
  logic cmd_halt_err;  // not halted -> cmderr=4
  // Effective halted-for-DM-purposes: either the core is currently halted
  // OR we already latched the halted state. Used by the abstract-command
  // halt gate and by dmstatus.{any,all}halted.
  logic halted_eff;
  assign halted_eff = halted_i || dm_halt_state_q;

  assign cmd_write_now   = dmactive_q && dmi_req && dmi_wr
                         && (dmi_addr == AddrCommand)
                         && (cmderr_q == 3'd0);
  assign cmd_halt_err = cmd_write_now && !halted_eff;
  assign cmd_unsupported = cmd_write_now && halted_eff
                         && ((cmd_cmdtype != 8'd0)
                             || (cmd_aarsize != 3'd2)
                             || cmd_aarpostinc || cmd_postexec
                             || (cmd_transfer && !cmd_reg_supported));
  assign cmd_accept      = cmd_write_now && halted_eff
                         && (cmd_cmdtype == 8'd0)
                         && (cmd_aarsize == 3'd2)
                         && !cmd_aarpostinc && !cmd_postexec
                         && (!cmd_transfer || cmd_reg_supported);

  // ----------------------------------------------------------
  // Sequential
  // ----------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      dmactive_q      <= 1'b0;
      ndmreset_q      <= 1'b0;
      haltreq_q       <= 1'b0;
      resumereq_q     <= 1'b0;
      resumeack_q     <= 1'b0;
      dm_halt_state_q <= 1'b0;
      data0_q         <= '0;
      cmderr_q        <= 3'd0;
      dcsr_q          <= 32'h4000_0000;  // xdebugver=4, all else 0
      dpc_q           <= '0;
      dscratch0_q     <= '0;
      dscratch1_q     <= '0;
      step_pending_q  <= 1'b0;
    end else if (!dmactive_q) begin
      // dmactive=0 holds DM in reset except for dmactive itself.
      ndmreset_q      <= 1'b0;
      haltreq_q       <= 1'b0;
      resumereq_q     <= 1'b0;
      resumeack_q     <= 1'b0;
      dm_halt_state_q <= 1'b0;
      data0_q         <= '0;
      cmderr_q        <= 3'd0;
      // dcsr/dpc/dscratch are NOT cleared by dmactive=0 per spec; only by
      // hard reset.
      if (dmi_req && dmi_wr && dmi_addr == AddrDmcontrol) begin
        dmactive_q <= dmi_wdata[0];
      end
    end else begin
      // Per-DMI-write side-effects.
      if (dmi_req && dmi_wr) begin
        unique case (dmi_addr)
          AddrDmcontrol: begin
            dmactive_q  <= dmi_wdata[0];
            ndmreset_q  <= dmi_wdata[1];
            resumereq_q <= dmi_wdata[30];
            haltreq_q   <= dmi_wdata[31];
            // Per spec: writing haltreq=1 clears resumeack; writing
            // resumereq=1 (with haltreq=0) starts a fresh ack window.
            if (dmi_wdata[31]) resumeack_q <= 1'b0;
            if (dmi_wdata[30] && !dmi_wdata[31]) resumeack_q <= 1'b0;
          end
          AddrData0: data0_q <= dmi_wdata;
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
          if (cmd_is_dcsr) dcsr_q <= data0_q;
          else if (cmd_is_dpc) dpc_q <= XLEN'(data0_q);
          else if (cmd_is_dscr0) dscratch0_q <= XLEN'(data0_q);
          else if (cmd_is_dscr1) dscratch1_q <= XLEN'(data0_q);
          // cmd_is_misa: read-only, silently dropped (spec allows either).
        end else begin
          // register -> data0 (low 32 bits for XLEN>32 today).
          data0_q <= reg_rdata[31:0];
        end
      end

      // Latch resume-ack when the core leaves the halted state after a
      // resume request (one-shot); independent of DMI write activity.
      if (resumereq_q && !haltreq_q && !halted_i) begin
        resumeack_q <= 1'b1;
      end

      // Sticky DM halt state: latch on any halted_i pulse so the abstract
      // command path keeps working after host deasserts haltreq, and the
      // core stays halted (haltreq_o stays high) until a resumereq write.
      if (halted_i) dm_halt_state_q <= 1'b1;
      // On the rising edge of halted_i (entering halt), capture the
      // resume PC into dpc so OpenOCD/GDB can read it back.
      if (halted_i && !dm_halt_state_q) dpc_q <= halt_pc_i;
      if (dmi_req && dmi_wr && dmi_addr == AddrDmcontrol && dmi_wdata[30] && !dmi_wdata[31]) begin
        // resumereq=1 with haltreq=0 -> release the core. If dcsr.step=1
        // arm a single-step: the first commit_fire after release will
        // re-halt the core via dm_halt_state_q below.
        dm_halt_state_q <= 1'b0;
        step_pending_q  <= dcsr_q[2];
      end

      // Single-step counter: while step_pending and core not halted,
      // re-arm sticky halt on the first commit pulse and update dcsr.cause.
      if (step_pending_q && !halted_i && commit_fire_i) begin
        dm_halt_state_q <= 1'b1;
        step_pending_q  <= 1'b0;
        // dcsr[8:6] = cause. 4 = step (Debug Spec 1.0 §4.8).
        dcsr_q[8:6]     <= 3'd4;
      end
    end
  end

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
  assign dmstatus_val = {
    14'b0,
    resumeack_q,
    resumeack_q,  // [17:16]
    4'b0,  // [15:12]
    ~halted_eff,
    ~halted_eff,  // [11:10]
    halted_eff,
    halted_eff,  // [9:8]
    1'b1,  // [7] authenticated
    3'b0,  // [6:4]
    4'd3  // [3:0] version=3 (1.0)
  };

  logic [31:0] dmcontrol_rd;
  assign dmcontrol_rd = {
    haltreq_q,  // [31] R: shows last-written haltreq
    resumereq_q,  // [30] R: ditto
    28'b0,  // [29:2] omitted (hartreset, hasel, hartsel, etc. = 0)
    ndmreset_q,  // [1]
    dmactive_q  // [0]
  };

  logic [31:0] abstractcs_rd;
  // [3:0] datacount=1, [10:8] cmderr, [12] busy=0, [28:24] progbufsize=0
  assign abstractcs_rd = {3'b0, 5'd0, 10'b0, 1'b0, 1'b0, 1'b0, cmderr_q, 4'b0, 4'd1};

  always_comb begin
    dmi_rdata = '0;
    unique case (dmi_addr)
      AddrData0:      dmi_rdata = data0_q;
      AddrDmcontrol:  dmi_rdata = dmcontrol_rd;
      AddrDmstatus:   dmi_rdata = dmstatus_val;
      AddrHartinfo:   dmi_rdata = '0;
      AddrAbstractcs: dmi_rdata = abstractcs_rd;
      AddrCommand:    dmi_rdata = '0;  // RAZ
      default:        dmi_rdata = '0;
    endcase
  end

  assign dmi_resp    = 2'b00;  // always OK
  // Drive haltreq to the core whenever the host has requested halt OR we
  // already latched the halted state (so the core can't slip through after
  // host deasserts haltreq while polling dmstatus). Single-step honours
  // step_pending_q: while a step is in flight, haltreq_o stays low so the
  // dispatch gate in ROU lets exactly one uop through; the commit-fire
  // counter above sets dm_halt_state_q on the very next cycle.
  assign haltreq_o   = ((haltreq_q | dm_halt_state_q) & ~step_pending_q)
                       & dmactive_q;
  assign resumereq_o = resumereq_q & dmactive_q;
  assign ndmreset_o  = ndmreset_q  & dmactive_q;

  // Drive the debug-GPR write port for one cycle when an accepted abstract
  // command issues a transfer-write to a GPR target. rapt_prf samples this
  // on the same rising edge that latches the new dcsr_q / dpc_q above, so
  // the architectural and DM views stay in sync.
  assign dbg_gpr_we_o    = cmd_accept && cmd_transfer && cmd_write && cmd_is_gpr;
  assign dbg_gpr_addr_o  = cmd_gpr_idx;
  assign dbg_gpr_wdata_o = XLEN'(data0_q);

endmodule
