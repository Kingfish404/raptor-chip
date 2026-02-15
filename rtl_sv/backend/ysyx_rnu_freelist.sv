`include "ysyx.svh"
`include "ysyx_rnu_internal_if.svh"

// Free List - manages allocation and deallocation of physical registers.
// Implemented as a circular FIFO. Tracks in-flight count for flush recovery.
module ysyx_rnu_freelist #(
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned PNUM = `YSYX_PHY_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    /* verilator lint_off UNUSEDPARAM */
    parameter unsigned RLEN = `YSYX_REG_LEN
    /* verilator lint_on UNUSEDPARAM */
) (
    input clock,
    input reset,

    rnu_fl_if.slave fl
);
  logic [PLEN-1:0] fifo [PNUM];
  logic [PLEN-1:0] head, tail;
  logic [PLEN-1:0] inflight_pr_num;

  assign fl.alloc_pr    = fifo[head[PLEN-1:0]];
  assign fl.alloc_empty = (head == tail);

  logic do_alloc;
  assign do_alloc = fl.alloc_req && !fl.alloc_empty;

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        fifo[i] <= i[PLEN-1:0];
      end
      head             <= RNUM[PLEN-1:0];
      tail             <= PNUM[PLEN-1:0];
      inflight_pr_num  <= '0;
    end else begin
      // --- Head pointer & in-flight tracking ---
      if (fl.flush_pipe) begin
        // Rewind head by in-flight count, accounting for one possible dealloc
        head            <= head - inflight_pr_num + (fl.flush_rd != 0 ? 1 : 0);
        inflight_pr_num <= '0;
      end else begin
        if (do_alloc) begin
          head <= head + 1;
        end
        // Update in-flight count
        if (do_alloc && !fl.dealloc_req) begin
          inflight_pr_num <= inflight_pr_num + 1;
        end else if (!do_alloc && fl.dealloc_req) begin
          inflight_pr_num <= inflight_pr_num - 1;
        end
        // else: both or neither → no change
      end

      // --- Tail pointer (dealloc always proceeds, even during flush) ---
      if (fl.dealloc_req) begin
        fifo[tail[PLEN-1:0]] <= fl.dealloc_pr;
        tail                 <= tail + 1;
      end
    end
  end
endmodule
