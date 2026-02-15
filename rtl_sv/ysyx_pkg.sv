package ysyx_pkg;
  `include "ysyx.svh"

  parameter int XLEN = `YSYX_XLEN;

  parameter unsigned RNUM = `YSYX_REG_SIZE;
  parameter unsigned RLEN = `YSYX_REG_LEN;

  parameter unsigned PNUM = `YSYX_PHY_SIZE;
  parameter unsigned PLEN = `YSYX_PHY_LEN;

  typedef struct packed {
    logic       c;
    logic [4:0] alu;
    logic       ben;
    logic       jen;
    logic       jren;
    logic       wen;
    logic       ren;
    logic       atom;

    logic system;
    logic ecall;
    logic ebreak;
    logic f_i;
    logic f_time;
    logic mret;
    logic sret;
    logic [2:0] csr_csw;

    logic trap;
    logic [XLEN-1:0] tval;
    logic [XLEN-1:0] cause;

    logic [RLEN-1:0] rd;
    logic [XLEN-1:0] imm;

    logic [XLEN-1:0] pnpc;
    logic [31:0] inst;
    logic [XLEN-1:0] pc;
  } uop_t;

  typedef struct packed {
    logic [XLEN-1:0] op1;
    logic [XLEN-1:0] op2;

    logic [PLEN-1:0] pr1;
    logic [PLEN-1:0] pr2;
    logic [PLEN-1:0] prd;
    logic [PLEN-1:0] prs;
  } prd_t;

  // ROB entry state
  typedef enum logic [1:0] {
    ROB_CM = 2'b00,  // Committed / empty
    ROB_WB = 2'b01,  // Written back, waiting to commit
    ROB_EX = 2'b10   // Executing
  } rob_state_t;

  // ROB entry - aggregates all per-entry fields for clarity
  typedef struct packed {
    // Physical register mapping
    logic [PLEN-1:0]  prd;
    logic [PLEN-1:0]  prs;

    // Architectural register
    logic [RLEN-1:0]  rd;
    rob_state_t       state;
    logic             busy;

    // Branch / jump
    logic             ben;
    logic             jen;
    logic             jren;
    logic             btaken;
    logic [XLEN-1:0]  npc;
    logic [XLEN-1:0]  pnpc;

    // Memory
    logic             wen;
    logic [4:0]       alu;
    logic [XLEN-1:0]  sq_waddr;
    logic [XLEN-1:0]  sq_wdata;

    // Atomics
    logic             atom;
    logic             atom_sc;

    // System
    logic             sys;
    logic             ecall;
    logic             ebreak;
    logic             mret;
    logic             sret;

    // CSR
    logic             csr_wen;
    logic [XLEN-1:0]  csr_wdata;
    logic [11:0]      csr_addr;

    // Trap
    logic             trap;
    logic [XLEN-1:0]  tval;
    logic [XLEN-1:0]  cause;

    // Fence
    logic             f_i;
    logic             f_time;

    // Instruction info
    logic [31:0]      inst;
    logic [XLEN-1:0]  pc;
  } rob_entry_t;

endpackage
