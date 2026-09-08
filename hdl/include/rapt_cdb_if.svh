/* verilator lint_off DECLFILENAME */
`ifndef RAPT_CDB_IF_SVH
`define RAPT_CDB_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface load_fast_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned ROBLEN = $clog2(`RAPT_ROB_SIZE),
    parameter unsigned GENERATION_BITS = `RAPT_ROB_GENERATION_BITS,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
);
  logic valid;
  logic rebusy;
  logic [PLEN-1:0] prd;
  logic [ROBLEN-1:0] dest;
  logic [GENERATION_BITS-1:0] generation;
  logic [RLEN-1:0] rd;
  // Confirmation belongs to the early-wakeup protocol, not the global
  // completion fan-in. Only a latency-predictable producer drives this path.
  logic confirmed;
  logic [PLEN-1:0] confirmed_prd;
  logic [ROBLEN-1:0] confirmed_dest;
  logic [GENERATION_BITS-1:0] confirmed_generation;
  logic [RLEN-1:0] confirmed_rd;
  logic [XLEN-1:0] result;

  modport source(
      output valid, rebusy, prd, dest, generation, rd,
                        confirmed, confirmed_prd, confirmed_dest, confirmed_generation,
                        confirmed_rd, result
  );
  modport sink(
      input valid, rebusy, prd, dest, generation, rd,
                      confirmed, confirmed_prd, confirmed_dest, confirmed_generation,
                      confirmed_rd, result
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_CDB_IF_SVH
