`include "rapt.svh"
module tb_ioq_operand_reads #(
    parameter int ReadPorts = 1
);
  localparam int Entries = 8;
  localparam int Slots = 2;
  localparam int Xlen = `RAPT_XLEN;
  localparam int PhysBits = 6;
  localparam int IndexBits = 3;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset, flush, retire;
  logic [Entries-1:0] entry_valid;
  logic [IndexBits-1:0] head;
  logic alloc_valid[Slots], alloc_addr_valid[Slots];
  logic [IndexBits-1:0] alloc_index[Slots];
  logic [1:0][PhysBits-1:0] alloc_sources[Slots];
  logic [Xlen-1:0] alloc_addr[Slots];
  logic [PhysBits-1:0] base_source[Entries], data_source[Entries];
  logic [11:0] immediate[Entries];
  logic [Entries-1:0] base_ready, data_ready, base_wake, data_wake;
  logic [Entries-1:0] needs_data;
  logic relay_valid;
  logic [IndexBits-1:0] relay_index;
  logic [Xlen-1:0] relay_addr;
  logic [PhysBits-1:0] read_address[ReadPorts];
  logic [Xlen-1:0] read_value[ReadPorts];
  logic read_valid[ReadPorts];
  logic [ReadPorts-1:0] grant;
  logic [Xlen-1:0] addr_storage[Entries], addr[Entries];
  logic [Entries-1:0] addr_ready, prepared, addr_cacheable;
  logic head_data_ready;
  logic [Xlen-1:0] head_data;

  rapt_ioq_operands #(
      .Entries(Entries),
      .Slots(Slots),
      .ReadPorts(ReadPorts),
      .Xlen(Xlen),
      .PhysBits(PhysBits),
      .IndexBits(IndexBits)
  ) dut (
      .*
  );

  function automatic logic [Xlen-1:0] value(input logic [PhysBits-1:0] tag);
    return tag == 0 ? Xlen'(0) : Xlen'('h10203040) + Xlen'(tag) * Xlen'('h01010101);
  endfunction
  for (genvar p = 0; p < ReadPorts; p++) begin : g_read
    assign read_value[p] = value(read_address[p]);
    assign read_valid[p] = grant[p];
  end
  task automatic tick;
    @(posedge clock);
    #1;
    if (reset || flush) entry_valid = '0;
    else begin
      if (retire) entry_valid[head] = 0;
      for (int s = 0; s < Slots; s++) if (alloc_valid[s]) entry_valid[alloc_index[s]] = 1;
    end
    #1;
  endtask
  task automatic check(input logic condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask
  task automatic clear_alloc;
    for (int s = 0; s < Slots; s++) begin
      alloc_valid[s] = 0;
      alloc_index[s] = '0;
      alloc_sources[s] = '0;
      alloc_addr_valid[s] = 0;
      alloc_addr[s] = '0;
    end
  endtask
  task automatic allocate(input int slot, input int index, input int data_tag,
                          input logic data_available);
    alloc_valid[slot] = 1;
    alloc_index[slot] = IndexBits'(index);
    alloc_sources[slot][1] = PhysBits'(data_tag);
    alloc_addr_valid[slot] = 1;
    alloc_addr[slot] = Xlen'('h80000000 + 8 * index);
    needs_data[index] = 1;
    base_ready[index] = 1;
    data_ready[index] = data_available;
  endtask

  initial begin
    reset = 1;
    flush = 0;
    retire = 0;
    head = 0;
    entry_valid = '0;
    base_ready = '0;
    data_ready = '0;
    base_wake = '0;
    data_wake = '0;
    needs_data = '0;
    relay_valid = 0;
    relay_index = 0;
    relay_addr = 0;
    grant = '1;
    clear_alloc();
    for (int e = 0; e < Entries; e++) immediate[e] = '0;
    tick();
    reset = 0;
    // Fill both cache slots with younger data while the head is pending.
    allocate(0, 0, 20, 0);
    allocate(1, 1, 21, 1);
    tick();
    clear_alloc();
    allocate(0, 2, 22, 1);
    tick();
    clear_alloc();
    tick();
    check(dut.cache_valid == 2'b11, "PRF reads did not prefetch both younger values");
    check(!head_data_ready, "pending head consumed a younger store value");
    data_ready[0] = 1;
    grant = '0;
    #1;
    check(read_address[0] == 20, "oldest store did not obtain the PRF request");
    tick();
    check(!head_data_ready, "denied read grant captured store data");
    grant = '1;
    tick();
    check(head_data_ready && head_data == value(20), "younger cache owners blocked the head");
    retire = 1;
    tick();
    retire = 0;
    entry_valid[0] = 0;
    head = 1;
    repeat (3) tick();
    check(head_data_ready && head_data == value(21), "retirement corrupted the next store");

    // Cache age comparisons must use circular age after the queue wraps.
    flush = 1;
    tick();
    flush = 0;
    entry_valid = '0;
    base_ready = '0;
    data_ready = '0;
    needs_data = '0;
    head = 7;
    allocate(0, 7, 30, 0);
    allocate(1, 0, 31, 1);
    tick();
    clear_alloc();
    allocate(0, 1, 32, 1);
    tick();
    clear_alloc();
    tick();
    data_ready[7] = 1;
    repeat (3) tick();
    check(head_data_ready && head_data == value(30), "wrapped head could not replace younger data");

    // A relay owns the sum even when its ordinary read is deliberately skipped.
    flush = 1;
    tick();
    flush = 0;
    entry_valid = '0;
    needs_data = '0;
    head = 0;
    alloc_valid[0] = 1;
    alloc_index[0] = 0;
    alloc_sources[0][0] = 9;
    alloc_addr_valid[0] = 0;
    tick();
    clear_alloc();
    entry_valid[0] = 1;
    base_ready[0] = 1;
    immediate[0] = 12'(-12);
    relay_valid = 1;
    relay_addr = value(9) - Xlen'(12);
    // A same-bank allocation must not overwrite the relay's owned sum.
    alloc_valid[0] = 1;
    alloc_index[0] = 2;
    alloc_sources[0][0] = 20;
    alloc_addr_valid[0] = 1;
    alloc_addr[0] = value(20);
    base_ready[2] = 1;
    tick();
    relay_valid = 0;
    clear_alloc();
    check(prepared[0] && addr[0] == value(9) - Xlen'(12), "relay sum lost its entry owner");
    check(!prepared[2], "same-bank allocation overwrote the relay preparation");
    repeat (3) tick();
    check(prepared[2] && addr[2] == value(20), "displaced allocation lost its physical source");
    check(head_data_ready && head_data == 0, "physical zero data required a PRF read");
    flush = 1;
    tick();
    check(prepared == '0 && dut.cache_valid == '0, "flush retained operand ownership");
    $display("PASS: operand reads, denied grants, eviction, wrap, relay RV%0d ports=%0d", Xlen,
             ReadPorts);
    $finish;
  end
endmodule
