`include "rapt.svh"

// L1 miss adapter: probe the shared L2 TLB before starting the existing PTW.
// Cancellation drains accepted PTE reads through the PTW's original protocol.
module rapt_cached_ptw #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit Enable = 0
) (
    input clock,
    input reset,
    input logic [8:0] asid,
    output rapt_pkg::l2tlb_req_t l2_req_o,
    input logic l2_ready_i,
    input rapt_pkg::l2tlb_rsp_t l2_rsp_i,

    input logic req_valid,
    input logic kill,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [XLEN-1:0] vaddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn,
    input logic mmu_en,
    input logic pbmte,
    input logic sbe,
    input logic req_store,
`ifdef RAPT_H_EXTENSION
    input logic guest_en,
    input logic vs_en,
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] vsatp_ppn,
    input logic g_en,
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] hgatp_ppn,
    input logic vs_priv_s,
    input logic vs_sum,
    input logic vs_mxr,
    input logic vs_pbmte,
    input logic g_mxr,
    input logic req_exec,
`endif

    output logic bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input  logic bus_arready,
    input  logic bus_rvalid,
    input  logic [XLEN-1:0] bus_rdata,

    output logic done,
    output logic fault,
    output logic access_fault,
`ifdef RAPT_H_EXTENSION
    output logic guest_fault,
    output logic [XLEN-1:2] fault_gpa,
    output logic fault_ptw,
    output logic [2:0] result_g_perm,
