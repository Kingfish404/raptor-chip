`ifndef RAPT_SVA_SVH
`define RAPT_SVA_SVH
`define RAPT_SVA_ACTIVE

// Formal staging adapter for the single-clock, same-edge/next-edge RAPT
// contracts used by dm_debug.sby. Slang accepts clocked immediate assertions;
// the simulation header's temporal SVA and action blocks are not supported.
// The valid bit also disables a next-edge obligation across synchronous reset.
`define RAPT_SVA(clk, rst, name, expr) \
  always_ff @(posedge clk) begin \
    if (!(rst)) begin \
      name``_formal: assert (expr); \
    end \
  end

`define RAPT_SVA_IMPLY(clk, rst, name, ante, cons) \
  `RAPT_SVA(clk, rst, name, !(ante) || (cons))

`define RAPT_SVA_NEXT(clk, rst, name, ante, cons) \
  logic name``_valid_q = 1'b0; \
  logic name``_ante_q; \
  always_ff @(posedge clk) begin \
    name``_valid_q <= !(rst); \
    name``_ante_q <= ante; \
    if (!(rst) && name``_valid_q && name``_ante_q) begin \
      name``_formal: assert (cons); \
    end \
  end

`define RAPT_COVER(clk, rst, name, expr) \
  always_ff @(posedge clk) begin \
    if (!(rst)) begin \
      name``_formal: cover (expr); \
    end \
  end

`define RAPT_SVA_IMM(name, cond) assert (cond);
`endif
