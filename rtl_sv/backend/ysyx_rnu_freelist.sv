`include "ysyx.svh"
`include "ysyx_rnu_internal_if.svh"

// Free List - manages allocation and deallocation of physical registers.
// Implemented as a circular FIFO. Tracks in-flight count for flush recovery.
// Dual-issue: supports 2 simultaneous allocations per cycle.
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
  logic [PLEN-1:0] fifo[PNUM];
  logic [PLEN-1:0] head, tail;
  logic [PLEN-1:0] inflight_pr_num;

  // Allocation port A
  assign fl.alloc_pr_a    = fifo[head[PLEN-1:0]];
  assign fl.alloc_empty_a = (head == tail);

  logic do_alloc_a;
  assign do_alloc_a = fl.alloc_req_a && !fl.alloc_empty_a;

`ifdef YSYX_DUAL_ISSUE
  // Allocation port B: reads from head+1 when A also allocates, head when only B allocates
  assign fl.alloc_pr_b    = do_alloc_a ? fifo[head[PLEN-1:0] + 1] : fifo[head[PLEN-1:0]];
  // Empty for slot B: need 2 free entries when both allocate, 1 when only B allocates
  assign fl.alloc_empty_b = do_alloc_a ? ((head == tail) || (head + 1 == tail)) : (head == tail);

  logic do_alloc_b;
  assign do_alloc_b = fl.alloc_req_b && !fl.alloc_empty_b;
`endif

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        fifo[i] <= PLEN'(i);
      end
      head            <= RNUM[PLEN-1:0];
      tail            <= PNUM[PLEN-1:0];
      inflight_pr_num <= '0;
    end else begin
      // --- Head pointer & in-flight tracking ---
      if (fl.flush_pipe) begin
        // Rewind head by in-flight count, accounting for commits during flush
        head            <= head - inflight_pr_num
                         + (fl.flush_rd_a != 0 ? 1 : 0)
                         + (fl.flush_rd_b != 0 ? 1 : 0);
        inflight_pr_num <= '0;
      end else begin
`ifdef YSYX_DUAL_ISSUE
        if (do_alloc_a && do_alloc_b) begin
          head <= head + 2;
        end else if (do_alloc_a || do_alloc_b) begin
          head <= head + 1;
        end
        // Update in-flight count: +allocs -deallocs
        inflight_pr_num <= inflight_pr_num
            + (do_alloc_a ? 1 : 0)
            + (do_alloc_b ? 1 : 0)
            - (fl.dealloc_req_a ? 1 : 0)
            - (fl.dealloc_req_b ? 1 : 0);
`else
        if (do_alloc_a) begin
          head <= head + 1;
        end
        // Update in-flight count: +1 for alloc, -1 per dealloc
        inflight_pr_num <= inflight_pr_num
            + (do_alloc_a ? 1 : 0)
            - (fl.dealloc_req_a ? 1 : 0)
            - (fl.dealloc_req_b ? 1 : 0);
`endif
      end

      // --- Tail pointer (dealloc always proceeds, even during flush) ---
      if (fl.dealloc_req_a && fl.dealloc_req_b) begin
        fifo[tail[PLEN-1:0]]   <= fl.dealloc_pr_a;
        fifo[tail[PLEN-1:0]+1] <= fl.dealloc_pr_b;
        tail                   <= tail + 2;
      end else if (fl.dealloc_req_a) begin
        fifo[tail[PLEN-1:0]] <= fl.dealloc_pr_a;
        tail                 <= tail + 1;
      end else if (fl.dealloc_req_b) begin
        fifo[tail[PLEN-1:0]] <= fl.dealloc_pr_b;
        tail                 <= tail + 1;
      end
    end
  end
endmodule
