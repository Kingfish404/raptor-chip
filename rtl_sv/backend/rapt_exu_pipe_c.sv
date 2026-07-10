`include "rapt.svh"
`include "rapt_if.svh"

// BRU pipe: dedicated branch resolution for conditional branches (ben).
//
// Only the 6 conditional-branch compare opcodes (BEQ/BNE/BLT/BGE/BLTU/BGEU
// -> ALU_EQ_/XOR_/SLT_/SGE_/SLTU/SGEU) are ever routed here, so a single
// taken/not-taken bit replaces a full XLEN-wide ALU (no shifter / Zbb /
// Zbs / CLMUL cones behind this pipe). Conditional branches never write
// rd and never produce values consumed downstream, so the writeback
// carries only ROB-state + branch-resolution fields (result/prd/rd tied 0
// -> no PRF write port, no bypass network entry).
/* verilator lint_off UNUSEDSIGNAL */
module rapt_exu_pipe_c #(
    parameter unsigned XLEN = `RAPT_XLEN
) (
    // Issue slot from the BRU issue queue
    exu_iq_iss_if.fu iss,

    // Writeback (CDB port [2])
    exu_wb_if.out exu_rou_c
);
  /* verilator lint_on UNUSEDSIGNAL */

  logic btaken_c;
  always_comb begin
    unique case (iss.alu)
      `RAPT_ALU_EQ__: btaken_c = (iss.op1 == iss.op2);                       // BEQ
      `RAPT_ALU_XOR_: btaken_c = (iss.op1 != iss.op2);                       // BNE: |s1^s2
      `RAPT_ALU_SLT_: btaken_c = ($signed(iss.op1) < $signed(iss.op2));      // BLT
      `RAPT_ALU_SGE_: btaken_c = ($signed(iss.op1) >= $signed(iss.op2));     // BGE
      `RAPT_ALU_SLTU: btaken_c = (iss.op1 < iss.op2);                        // BLTU
      `RAPT_ALU_SGEU: btaken_c = (iss.op1 >= iss.op2);                       // BGEU
      default:        btaken_c = 1'b0;
    endcase
  end

  logic [XLEN-1:0] addr_exu_c;
  assign addr_exu_c = (iss.pc + iss.imm) & ~'b1;

  // === Writeback ===
  assign exu_rou_c.valid = iss.valid;
  assign exu_rou_c.dest = iss.dest;
  assign exu_rou_c.pc = iss.pc;
  assign exu_rou_c.npc    = btaken_c
      ? addr_exu_c
      : iss.pc + (iss.c ? 2 : 4);
  assign exu_rou_c.btaken = btaken_c;
  assign exu_rou_c.mispredict = (exu_rou_c.npc != iss.pnpc);
  assign exu_rou_c.difftest_skip = 1'b0;
  // BRU never writes rd nor produces CSR / trap / MEM sideband (unified
  // exu_wb_if tie-offs; keeps the no-PRF-write-port / no-bypass-entry
  // property: consumers never see a valid prd from this port).
  assign exu_rou_c.result = '0;
  assign exu_rou_c.prd = '0;
  assign exu_rou_c.rd = '0;
  assign exu_rou_c.csr_wen = 1'b0;
  assign exu_rou_c.csr_wdata = '0;
  assign exu_rou_c.trap = 1'b0;
  assign exu_rou_c.tval = '0;
  assign exu_rou_c.cause = '0;
  assign exu_rou_c.wen = 1'b0;
  assign exu_rou_c.alu = '0;
  assign exu_rou_c.sq_waddr = '0;
  assign exu_rou_c.sq_wdata = '0;

endmodule
