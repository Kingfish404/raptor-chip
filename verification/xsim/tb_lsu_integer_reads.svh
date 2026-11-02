// Use the production late-read interface for IOQ/SQ/L1D integration checks.
// The same physical bank model serves isolated IOQ and composed LSU tests.
logic [1:0][rapt_pkg::PLENPkg-1:0] test_int_sources[rapt_pkg::DispatchWidth];
logic [rapt_pkg::PLENPkg-1:0] test_operand_address[1];
logic [XLEN-1:0] test_operand_value[1];
logic test_operand_valid[1];
wire test_allocate[rapt_pkg::DispatchWidth];
wire test_retire = dut.u_ioq.ioq_valid_found;
assign test_allocate = disp_ioq.accept;
`include "tb_ioq_integer_reads.svh"
