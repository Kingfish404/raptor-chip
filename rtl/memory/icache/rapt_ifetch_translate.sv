`include "rapt.svh"
`include "rapt_if.svh"

// Translation adapter for the per-word fetch controller. Every accepted
// request produces one response, even after cancellation. A killed PTW does
// not itself pulse done/fault, so its busy falling is explicitly acknowledged.
// The caller discards the response of a cancelled architectural instruction.
module rapt_ifetch_translate #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit ExternalPmp = 1'b0
) (
    input logic clock,
    reset,
    kill,
    input logic request_valid,
    output logic request_ready,
    input logic [XLEN-1:0] request_vaddr,
    input logic mmu_en,
    pbmte,
    sbe,
    input logic [1:0] priv,
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn,
    pmp_state_if.in pmp_state,
    // The cache may lend its idle checker to this slow-path adapter.
    output logic [XLEN-1:0] pmp_addr_o,
    output logic [3:0] pmp_size_m1_o,
    output logic [1:0] pmp_priv_o,
    output logic pmp_read_o,
    input logic pmp_fault_i = 1'b0,
    pmp_read_fault_i = 1'b0,
    output logic response_valid,
    output logic [XLEN-1:0] response_paddr,
    output logic [1:0] response_pbmt,
    output logic response_fault,
    output logic [XLEN-1:0] response_cause,
    output logic bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input logic bus_arready,
    bus_rvalid,
    bus_rerror,
    input logic [XLEN-1:0] bus_rdata
);
  typedef enum logic [2:0] {
    IDLE,
    START,
    WALK,
    CHECK,
    DRAIN,
    REPLY
  } state_t;
  state_t state;
  logic [XLEN-1:0] va_q;
  logic [1:0] priv_q;
  logic pbmte_q, sbe_q;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] root_q;
  logic ptw_arvalid, ptw_busy, ptw_done, ptw_fault, ptw_kill;
  logic [XLEN-1:10] ptag;
  logic [6:0] pte;
  logic [1:0] pbmt;
  wire pmp_fault, pmp_read_fault;
  wire [XLEN-1:12] unused_result_vtag;
  wire [1:0] unused_result_level;
  wire check_target = state == CHECK;
  logic pte_access_fault, target_access_fault;

  assign request_ready = state == IDLE && !kill;
  assign response_valid = state == REPLY;
  assign pte_access_fault = pmp_read_fault || !rapt_pkg::addr_ptw_readable(
      bus_araddr, 4'(XLEN / 8 - 1)
  );
  assign target_access_fault = pmp_fault || !rapt_pkg::addr_executable(response_paddr, 4'd3);
  // Do not derive kill from ptw_arvalid: PTW gates arvalid with kill.
  assign ptw_kill = kill || state == DRAIN
      || (state == WALK && ptw_busy && (pte_access_fault || (bus_rvalid && bus_rerror)));
  assign bus_arvalid = state == WALK && ptw_arvalid && !pte_access_fault && !kill;

  // WALK consumes only the PTE verdict; CHECK consumes only the target
  // verdict. Both use one checker in their original cycles.
  assign pmp_addr_o = check_target ? response_paddr : bus_araddr;
  assign pmp_size_m1_o = check_target ? 4'd3 : 4'(XLEN / 8 - 1);
  // Implicit page-table reads use supervisor privilege even for U fetch.
  assign pmp_priv_o = check_target ? priv_q : `RAPT_PRIV_S;
  assign pmp_read_o = !check_target;
  if (ExternalPmp) begin : g_external_pmp
    assign pmp_fault = pmp_fault_i;
    assign pmp_read_fault = pmp_read_fault_i;
  end else begin : g_local_pmp
    assign pmp_read_fault = pmp_fault;
    rapt_pmp_check #(
        .XLEN(XLEN)
    ) u_pmp (
        .addr(pmp_addr_o),
        .size_m1(pmp_size_m1_o),
        .priv(pmp_priv_o),
        .op_r(pmp_read_o),
        .op_w(1'b0),
        .op_x(!pmp_read_o),
        .state(pmp_state),
        .fault(pmp_fault),
        /* verilator lint_off PINCONNECTEMPTY */
        .fault_lo_o(),
        .fault_read_o(),
        .fault_write_o()
        /* verilator lint_on PINCONNECTEMPTY */
    );
  end

  rapt_ptw #(
      .XLEN(XLEN)
  ) u_ptw (
      .clock(clock),
      .reset(reset),
      .req_valid(state == START && !kill),
      .kill(ptw_kill),
      .vaddr(va_q),
      .satp_ppn(root_q),
      .mmu_en(1'b1),
      .pbmte(pbmte_q),
      .sbe(sbe_q),
      .req_store(1'b0),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(bus_araddr),
      .bus_arready(bus_arready && bus_arvalid),
      .bus_rvalid(bus_rvalid),
      .bus_rdata(bus_rdata),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptag),
      .result_vtag(unused_result_vtag),
      .result_pte(pte),
      .result_pbmt(pbmt),
      .result_level(unused_result_level),
      .busy(ptw_busy)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      va_q <= '0;
      priv_q <= `RAPT_PRIV_M;
      root_q <= '0;
      pbmte_q <= 0;
      sbe_q <= 0;
      response_paddr <= '0;
      response_pbmt <= 0;
      response_fault <= 0;
      response_cause <= 0;
    end else begin
      case (state)
        IDLE:
        if (request_valid && request_ready) begin
          va_q <= request_vaddr;
          priv_q <= priv;
          root_q <= satp_ppn;
          pbmte_q <= pbmte;
          sbe_q <= sbe;
          response_paddr <= rapt_pkg::canonical_paddr(request_vaddr);
          response_pbmt <= 0;
          response_fault <= 0;
          response_cause <= 0;
          state <= mmu_en ? START : CHECK;
        end
        START: state <= kill ? REPLY : WALK;
        WALK: begin
          if (kill || (ptw_busy && (pte_access_fault || (bus_rvalid && bus_rerror)))) begin
            response_fault <= 1;
            response_cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
            state <= DRAIN;
          end else if (ptw_fault || (ptw_done && (!pte[2] || !pte[5]
              || (priv_q == `RAPT_PRIV_U && !pte[3])
              || (priv_q == `RAPT_PRIV_S && pte[3])))) begin
            response_fault <= 1;
            response_cause <= `RAPT_CAUSE_INSTR_PAGE_FAULT;
            state <= REPLY;
          end else if (ptw_done) begin
            response_paddr <= XLEN'({ptag, va_q[11:0]});
            response_pbmt <= pbmt;
            state <= CHECK;
          end
        end
        CHECK: begin
          response_fault <= target_access_fault;
          response_cause <= target_access_fault ? `RAPT_CAUSE_INSTR_ACC_FAULT : XLEN'(0);
          state <= REPLY;
        end
        DRAIN: if (!ptw_busy) state <= REPLY;
        REPLY: state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
