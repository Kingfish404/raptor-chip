`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// rapt_plic -- Platform-Level Interrupt Controller (PLIC)
//
// Reference:
//   https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic-1.0.0.pdf
//   nemu/src/device/intr.c (functional reference used by difftest)
//
// Configuration (parameterised, defaults from rapt_soc.svh):
//   NDEV  = number of external interrupt sources (1..NDEV; source 0 reserved).
//           Capped at 31 so all per-source bit-vectors fit in one 32-bit word.
//   NCTX  = number of contexts. NCTX = 2 with NHART = 1 means
//           ctx0 = M-mode hart 0, ctx1 = S-mode hart 0.
//
// Register map (all registers 32-bit, naturally aligned):
//   0x000000 + 4*src                 priority[src]   (RW, 3 bits)
//   0x001000                         pending word 0  (RO)
//   0x002000 + 0x80*ctx              enable word 0   (RW)
//   0x200000 + 0x1000*ctx + 0        threshold[ctx]  (RW, 3 bits)
//   0x200000 + 0x1000*ctx + 4        claim/complete  (RW)
//
// Bus interface (single-cycle posted writes, combinational reads). The
// cluster pulses `plic_bus.ar_commit` for one cycle at the AR handshake of an
// internal read so the PLIC can apply the claim-read side effect (clear the
// pending bit of the highest-priority source) atomically with the data
// leaving for the core.
module rapt_plic #(
    parameter int XLEN  = `RAPT_XLEN,
    parameter int NDEV  = `RAPT_PLIC_NDEV,
    parameter int NCTX  = `RAPT_PLIC_NCTX,
    parameter int NHART = (NCTX + 1) / 2
) (
    input clock,
    input reset,

    plic_bus_if.slave plic_bus
);
  // Width helpers (avoid 0-width when NDEV=1).
  // CamelCase to satisfy verible parameter-name-style.
  localparam int IdW = (NDEV <= 1) ? 1 : $clog2(NDEV + 1);

  // ---------------------------------------------------------------------
  // Address-map constants (24-bit offset within the 16 MB PLIC window;
  // widened to 32 bits for arithmetic to keep Verilator's width checker
  // happy).
  // ---------------------------------------------------------------------
  localparam logic [31:0] PendBase  = 32'h0000_1000;
  localparam logic [31:0] EnBase    = 32'h0000_2000;
  localparam logic [31:0] EnStride  = 32'h0000_0080;
  localparam logic [31:0] CtxBase   = 32'h0020_0000;
  localparam logic [31:0] CtxStride = 32'h0000_1000;

  // ---------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------
  logic [   2:0] priority_q [NDEV+1];
  logic [NDEV:0] pending_q;
  logic [NDEV:0] enable_q   [  NCTX];
  logic [   2:0] threshold_q[  NCTX];
  logic [NHART-1:0] meip_q;
  logic [NHART-1:0] seip_q;
  // A gateway admits at most one request per source until software claims and
  // completes it. For a level source that remains asserted, completion opens
  // the gateway and causes a fresh request on the following cycle.
  logic [NDEV:0] gateway_busy_q;
  // Retained as an observation-only snapshot for NPC checkpoint diagnostics.
  // Gateway behavior must not depend on edge detection from this register.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NDEV:0] ext_irq_q;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------------
  // Pure-functional address decode helpers. Verilator only sees the low
  // 24 bits of the cluster-aligned PLIC address, but the helpers operate
  // on a 32-bit internal `off` so all arithmetic stays width-clean.
  // ---------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] off_of(input logic [XLEN-1:0] a);
    off_of = {8'b0, a[23:0]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic int prio_idx(input logic [31:0] off);
    prio_idx = (off < (NDEV + 1) * 4) ? int'(off >> 2) : -1;
  endfunction

  function automatic logic is_pending(input logic [31:0] off);
    is_pending = (off >= PendBase) && (off < PendBase + 32'h4);
  endfunction

  function automatic int en_ctx(input logic [31:0] off);
    if (off >= EnBase && off < EnBase + EnStride * NCTX)
      en_ctx = int'((off - EnBase) / EnStride);
    else en_ctx = -1;
  endfunction

  function automatic int ctx_idx(input logic [31:0] off);
    if (off >= CtxBase && off < CtxBase + CtxStride * NCTX)
      ctx_idx = int'((off - CtxBase) / CtxStride);
    else ctx_idx = -1;
  endfunction

  function automatic logic [11:0] ctx_reg(input logic [31:0] off);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] m;
    /* verilator lint_on UNUSEDSIGNAL */
    m = (off - CtxBase) % CtxStride;
    ctx_reg = m[11:0];
  endfunction

  // ---------------------------------------------------------------------
  // Read-side decoded signals (combinational from `plic_bus.araddr`). These feed
  // the read mux and the claim atomic in the always_ff block -- keeping
  // those pure non-blocking.
  // ---------------------------------------------------------------------
  logic [31:0] r_off;
  int          r_pidx;
  int          r_ectx;
  int          r_cctx;
  logic [11:0] r_creg;

  always_comb begin
    r_off  = off_of(plic_bus.araddr);
    r_pidx = prio_idx(r_off);
    r_ectx = en_ctx(r_off);
    r_cctx = ctx_idx(r_off);
    r_creg = ctx_reg(r_off);
  end

  // ---------------------------------------------------------------------
  // Write-side decoded signals (combinational from `plic_bus.awaddr`).
  // ---------------------------------------------------------------------
  logic [31:0] w_off;
  int          w_pidx;
  int          w_ectx;
  int          w_cctx;
  logic [11:0] w_creg;

  always_comb begin
    w_off  = off_of(plic_bus.awaddr);
    w_pidx = prio_idx(w_off);
    w_ectx = en_ctx(w_off);
    w_cctx = ctx_idx(w_off);
    w_creg = ctx_reg(w_off);
  end

  // ---------------------------------------------------------------------
  // Highest-priority pending+enabled source per context (combinational).
  // ---------------------------------------------------------------------
  logic [IdW-1:0] best_id  [NCTX];
  logic [    2:0] best_prio[NCTX];
  logic           ctx_irq_level[NCTX];

  always_comb begin
    for (int c = 0; c < NCTX; c++) begin
      best_id[c]        = '0;
      best_prio[c]      = threshold_q[c];
      ctx_irq_level[c]  = 1'b0;
      for (int s = 1; s <= NDEV; s++) begin
        if (pending_q[s] && enable_q[c][s] && (priority_q[s] > threshold_q[c])) begin
          ctx_irq_level[c] = 1'b1;
        end
        if (pending_q[s] && enable_q[c][s] && (priority_q[s] > best_prio[c])) begin
          best_prio[c] = priority_q[s];
          best_id[c]   = IdW'(s);
        end
      end
    end
  end

  // Map per-context IRQ level onto per-hart meip/seip. The hart-level outputs
  // are registered below to keep the PLIC priority tree out of the core CSR and
  // dispatch operand timing cones.
  logic [NHART-1:0] meip_next;
  logic [NHART-1:0] seip_next;

  assign plic_bus.meip = meip_q;
  assign plic_bus.seip = seip_q;

  always_comb begin
    int h;
    meip_next = '0;
    seip_next = '0;
    for (int hh = 0; hh < NHART; hh++) begin
      meip_next[hh] = 1'b0;
      seip_next[hh] = 1'b0;
    end
    for (int c = 0; c < NCTX; c++) begin
      h = c / 2;
      if (h < NHART) begin
        if ((c & 1) == 0) meip_next[h] = ctx_irq_level[c];
        else seip_next[h] = ctx_irq_level[c];
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read mux (combinational).
  // ---------------------------------------------------------------------
  logic [31:0] r_eoff;
  always_comb begin
    r_eoff    = (r_off - EnBase) - EnStride * r_ectx;
    plic_bus.rdata = '0;
    if (r_pidx >= 0) begin
      plic_bus.rdata = {{(XLEN - 3) {1'b0}}, priority_q[r_pidx]};
    end else if (is_pending(r_off)) begin
      plic_bus.rdata = {{(XLEN - (NDEV + 1)) {1'b0}}, pending_q};
    end else if (r_ectx >= 0) begin
      if (r_eoff < 32'h4) plic_bus.rdata = {{(XLEN - (NDEV + 1)) {1'b0}}, enable_q[r_ectx]};
    end else if (r_cctx >= 0) begin
      if (r_creg == 12'h0) plic_bus.rdata = {{(XLEN - 3) {1'b0}}, threshold_q[r_cctx]};
      else if (r_creg == 12'h4) plic_bus.rdata = {{(XLEN - IdW) {1'b0}}, best_id[r_cctx]};
    end
  end

  // ---------------------------------------------------------------------
  // Sequential state -- uses only non-blocking assignments. All address
  // decoding is done above in always_comb blocks.
  // ---------------------------------------------------------------------
  logic [31:0] w_eoff;
  assign w_eoff = (w_off - EnBase) - EnStride * w_ectx;

  logic claim_fire;
  logic [IdW-1:0] claim_id;
  logic complete_fire;
  logic [IdW-1:0] complete_id;
  logic complete_id_claimed;
  logic sw_pending_set;
  logic [NDEV:0] pending_next;
  logic [NDEV:0] gateway_busy_next;

  assign claim_fire = plic_bus.ar_commit && r_cctx >= 0 && r_creg == 12'h4
                      && best_id[r_cctx] != '0;
  assign claim_id = claim_fire ? best_id[r_cctx] : '0;
  assign complete_id = plic_bus.wdata[IdW-1:0];
  assign complete_fire = plic_bus.wvalid && w_cctx >= 0 && w_creg == 12'h4
                         && complete_id_claimed;
  assign sw_pending_set = plic_bus.wvalid && is_pending(w_off);

  always_comb begin
    complete_id_claimed = 1'b0;
    for (int s = 1; s <= NDEV; s++) begin
      if (complete_id == IdW'(s) && gateway_busy_q[s] && !pending_q[s]) begin
        complete_id_claimed = 1'b1;
      end
    end
  end

  // One priority mux per source. Claim wins over request admission for IP;
  // completion only releases a gateway whose request has already been claimed.
  always_comb begin
    pending_next = pending_q;
    gateway_busy_next = gateway_busy_q;
    pending_next[0] = 1'b0;
    gateway_busy_next[0] = 1'b0;
    for (int s = 1; s <= NDEV; s++) begin
      if (!gateway_busy_q[s]
          && (plic_bus.ext_irq[s] || (sw_pending_set && plic_bus.wdata[s]))) begin
        pending_next[s] = 1'b1;
        gateway_busy_next[s] = 1'b1;
      end
      if (claim_fire && claim_id == IdW'(s)) pending_next[s] = 1'b0;
      if (complete_fire && complete_id == IdW'(s)) gateway_busy_next[s] = 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      pending_q      <= '0;
      gateway_busy_q <= '0;
      ext_irq_q      <= '0;
      meip_q         <= '0;
      seip_q         <= '0;
      for (int s = 0; s <= NDEV; s++) priority_q[s] <= '0;
      for (int c = 0; c < NCTX; c++) begin
        enable_q[c]    <= '0;
        threshold_q[c] <= '0;
      end
    end else begin
      meip_q <= meip_next;
      seip_q <= seip_next;
      ext_irq_q <= plic_bus.ext_irq;
      pending_q <= pending_next;
      gateway_busy_q <= gateway_busy_next;

      // Write side.
      if (plic_bus.wvalid) begin
        if (w_pidx > 0 && w_pidx <= NDEV) begin
          priority_q[w_pidx] <= plic_bus.wdata[2:0];
        end else if (is_pending(w_off)) begin
          // SW pending-set extension is handled by the per-source gateway
          // mux above so it obeys the same one-outstanding-request rule.
        end else if (w_ectx >= 0 && w_eoff < 32'h4) begin
          // Source 0 hardwired to 0 in the enable bitmap.
          enable_q[w_ectx] <= {plic_bus.wdata[NDEV:1], 1'b0};
        end else if (w_cctx >= 0 && w_creg == 12'h0) begin
          threshold_q[w_cctx] <= plic_bus.wdata[2:0];
          // w_creg == 12'h4 (complete) is handled by the gateway mux above.
        end
      end
    end
  end

endmodule
