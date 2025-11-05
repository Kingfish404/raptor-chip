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

endpackage
