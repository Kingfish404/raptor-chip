`include "rapt.svh"
`include "rapt_if.svh"

// Fetch Queue Unit (FQU): a registered, elastic boundary between IFU and
// IDU. Every packet accepted from IFU is stored before it can be presented to IDU
module rapt_fqu #(
    parameter int unsigned DEPTH = 2,
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_idu_if.slave ifu_in,
    ifu_idu_if.master idu_out,

    input logic reset
);
  localparam int unsigned PTRW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned CNTW = $clog2(DEPTH + 1);

  logic [PTRW-1:0] head;
  logic [PTRW-1:0] tail;
  logic [CNTW-1:0] count;

  logic [31:0] inst_a_mem[DEPTH];
  logic [XLEN-1:0] pc_a_mem[DEPTH];
  logic [XLEN-1:0] pnpc_mem[DEPTH];
  logic trap_mem[DEPTH];
  logic [XLEN-1:0] cause_mem[DEPTH];
  logic [XLEN-1:0] tval_mem[DEPTH];
`ifdef RAPT_DUAL_ISSUE
  logic [31:0] inst_b_mem[DEPTH];
  logic [XLEN-1:0] pc_b_mem[DEPTH];
  logic valid_b_mem[DEPTH];
`endif

  logic flush;
  logic empty;
  logic full;
  logic push;
  logic pop;

  // Simulation PMU: queue occupancy distinguishes actual frontend buffering
  // pressure from downstream stalls that a deeper queue cannot absorb.
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_full /*verilator public_flat_rd*/;
  logic [CNTW-1:0] pmu_count /*verilator public_flat_rd*/;
  /* verilator lint_on UNUSEDSIGNAL */

  // A decode-side redirect invalidates both the resident packet and a packet
  // accepted from IFU in the same cycle. Commit redirects use the same path.
  assign flush = cmu_bcast.flush_pipe || cmu_bcast.sys_resume || idu_out.resteer;
  assign empty = count == '0;
  assign full = count == CNTW'(DEPTH);
  assign pmu_full = full;
  assign pmu_count = count;

  // FQU has no flow-through path: a packet becomes visible to IDU only after
  // the enqueue clock edge. Payload always comes from registered storage.
  assign idu_out.valid_a = !flush && !empty;
  assign idu_out.inst_a = inst_a_mem[head];
  assign idu_out.pc_a = pc_a_mem[head];
  assign idu_out.pnpc = pnpc_mem[head];
  assign idu_out.trap = trap_mem[head];
  assign idu_out.cause = cause_mem[head];
  assign idu_out.tval = tval_mem[head];
`ifdef RAPT_DUAL_ISSUE
  assign idu_out.inst_b = inst_b_mem[head];
  assign idu_out.pc_b = pc_b_mem[head];
  assign idu_out.valid_b = !flush && !empty && valid_b_mem[head];
`endif

  assign pop = !flush && !empty && idu_out.ready;
  assign ifu_in.ready = !flush && (!full || pop);
  assign push = ifu_in.valid_a && ifu_in.ready;

  // The redirect channel remains combinational so IFU can squash the same
  // cycle in which IDU detects a stale prediction.
  assign ifu_in.resteer = idu_out.resteer;
  assign ifu_in.resteer_pc = idu_out.resteer_pc;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      head <= '0;
      tail <= '0;
      count <= '0;
    end else begin
      unique case ({push, pop})
        2'b10: begin
          inst_a_mem[tail] <= ifu_in.inst_a;
          pc_a_mem[tail] <= ifu_in.pc_a;
          pnpc_mem[tail] <= ifu_in.pnpc;
          trap_mem[tail] <= ifu_in.trap;
          cause_mem[tail] <= ifu_in.cause;
          tval_mem[tail] <= ifu_in.tval;
`ifdef RAPT_DUAL_ISSUE
          inst_b_mem[tail] <= ifu_in.inst_b;
          pc_b_mem[tail] <= ifu_in.pc_b;
          valid_b_mem[tail] <= ifu_in.valid_b;
`endif
          tail <= tail + 1'b1;
          count <= count + 1'b1;
        end
        2'b01: begin
          head <= head + 1'b1;
          count <= count - 1'b1;
        end
        2'b11: begin
          inst_a_mem[tail] <= ifu_in.inst_a;
          pc_a_mem[tail] <= ifu_in.pc_a;
          pnpc_mem[tail] <= ifu_in.pnpc;
          trap_mem[tail] <= ifu_in.trap;
          cause_mem[tail] <= ifu_in.cause;
          tval_mem[tail] <= ifu_in.tval;
`ifdef RAPT_DUAL_ISSUE
          inst_b_mem[tail] <= ifu_in.inst_b;
          pc_b_mem[tail] <= ifu_in.pc_b;
          valid_b_mem[tail] <= ifu_in.valid_b;
`endif
          tail <= tail + 1'b1;
          head <= head + 1'b1;
        end
        default: begin
        end
      endcase
    end
  end

  // HANDSHAKE: an empty FQU cannot expose an unregistered IFU packet.
  `RAPT_SVA_IMPLY(clock, reset, FQU_EMPTY_BLOCKS_OUTPUT,
                  empty, !idu_out.valid_a)
`ifdef RAPT_DUAL_ISSUE
  `RAPT_SVA_IMPLY(clock, reset, FQU_SLOT_B_IMPLIES_SLOT_A,
                  idu_out.valid_b, idu_out.valid_a)
`endif
  `RAPT_SVA_IMPLY(clock, reset, FQU_FLUSH_BLOCKS_OUTPUT,
                  flush, !idu_out.valid_a && !ifu_in.ready)
  `RAPT_SVA_NEXT(clock, reset, FQU_FLUSH_CLEARS_STORAGE,
                 flush, empty)
  `RAPT_COVER(clock, reset, FQU_STEADY_PACKET_FLOW,
              !empty && idu_out.ready && ifu_in.valid_a)

endmodule