`endif
    output logic [XLEN-1:10] result_ptag,
    output logic [XLEN-1:12] result_vtag,
    // pte flags: {D,A,G,U,X,W,R} (bits 7..1 of PTE); valid when done=1
    output logic [6:0] result_pte,
    // Leaf PBMT; valid together with result_pte on done. Sv32 always uses PMA.
    output logic [1:0] result_pbmt,
    output logic [1:0] result_level,

    output logic busy
);
  if (!Enable) begin : g_bypass
    assign l2_req_o = '0;
    rapt_ptw #(.XLEN(XLEN)) walker (.*);
  end else begin : g_cached
    typedef enum logic [2:0] {
      IDLE,
      LOOKUP,
      RESPONSE,
      START,
      WALK,
      FILL
    } state_t;
    state_t state;
    rapt_pkg::l2tlb_req_t request_q;
    logic store_q, cancelled;
    logic walk_done, walk_fault, walk_access_fault, walk_busy;
    logic [XLEN-1:10] walk_ptag;
    logic [XLEN-1:12] walk_vtag;
    logic [6:0] walk_pte;
    logic [1:0] walk_pbmt;
    logic [1:0] walk_level;
    logic done_q, fault_q, access_fault_q;
    logic cacheable_ppn;
`ifdef RAPT_H_EXTENSION
    logic guest_en_q, vs_en_q, g_en_q;
    logic [`RAPT_CSR_SATP_PPN_W-1:0] vsatp_ppn_q, hgatp_ppn_q;
    logic vs_priv_s_q, vs_sum_q, vs_mxr_q, vs_pbmte_q, g_mxr_q, req_exec_q;
    logic [11:2] va_low_q;
    logic walk_guest_fault, walk_fault_ptw;
    logic [XLEN-1:2] walk_fault_gpa;
    logic [2:0] walk_result_g_perm;
    logic guest_fault_q, fault_ptw_q;
    logic [XLEN-1:2] fault_gpa_q;
    logic [2:0] result_g_perm_q;
    wire [11:2] walker_va_low = va_low_q;
`else
    wire [11:2] walker_va_low = 10'b0;
`endif
    // Keep an unsupported full PPN on the completion path so the requester
    // preserves page-permission priority, access-fault cause and virtual tval.
    assign cacheable_ppn = rapt_pkg::tlb_ppn_fits(request_q.ptag);

    assign busy = state != IDLE;
    assign done = done_q && !kill;
    assign fault = fault_q && !kill;
    assign access_fault = access_fault_q && !kill;
`ifdef RAPT_H_EXTENSION
    assign guest_fault = guest_fault_q && !kill;
    assign fault_gpa = fault_gpa_q;
    assign fault_ptw = fault_ptw_q;
    assign result_g_perm = result_g_perm_q;
`endif
    assign result_vtag = request_q.vtag;
    assign result_ptag = request_q.ptag;
    assign result_pte = request_q.pte;
    assign result_pbmt = request_q.pbmt;
    assign result_level = request_q.level;
    always_comb begin
      l2_req_o = request_q;
      l2_req_o.valid = (state == LOOKUP || (state == FILL && cacheable_ppn)) && !kill && !reset;
      l2_req_o.fill = state == FILL;
    end

    rapt_ptw #(
        .XLEN(XLEN)
    ) walker (
        .clock(clock),
        .reset(reset),
        .req_valid(state == START),
        .kill(kill),
        .vaddr({request_q.vtag, walker_va_low, 2'b00}),
        .satp_ppn(request_q.root),
        .mmu_en(1'b1),
        .pbmte(request_q.pbmte),
        .sbe(request_q.sbe),
        .req_store(store_q),
`ifdef RAPT_H_EXTENSION
        .guest_en(guest_en_q),
        .vs_en(vs_en_q),
        .vsatp_ppn(vsatp_ppn_q),
        .g_en(g_en_q),
        .hgatp_ppn(hgatp_ppn_q),
        .vs_priv_s(vs_priv_s_q),
        .vs_sum(vs_sum_q),
        .vs_mxr(vs_mxr_q),
        .vs_pbmte(vs_pbmte_q),
        .g_mxr(g_mxr_q),
        .req_exec(req_exec_q),
`endif
        .bus_arvalid(bus_arvalid),
        .bus_araddr(bus_araddr),
        .bus_arready(bus_arready),
        .bus_rvalid(bus_rvalid),
        .bus_rdata(bus_rdata),
        .done(walk_done),
        .fault(walk_fault),
        .access_fault(walk_access_fault),
`ifdef RAPT_H_EXTENSION
        .guest_fault(walk_guest_fault),
        .fault_gpa(walk_fault_gpa),
        .fault_ptw(walk_fault_ptw),
        .result_g_perm(walk_result_g_perm),
`endif
        .result_ptag(walk_ptag),
        .result_vtag(walk_vtag),
        .result_pte(walk_pte),
        .result_pbmt(walk_pbmt),
        .result_level(walk_level),
        .busy(walk_busy)
    );

    always_ff @(posedge clock) begin
      if (reset) begin
        state <= IDLE;
        request_q <= '0;
        store_q <= 1'b0;
        cancelled <= 1'b0;
        done_q <= 1'b0;
        fault_q <= 1'b0;
        access_fault_q <= 1'b0;
`ifdef RAPT_H_EXTENSION
        guest_en_q <= 1'b0;
        guest_fault_q <= 1'b0;
        fault_gpa_q <= '0;
        fault_ptw_q <= 1'b0;
        result_g_perm_q <= 3'b111;
`endif
      end else begin
        done_q <= 1'b0;
        fault_q <= 1'b0;
        access_fault_q <= 1'b0;
`ifdef RAPT_H_EXTENSION
        guest_fault_q <= 1'b0;
`endif
        if (kill) begin
          // Keep ownership while the underlying walker drains its bus read.
          cancelled <= 1'b1;
          if (state != WALK || !walk_busy) state <= IDLE;
        end else begin
          case (state)
            IDLE: begin
              cancelled <= 1'b0;
              if (req_valid && mmu_en) begin
                request_q <= '0;
                request_q.vtag <= vaddr[XLEN-1:12];
                request_q.asid <= asid;
                request_q.root <= satp_ppn;
                request_q.pbmte <= pbmte;
                request_q.sbe <= sbe;
                store_q <= req_store;
`ifdef RAPT_H_EXTENSION
                guest_en_q <= guest_en;
                vs_en_q <= vs_en;
                vsatp_ppn_q <= vsatp_ppn;
                g_en_q <= g_en;
                hgatp_ppn_q <= hgatp_ppn;
                vs_priv_s_q <= vs_priv_s;
                vs_sum_q <= vs_sum;
                vs_mxr_q <= vs_mxr;
                vs_pbmte_q <= vs_pbmte;
                g_mxr_q <= g_mxr;
                req_exec_q <= req_exec;
                va_low_q <= vaddr[11:2];
                state <= guest_en ? START : LOOKUP;
`else
                state <= LOOKUP;
`endif
              end
            end
            LOOKUP: if (l2_ready_i) state <= RESPONSE;
            RESPONSE:
            if (l2_rsp_i.valid) begin
              if (l2_rsp_i.hit) begin
                request_q.ptag <= l2_rsp_i.ptag;
                request_q.pte <= l2_rsp_i.pte;
                request_q.pbmt <= l2_rsp_i.pbmt;
                request_q.level <= l2_rsp_i.level;
`ifdef RAPT_H_EXTENSION
                result_g_perm_q <= 3'b111;
`endif
                // Svade still applies when a read-filled entry is reused by
                // a store. R/W/X/U/SUM/MXR and PMP remain requester checks.
                if (!l2_rsp_i.pte[5] || (store_q && !l2_rsp_i.pte[6])) fault_q <= 1'b1;
                else done_q <= 1'b1;
                state <= IDLE;
              end else state <= START;
            end
            START: state <= WALK;
            WALK: begin
              if (cancelled) begin
                if (!walk_busy) state <= IDLE;
              end else if (walk_access_fault) begin
                access_fault_q <= 1'b1;
                state <= IDLE;
              end else if (walk_fault) begin
                fault_q <= 1'b1;
`ifdef RAPT_H_EXTENSION
                guest_fault_q <= walk_guest_fault;
                fault_gpa_q <= walk_fault_gpa;
                fault_ptw_q <= walk_fault_ptw;
`endif
                state <= IDLE;
              end else if (walk_done) begin
                request_q.ptag <= walk_ptag;
                request_q.vtag <= walk_vtag;
                request_q.pte <= walk_pte;
                request_q.pbmt <= walk_pbmt;
                request_q.level <= walk_level;
`ifdef RAPT_H_EXTENSION
                result_g_perm_q <= walk_result_g_perm;
                if (guest_en_q) begin
                  done_q <= 1'b1;
                  state <= IDLE;
                end else begin
                  state <= FILL;
                end
`else
                state <= FILL;
`endif
              end
            end
            FILL:
            if (!cacheable_ppn || l2_ready_i) begin
              done_q <= 1'b1;
              state <= IDLE;
            end
            default: state <= IDLE;
          endcase
        end
      end
    end
  end
endmodule
