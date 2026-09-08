`include "rapt.svh"
module tb_ifetch_io_guard;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic [XLEN-1:0] owner_pc = 'h40000000, frontier_pc = 'h40000000;
  logic
      frontier_advance = 0,
      blocked = 0,
      pipeline_empty = 1,
      memory_idle = 1,
      io_start = 0,
      authorized;
  rapt_ifetch_io_guard dut (.*);
  `include "tb_common.svh"
  initial begin
    tick(3);
    reset = 0;
    #1;
    check(authorized, "empty architectural frontier did not authorize fetch");
    for (int gate = 0; gate < 4; gate++) begin
      owner_pc=frontier_pc+(gate==0 ? XLEN'(4) : XLEN'(0));
      pipeline_empty=gate!=1;
      memory_idle=gate!=2;
      blocked=gate==3;
      #1;
      check(!authorized,
            "wrong path, queued same-PC instruction, memory or redirect gate bypassed");
      tick(3);
    end
    owner_pc=frontier_pc;
    pipeline_empty=1;
    memory_idle=1;
    blocked=0;
    #1;
    check(authorized, "drained frontier remained blocked");
    io_start = 1;
    tick(1);
    io_start = 0;
    repeat (4) begin
      check(!authorized, "same dynamic instruction authorized twice");
      tick(1);
    end
    // A cancel/redirect alone is not a new architectural instruction.
    blocked = 1;
    tick(1);
    blocked = 0;
    #1;
    check(!authorized, "frontend cancellation replenished permission");
    // A self-loop has the same next PC, but an actual retirement is a new epoch.
    frontier_advance = 1;
    #1;
    check(!authorized, "grant raced frontier update");
    tick(1);
    frontier_advance = 0;
    #1;
    check(authorized, "same-PC retirement failed to replenish permission");
    // Even in a new epoch, buffered older instructions must drain first.
    pipeline_empty = 0;
    #1;
    check(!authorized, "older buffered instruction was ignored");
    tick(2);
    pipeline_empty=1;
    io_start=1;
    tick(1);
    io_start=0;
    // Trap entry advances the frontier even with no ordinary commit.
    frontier_advance=1;
    blocked=1;
    tick(1);
    frontier_pc='h80000100;
    frontier_advance=0;
    blocked=0;
    #1;
    check(!authorized, "old IO owner authorized at trap handler frontier");
    owner_pc = frontier_pc;
    #1;
    check(authorized, "trap handler frontier could not fetch");
    $display(
        "PASS: IO fetch architectural frontier, same-PC epochs, pipeline/memory drain and cancellation");
    $finish;
  end
endmodule
