`include "rapt.svh"

interface rapt_csr_uvm_if(input logic clock);
  logic reset;
  logic [31:0] pc;
  logic csr_wen;
  logic [31:0] csr_wdata;
  logic [11:0] csr_addr;
  logic ecall;
  logic ebreak;
  logic mret;
  logic sret;
  logic trap;
  logic [31:0] tval;
  logic [31:0] cause;
  logic valid;
  logic retire_a;
  logic retire_b;
  logic timer_irq;
  logic sw_irq;
  logic m_ext_irq;
  logic s_ext_irq;

  logic [31:0] sepc;
  logic [31:0] mtvec;
  logic [31:0] stvec;
  logic [1:0] priv;
  logic s_int_pending;
  logic [31:0] s_int_cause;

  initial begin
    reset = 1'b1;
    pc = '0;
    csr_wen = 1'b0;
    csr_wdata = '0;
    csr_addr = '0;
    ecall = 1'b0;
    ebreak = 1'b0;
    mret = 1'b0;
    sret = 1'b0;
    trap = 1'b0;
    tval = '0;
    cause = '0;
    valid = 1'b0;
    retire_a = 1'b0;
    retire_b = 1'b0;
    timer_irq = 1'b0;
    sw_irq = 1'b0;
    m_ext_irq = 1'b0;
    s_ext_irq = 1'b0;
  end
endinterface