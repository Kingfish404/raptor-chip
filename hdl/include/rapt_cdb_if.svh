/* verilator lint_off DECLFILENAME */
`ifndef RAPT_CDB_IF_SVH
`define RAPT_CDB_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface load_fast_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN
);
  logic valid;
  logic rebusy;
  logic [PLEN-1:0] prd;

  modport source(output valid, rebusy, prd);
  modport sink(input valid, rebusy, prd);
endinterface

interface cdb_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;
  logic mispredict;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest;
  logic [XLEN-1:0] result;
  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic fp_flags_valid;
  logic [4:0] fp_flags;
  logic wen;
  logic [5:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;
  logic [63:0] sq_wdata64;
  logic sq_fp64;
  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;
  logic difftest_skip;
  logic valid;
  /* verilator lint_on UNUSEDSIGNAL */

  modport in(
      input pc, npc, btaken, mispredict,
      input dest, result,
      input prd, rd,
      input csr_wen, csr_wdata, fp_flags_valid, fp_flags,
      input wen, alu, sq_waddr, sq_wdata, sq_wdata64, sq_fp64,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken, mispredict,
      output dest, result,
      output prd, rd,
      output csr_wen, csr_wdata, fp_flags_valid, fp_flags,
      output wen, alu, sq_waddr, sq_wdata, sq_wdata64, sq_fp64,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_CDB_IF_SVH
