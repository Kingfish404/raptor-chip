`include "rapt_if.svh"

// Actual integer execution ports, with shared public uop/identity and
// independent secret operand values. Decode and outer arbitration are outside
// this harness. All ALU op/word combinations are allowed (a superset of Zkt).
module formal_zkt_alu_ports (
    input rapt_pkg::issue_packet_t public_issue,
    input [`RAPT_XLEN-1:0] a0,
    b0,
    a1,
    b1
);
  rapt_pkg::issue_packet_t i0, i1;
  rapt_pkg::completion_t simple0, simple1, system0, system1;
  rapt_pkg::completion_t simple_control0, simple_control1;
  rapt_pkg::completion_t system_control0, system_control1;
  cmu_bcast_if cmu ();
  csr_bcast_if csr ();
  exu_csr_if exu0 (), exu1 ();
  assign csr.mtvec = '0;
  assign csr.tvec = '0;
  assign exu0.rdata = '0;
  assign exu1.rdata = '0;
  assign exu0.rmw_data = '0;
  assign exu1.rmw_data = '0;
  assign exu0.mepc = '0;
  assign exu1.mepc = '0;
  assign exu0.sepc = '0;
  assign exu1.sepc = '0;
  always_comb begin
    i0 = public_issue;
    i1 = public_issue;
    i0.op1 = a0;
    i0.op2 = b0;
    i1.op1 = a1;
    i1.op2 = b1;
    assume (public_issue.uop.execute.sys == '0);
    assume (public_issue.uop.execute.branch == '0);
    assume (!public_issue.uop.trap);
    if (`RAPT_XLEN == 32) assume (!public_issue.uop.execute.int_op.word);
    simple_control0 = simple0;
    simple_control0.result = '0;
    simple_control1 = simple1;
    simple_control1.result = '0;
    system_control0 = system0;
    system_control0.result = '0;
    system_control1 = system1;
    system_control1.result = '0;
    assert (simple0.valid == public_issue.valid);
    assert (system0.valid == public_issue.valid);
    assert (simple_control0 == simple_control1);
    assert (system_control0 == system_control1);
    cover(public_issue.valid && a0 != a1 && b0 != b1
        && simple0.result != simple1.result && system0.result != system1.result);
    cover (public_issue.valid && public_issue.uop.c);
    if (`RAPT_XLEN == 64) cover (public_issue.valid && public_issue.uop.execute.int_op.word);
  end
  rapt_ieu_pipe_alu simple_left (
      .iss(i0),
      .wb_alu(simple0)
  );
  rapt_ieu_pipe_alu simple_right (
      .iss(i1),
      .wb_alu(simple1)
  );
  rapt_ieu_pipe_alu_csr system_left (
      .cmu_bcast(cmu),
      .iss(i0),
      .csr_bcast(csr),
      .exu_csr(exu0),
      .wb_alu_csr(system0)
  );
  rapt_ieu_pipe_alu_csr system_right (
      .cmu_bcast(cmu),
      .iss(i1),
      .csr_bcast(csr),
      .exu_csr(exu1),
      .wb_alu_csr(system1)
  );
endmodule
