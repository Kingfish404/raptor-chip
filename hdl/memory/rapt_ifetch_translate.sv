`include "rapt.svh"
`include "rapt_if.svh"

// Translation adapter for the per-word fetch controller. Every accepted
// request produces one response, even after cancellation. A killed PTW does
// not itself pulse done/fault, so its busy falling is explicitly acknowledged.
// The caller discards the response of a cancelled architectural instruction.
module rapt_ifetch_translate #(
    parameter int XLEN = `RAPT_XLEN
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
  wire [1:0] pmp_fault;
  wire [XLEN-1:0] pmp_addr[2];
  logic pte_access_fault, target_access_fault;

  assign request_ready = state == IDLE && !kill;
  assign response_valid = state == REPLY;
  assign pmp_addr[0] = bus_araddr;
  assign pmp_addr[1] = response_paddr;
  assign pte_access_fault = pmp_fault[0]
      || !rapt_pkg::addr_ptw_readable(bus_araddr, 4'(XLEN / 8 - 1));
  assign target_access_fault = pmp_fault[1]
      || !rapt_pkg::addr_executable(response_paddr, 4'd3);
  // Do not derive kill from ptw_arvalid: PTW gates arvalid with kill.
  assign ptw_kill = kill || state == DRAIN
      || (state == WALK && ptw_busy && (pte_access_fault || (bus_rvalid && bus_rerror)));
  assign bus_arvalid = state == WALK && ptw_arvalid && !pte_access_fault && !kill;

  for (genvar port_idx = 0; port_idx < 2; port_idx++) begin : g_pmp
    rapt_pmp #(
        .XLEN(XLEN)
    ) u_pmp (
        .addr(pmp_addr[port_idx]),
        .size_m1(port_idx == 0 ? 4'(XLEN/8-1) : 4'd3),
        // Implicit page-table reads use supervisor privilege even for U fetch.
        .priv(port_idx == 0 ? `RAPT_PRIV_S : priv_q),
        .op_r(port_idx == 0),
        .op_w(1'b0),
        .op_x(port_idx == 1),
        .pmp_raw_addr(pmp_state.pmp_raw_addr),
        .pmp_napot_mask(pmp_state.pmp_napot_mask),
        .pmp_cfg_r(pmp_state.pmp_cfg_r),
        .pmp_cfg_w(pmp_state.pmp_cfg_w),
        .pmp_cfg_x(pmp_state.pmp_cfg_x),
        .pmp_cfg_l(pmp_state.pmp_cfg_l),
        .pmp_mode_off(pmp_state.pmp_mode_off),
        .pmp_mode_tor(pmp_state.pmp_mode_tor),
        .pmp_mode_na4(pmp_state.pmp_mode_na4),
        .pmp_mode_napot(pmp_state.pmp_mode_napot),
        .fault(pmp_fault[port_idx]),
        .fault_lo_o()
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
      .bus_awvalid(),
      .bus_awaddr(),
      .bus_wvalid(),
      .bus_wdata(),
      .bus_wstrb(),
      .bus_wready(1'b0),
      .bus_werr(1'b0),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptag),
      .result_vtag(),
      .result_pte(pte),
      .result_pbmt(pbmt),
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
          response_paddr <= request_vaddr;
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
