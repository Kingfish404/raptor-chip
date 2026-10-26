`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the upper half of the fixed BRQ even when ALQ/IOQ have four
// entries. Both halves of the adapter must preserve the complete index.
module tb_dispatch_iq_index;
  import rapt_pkg::*;
  dpu_iq_if #(.RS_SIZE(BranchQueueEntries)) queue ();
  dispatch_capacity_t capacity;
  dispatch_grant_t grant;
  rapt_dispatch_iq_adapter dut (
      .queue(queue),
      .capacity(capacity),
      .grant(grant)
  );

  initial begin
    grant = '0;
    for (int s = 0; s < DispatchWidth; s++) begin
      queue.free_found[s] = 0;
      queue.free_idx[s] = '0;
    end
    for (int index = 0; index < BranchQueueEntries; index++) begin
      queue.free_found[0] = 1;
      queue.free_idx[0] = $bits(queue.free_idx[0])'(index);
      #1;
      if (!capacity.ready[0] || int'(capacity.free_index[0]) != index)
        $fatal(1, "capacity truncated BRQ index %0d to %0d", index, capacity.free_index[0]);
      grant.accept[0] = 1;
      grant.index[0] = capacity.free_index[0];
      #1;
      if (!queue.accept[0] || int'(queue.rs_idx[0]) != index)
        $fatal(1, "grant truncated BRQ index %0d to %0d", index, queue.rs_idx[0]);
    end
    $display("PASS: BRQ dispatch index round trip entries=%0d bits=%0d XLEN=%0d",
             BranchQueueEntries, QueueIndexBits, `RAPT_XLEN);
    $finish;
  end
endmodule
