`include "rapt_sva.svh"

// Architectural vector state. All mutation inputs are already-authorized
// single-cycle events from the owner; speculative dispatch is NOT a write.
// The owner serializes configuration, CSR accesses, and execution updates.
// Flush must not reset this module: a trapping vector instruction may have
// committed a prefix, whose vstart and register contents survive the trap.
module rapt_vpu_csr #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64
) (
    input logic clock,
    input logic reset,
    input logic vector_enabled,

    input logic cfg_valid,
    input logic [XLEN-1:0] cfg_vtype,
    input logic [XLEN-1:0] cfg_avl,
    input logic cfg_avl_max,
    input logic cfg_keep_vl,
    output logic cfg_illegal,
    output logic [XLEN-1:0] cfg_result,

    input logic csr_valid,
    input logic [11:0] csr_addr,
    input logic csr_write,
    // Caller resolves CSR RW/RS/RC semantics, including write suppression.
    // Upper write bits are WARL zero in the implemented vector CSRs.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [XLEN-1:0] csr_wdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [XLEN-1:0] csr_rdata,
    output logic csr_illegal,

    input logic exec_valid,
    input logic exec_fault,
    input logic exec_fof,
    input logic [$clog2(VLEN)-1:0] exec_vstart,
    input logic [XLEN-1:0] exec_vl,
    input logic exec_saturated,

    output logic [XLEN-1:0] vtype,
    output logic [XLEN-1:0] vl,
    output logic [$clog2(VLEN)-1:0] vstart,
    output logic [1:0] vxrm,
    output logic vxsat,
    // Commit controller folds this pulse into mstatus/sstatus.VS and SD.
    output logic dirty
);
  localparam int StartBits = $clog2(VLEN);
  logic [XLEN-1:0] next_vtype;
  // Geometry and vill are encoded in next_vtype; this owner only commits it.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] next_max;
  logic next_vill;
  /* verilator lint_on UNUSEDSIGNAL */
  logic cfg_fire, csr_fire, exec_fire;
  logic csr_exists, csr_readonly;

  rapt_vpu_vtype #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) u_vtype (
      .requested_vtype(cfg_vtype),
      .avl(cfg_avl),
      .avl_max(cfg_avl_max),
      .keep_vl(cfg_keep_vl),
      .current_vtype(vtype),
      .current_vl(vl),
      .next_vtype(next_vtype),
      .next_vl(cfg_result),
      .vlmax(next_max),
      .vill(next_vill)
  );
  assign cfg_illegal = cfg_valid && !vector_enabled;
  assign cfg_fire = cfg_valid && vector_enabled && !reset;
  assign csr_fire = csr_valid && csr_write && !csr_illegal && !reset;
  assign exec_fire = exec_valid && vector_enabled && !reset;
  assign dirty = cfg_fire || csr_fire || exec_fire;

  always_comb begin
    csr_rdata = '0;
    csr_exists = 1'b1;
    csr_readonly = 1'b0;
    case (csr_addr)
      12'h008: csr_rdata = XLEN'(vstart);
      12'h009: csr_rdata = XLEN'(vxsat);
      12'h00a: csr_rdata = XLEN'(vxrm);
      12'h00f: csr_rdata = XLEN'({vxrm, vxsat});
      12'hc20: begin csr_rdata = vl; csr_readonly = 1'b1; end
      12'hc21: begin csr_rdata = vtype; csr_readonly = 1'b1; end
      12'hc22: begin csr_rdata = XLEN'(VLEN/8); csr_readonly = 1'b1; end
      default: csr_exists = 1'b0;
    endcase
    csr_illegal = csr_valid && (!vector_enabled || !csr_exists || (csr_write && csr_readonly));
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      vtype <= {1'b1, {(XLEN-1){1'b0}}};
      vl <= '0;
      vstart <= '0;
      vxrm <= '0;
      vxsat <= 1'b0;
    end else begin
      if (cfg_fire) begin
        vtype <= next_vtype;
        vl <= cfg_result;
        vstart <= '0;
      end
      if (csr_fire) begin
        case (csr_addr)
          12'h008: vstart <= csr_wdata[StartBits-1:0];
          12'h009: vxsat <= csr_wdata[0];
          12'h00a: vxrm <= csr_wdata[1:0];
          12'h00f: begin vxrm <= csr_wdata[2:1]; vxsat <= csr_wdata[0]; end
          default: ;
        endcase
      end
      if (exec_fire) begin
        vstart <= exec_fault ? exec_vstart : '0;
        if (exec_fof && !exec_fault) vl <= exec_vl;
        vxsat <= vxsat || exec_saturated;
      end
    end
  end

  `RAPT_SVA(clock, reset, VPU_CSR_SINGLE_OWNER, $onehot0({cfg_valid, csr_valid, exec_valid}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_CSR_EXEC_ENABLED, exec_valid, vector_enabled)
  `RAPT_SVA_IMPLY(clock, reset, VPU_CSR_FOF_UPDATE, exec_valid && exec_fof,
                  !exec_fault && exec_vl <= vl)
endmodule
