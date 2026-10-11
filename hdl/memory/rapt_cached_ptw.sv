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

    output logic bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input  logic bus_arready,
    input  logic bus_rvalid,
    input  logic [XLEN-1:0] bus_rdata,

    output logic bus_awvalid,
    output logic [XLEN-1:0] bus_awaddr,
    output logic bus_wvalid,
    output logic [XLEN-1:0] bus_wdata,
    output logic [7:0] bus_wstrb,
    input  logic bus_wready,
    input  logic bus_werr,

    output logic done,
    output logic fault,
    output logic [XLEN-1:10] result_ptag,
    output logic [XLEN-1:12] result_vtag,
    // pte flags: {D,A,G,U,X,W,R} (bits 7..1 of PTE); valid when done=1
    output logic [6:0] result_pte,
    // Leaf PBMT; valid together with result_pte on done. Sv32 always uses PMA.
    output logic [1:0] result_pbmt,

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
    logic walk_done, walk_fault, walk_busy;
    logic [XLEN-1:10] walk_ptag;
    logic [XLEN-1:12] walk_vtag;
    logic [6:0] walk_pte;
    logic [1:0] walk_pbmt;
    logic done_q, fault_q;

    assign busy = state != IDLE;
    assign done = done_q && !kill;
    assign fault = fault_q && !kill;
    assign result_vtag = request_q.vtag;
    assign result_ptag = request_q.ptag;
    assign result_pte = request_q.pte;
    assign result_pbmt = request_q.pbmt;
    always_comb begin
      l2_req_o = request_q;
      l2_req_o.valid = (state == LOOKUP || state == FILL) && !kill && !reset;
      l2_req_o.fill = state == FILL;
    end

    rapt_ptw #(
        .XLEN(XLEN)
    ) walker (
        .clock(clock),
        .reset(reset),
        .req_valid(state == START),
        .kill(kill),
        .vaddr({request_q.vtag, 12'b0}),
        .satp_ppn(request_q.root),
        .mmu_en(1'b1),
        .pbmte(request_q.pbmte),
        .sbe(request_q.sbe),
        .req_store(store_q),
        .bus_arvalid(bus_arvalid),
        .bus_araddr(bus_araddr),
        .bus_arready(bus_arready),
        .bus_rvalid(bus_rvalid),
        .bus_rdata(bus_rdata),
        .bus_awvalid(bus_awvalid),
        .bus_awaddr(bus_awaddr),
        .bus_wvalid(bus_wvalid),
        .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb),
        .bus_wready(bus_wready),
        .bus_werr(bus_werr),
        .done(walk_done),
        .fault(walk_fault),
        .result_ptag(walk_ptag),
        .result_vtag(walk_vtag),
        .result_pte(walk_pte),
        .result_pbmt(walk_pbmt),
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
      end else begin
        done_q <= 1'b0;
        fault_q <= 1'b0;
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
                state <= LOOKUP;
              end
            end
            LOOKUP: if (l2_ready_i) state <= RESPONSE;
            RESPONSE: if (l2_rsp_i.valid) begin
              if (l2_rsp_i.hit) begin
                request_q.ptag <= l2_rsp_i.ptag;
                request_q.pte <= l2_rsp_i.pte;
                request_q.pbmt <= l2_rsp_i.pbmt;
                // Svade still applies when a read-filled entry is reused by
                // a store. R/W/X/U/SUM/MXR and PMP remain requester checks.
                if (!l2_rsp_i.pte[5] || (store_q && !l2_rsp_i.pte[6]))
                  fault_q <= 1'b1;
                else done_q <= 1'b1;
                state <= IDLE;
              end else state <= START;
            end
            START: state <= WALK;
            WALK: begin
              if (cancelled) begin
                if (!walk_busy) state <= IDLE;
              end else if (walk_fault) begin
                fault_q <= 1'b1;
                state <= IDLE;
              end else if (walk_done) begin
                request_q.ptag <= walk_ptag;
                request_q.vtag <= walk_vtag;
                request_q.pte <= walk_pte;
                request_q.pbmt <= walk_pbmt;
                state <= FILL;
              end
            end
            FILL: if (l2_ready_i) begin
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
