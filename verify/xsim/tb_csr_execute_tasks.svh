// Shared module-local tasks. Intentionally no include guard.
task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                         input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
  @(negedge clock);
  iss = '0;
  iss.valid = 1;
  iss.op1 = operand;
  // This helper uses x0 for read-only zero masks and x1 otherwise.
  // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
  iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
  iss.uop.imm = XLEN'(addr);
  iss.uop.execute.sys.valid = 1;
  iss.uop.execute.sys.csr_csw = op;
  #1;
  result = wb.result;
  if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
  rou_csr.valid = 1;
  rou_csr.csr_addr = addr;
  rou_csr.csr_wen = wb.csr_wen;
  rou_csr.csr_wdata = wb.csr_wdata;
  @(posedge clock);
  @(negedge clock);
  clear_commit();
  iss = '0;
endtask
task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
  logic [XLEN-1:0] ignored;
  operation(addr, 3'b001, value, ignored);
endtask
task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
  logic [XLEN-1:0] actual;
  operation(addr, 3'b010, 0, actual);
  if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
endtask
