`include "rapt.svh"
`include "rapt_if.svh"

module rapt_ieu #(
    parameter unsigned ALQ_SIZE = `RAPT_RS_SIZE,
    parameter unsigned BRQ_SIZE = 4,
    parameter unsigned MDQ_SIZE = 4,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    rou_exu_if.monitor rou_exu,
    dpu_iq_if.rs disp_alq,
    dpu_iq_if.rs disp_brq,
    dpu_iq_if.rs disp_mdq,
    cdb_if.in exu_ioq_bcast,
    load_fast_if.sink load_fast,
    input logic alu_csr_issue_enable,
    exu_csr_if.master exu_csr,
    cdb_if.out wb_alu_csr_raw,
    cdb_if wb_alu_csr,
    cdb_if wb_alu,
    cdb_if wb_branch,
    cdb_if exu_wb_mul,
    output logic pmu_ooo_valid,
    output logic pmu_ooo_valid_found,
    output logic pmu_ooo_full,
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_alu_csr ();
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_alu ();
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_branch ();
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_branch_unused ();

  logic [$clog2(ALQ_SIZE):0] occ_alq;
  logic [$clog2(BRQ_SIZE):0] occ_brq;
  logic pmu_alq_full_unused;
  logic pmu_brq_full_unused;

  assign pmu_ooo_valid = (occ_alq != '0) || (occ_brq != '0);
  assign pmu_ooo_valid_found = iss_alu_csr.valid || iss_alu.valid || iss_branch.valid;
  assign pmu_ooo_full = (occ_alq == ($clog2(ALQ_SIZE) + 1)'(ALQ_SIZE));

  rapt_iq #(
      .IQ_SIZE  (ALQ_SIZE),
      .HAS_ISS_B(1'b1),
      .ROB_SIZE (ROB_SIZE),
      .PLEN     (PLEN),
      .RLEN     (RLEN),
      .XLEN     (XLEN)
  ) u_alq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_alq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .issue_enable (alu_csr_issue_enable),
      .iss          (iss_alu_csr),
      .iss_b        (iss_alu),
      .occ_o        (occ_alq),
      .pmu_iq_full  (pmu_alq_full_unused)
  );

  rapt_iq #(
      .IQ_SIZE (BRQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_brq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_brq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .issue_enable (1'b1),
      .iss          (iss_branch),
      .iss_b        (iss_branch_unused),
      .occ_o        (occ_brq),
      .pmu_iq_full  (pmu_brq_full_unused)
  );

  rapt_ieu_pipe_alu_csr #(
      .ROB_SIZE(ROB_SIZE),
      .XLEN    (XLEN)
  ) u_pipe_alu_csr (
      .cmu_bcast (cmu_bcast),
      .iss       (iss_alu_csr),
      .csr_bcast (csr_bcast),
      .exu_csr   (exu_csr),
      .wb_alu_csr(wb_alu_csr_raw),
      .uop_pl    (uop_pl)
  );

  rapt_ieu_pipe_alu #(
      .XLEN(XLEN)
  ) u_pipe_alu (
      .iss   (iss_alu),
      .wb_alu(wb_alu)
  );

  rapt_ieu_pipe_branch #(
      .XLEN(XLEN)
  ) u_pipe_branch (
      .iss      (iss_branch),
      .wb_branch(wb_branch)
  );

  rapt_ieu_muldiv #(
      .MDQ_SIZE(MDQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_muldiv (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_mdq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul)
  );
endmodule
