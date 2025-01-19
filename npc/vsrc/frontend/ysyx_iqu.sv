`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_iqu (
    input clock,
    input reset,

    idu_pipe_if.in  idu_if,
    idu_pipe_if.out iqu_if,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  parameter unsigned QUEUE_SIZE = `YSYX_IQU_SIZE;
  parameter bit [1:0] EMPTY = 2'b00, READY = 2'b01, FULL = 2'b10;
  micro_op_t uop_queue[QUEUE_SIZE];
  logic [$clog2(QUEUE_SIZE)-1:0] uop_head, uop_tail;
  logic [$clog2(QUEUE_SIZE):0] size;
  logic queue_full;
  logic [1:0] state;

  // === micro op queue ===
  logic [31:0] pc[QUEUE_SIZE];
  logic [31:0] inst[QUEUE_SIZE];

  logic [31:0] imm[QUEUE_SIZE];
  logic [4:0] alu_op[QUEUE_SIZE];
  logic [31:0] op1[QUEUE_SIZE];
  logic [31:0] op2[QUEUE_SIZE];

  logic [`YSYX_REG_LEN-1:0] rd[QUEUE_SIZE];

  logic ren[QUEUE_SIZE];
  logic wen[QUEUE_SIZE];
  logic jen[QUEUE_SIZE];
  logic ben[QUEUE_SIZE];

  logic system[QUEUE_SIZE];
  logic ecall[QUEUE_SIZE];
  logic ebreak[QUEUE_SIZE];
  logic mret[QUEUE_SIZE];
  logic [2:0] csr_csw[QUEUE_SIZE];
  // === micro op queue ===

  assign out_valid  = (size > 0);
  assign queue_full = (size == QUEUE_SIZE);
  assign out_ready  = (!queue_full);

  always @(posedge clock) begin
    if (reset) begin
      uop_head <= 0;
      uop_tail <= 0;
      size     <= 0;
      state    <= EMPTY;
    end else begin
      casez (state)
        EMPTY: begin
          if (prev_valid) begin
            size <= 1;
            state <= READY;
            uop_tail <= uop_tail + 1;
          end
        end
        READY: begin
          if (prev_valid) begin
            if (next_ready) begin
              uop_head <= uop_head + 1;
              uop_tail <= uop_tail + 1;
            end else begin
              size <= size + 1;
              uop_tail <= uop_tail + 1;
              if (size == (QUEUE_SIZE - 1)) begin
                state <= FULL;
              end
            end
          end else begin
            if (next_ready) begin
              size <= size - 1;
              uop_head <= uop_head + 1;
              if (size == 1) begin
                state <= EMPTY;
              end
            end else begin
            end
          end
        end
        FULL: begin
          if (next_ready) begin
            size <= size - 1;
            uop_head <= uop_head + 1;
            state <= READY;
          end
        end
        default: begin
          state <= EMPTY;
        end
      endcase
      if (state != FULL) begin
        pc[uop_tail]      <= idu_if.pc;
        inst[uop_tail]    <= idu_if.inst;

        imm[uop_tail]     <= idu_if.imm;
        alu_op[uop_tail]  <= idu_if.alu_op;
        op1[uop_tail]     <= idu_if.op1;
        op2[uop_tail]     <= idu_if.op2;

        rd[uop_tail]      <= idu_if.rd;
        ren[uop_tail]     <= idu_if.ren;
        wen[uop_tail]     <= idu_if.wen;
        jen[uop_tail]     <= idu_if.jen;
        ben[uop_tail]     <= idu_if.ben;

        system[uop_tail]  <= idu_if.system;
        ecall[uop_tail]   <= idu_if.ecall;
        ebreak[uop_tail]  <= idu_if.ebreak;
        mret[uop_tail]    <= idu_if.mret;
        csr_csw[uop_tail] <= idu_if.csr_csw;
      end
    end
  end

  always_comb begin
    iqu_if.pc      = pc[uop_head];
    iqu_if.inst    = inst[uop_head];

    iqu_if.imm     = imm[uop_head];
    iqu_if.alu_op  = alu_op[uop_head];
    iqu_if.op1     = op1[uop_head];
    iqu_if.op2     = op2[uop_head];

    iqu_if.rd      = rd[uop_head];
    iqu_if.ren     = ren[uop_head];
    iqu_if.wen     = wen[uop_head];
    iqu_if.jen     = jen[uop_head];
    iqu_if.ben     = ben[uop_head];

    iqu_if.system  = system[uop_head];
    iqu_if.ecall   = ecall[uop_head];
    iqu_if.ebreak  = ebreak[uop_head];
    iqu_if.mret    = mret[uop_head];
    iqu_if.csr_csw = csr_csw[uop_head];
  end
endmodule
