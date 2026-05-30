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
  // Edge-detect on plic_bus.ext_irq so a level-held source doesn't perpetually
  // re-set pending_q after a complete (mirrors a typical PLIC RTL).
  logic [NDEV:0] ext_irq_q;

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
  logic           ctx_irq  [NCTX];

  always_comb begin
    for (int c = 0; c < NCTX; c++) begin
      best_id[c]   = '0;
      best_prio[c] = threshold_q[c];
      ctx_irq[c]   = 1'b0;
      for (int s = 1; s <= NDEV; s++) begin
        if (pending_q[s] && enable_q[c][s] && (priority_q[s] > best_prio[c])) begin
          best_prio[c] = priority_q[s];
          best_id[c]   = IdW'(s);
          ctx_irq[c]   = 1'b1;
        end
      end
    end
  end

  // Map per-context IRQ level onto per-hart meip/seip.
  always_comb begin
    int h;
    for (int hh = 0; hh < NHART; hh++) begin
      plic_bus.meip[hh] = 1'b0;
      plic_bus.seip[hh] = 1'b0;
    end
    for (int c = 0; c < NCTX; c++) begin
      h = c / 2;
      if (h < NHART) begin
        if ((c & 1) == 0) plic_bus.meip[h] = ctx_irq[c];
        else plic_bus.seip[h] = ctx_irq[c];
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

  always_ff @(posedge clock) begin
    if (reset) begin
      ext_irq_q <= '0;
      pending_q <= '0;
      for (int s = 0; s <= NDEV; s++) priority_q[s] <= '0;
      for (int c = 0; c < NCTX; c++) begin
        enable_q[c]    <= '0;
        threshold_q[c] <= '0;
      end
    end else begin
      // Edge-detect external sources.
      ext_irq_q <= plic_bus.ext_irq;
      for (int s = 1; s <= NDEV; s++) begin
        if (plic_bus.ext_irq[s] && !ext_irq_q[s]) pending_q[s] <= 1'b1;
      end
      pending_q[0] <= 1'b0;

      // Claim atomic: at AR handshake on a claim register, clear the
      // pending bit of the source we just returned.
      if (plic_bus.ar_commit && r_cctx >= 0 && r_creg == 12'h4 && best_id[r_cctx] != '0) begin
        pending_q[best_id[r_cctx]] <= 1'b0;
      end

      // Write side.
      if (plic_bus.wvalid) begin
        if (w_pidx > 0 && w_pidx <= NDEV) begin
          priority_q[w_pidx] <= plic_bus.wdata[2:0];
        end else if (is_pending(w_off)) begin
          // SW pending-set extension (non-spec, SiFive-style debug aid).
          // Per-bit set so we coexist with the edge-detect path that may
          // also be raising bits this cycle. Bit 0 is hardwired to 0.
          for (int s = 1; s <= NDEV; s++) begin
            if (plic_bus.wdata[s]) pending_q[s] <= 1'b1;
          end
        end else if (w_ectx >= 0 && w_eoff < 32'h4) begin
          // Source 0 hardwired to 0 in the enable bitmap.
          enable_q[w_ectx] <= {plic_bus.wdata[NDEV:1], 1'b0};
        end else if (w_cctx >= 0 && w_creg == 12'h0) begin
          threshold_q[w_cctx] <= plic_bus.wdata[2:0];
          // w_creg == 12'h4 (complete): no extra state -- pending was cleared
          // on claim; level sources re-arm via the rising-edge detector.
        end
      end
    end
  end

endmodule
