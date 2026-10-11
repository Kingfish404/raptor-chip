`include "rapt.svh"
module tb_cached_ptw;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1, flush = 0;
  logic [1:0] request = 0, kill = 0, store_req = 0, arvalid, done, fault, busy;
  logic [1:0] pending = 0, rvalid = 0;
  logic hold_response = 0;
  logic [XLEN-1:0] va[2], araddr[2], rdata[2];
  logic [8:0] asid [2];
  logic [`RAPT_CSR_SATP_PPN_W-1:0] root [2];
  logic [1:0] pbmte = 0;
  logic [XLEN-1:10] ptag [2];
  logic [XLEN-1:12] vtag [2];
  logic [6:0] flags [2];
  logic [1:0] pbmt [2];
  int reads [2];
  logic [XLEN-1:0] leaf = XLEN'((64'h40000 << 10) | 64'hcf);
  rapt_pkg::l2tlb_req_t l2req [2];
  rapt_pkg::l2tlb_rsp_t l2rsp [2];
  logic [1:0] ready;
  rapt_l2tlb cache (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .req_i(l2req),
      .ready_o(ready),
      .rsp_o(l2rsp)
  );
  for (genvar p = 0; p < 2; p++) begin : g_ports
    rapt_cached_ptw #(
        .Enable(1)
    ) dut (
        .clock(clock),
        .reset(reset),
        .req_valid(request[p]),
        .kill(kill[p] || flush),
        .vaddr(va[p]),
        .satp_ppn(root[p]),
        .asid(asid[p]),
        .mmu_en(1'b1),
        .pbmte(pbmte[p]),
        .sbe(1'b0),
        .req_store(store_req[p]),
        .l2_req_o(l2req[p]),
        .l2_ready_i(ready[p]),
        .l2_rsp_i(l2rsp[p]),
        .bus_arvalid(arvalid[p]),
        .bus_araddr(araddr[p]),
        .bus_arready(1'b1),
        .bus_rvalid(rvalid[p]),
        .bus_rdata(rdata[p]),
        .bus_awvalid(),
        .bus_awaddr(),
        .bus_wvalid(),
        .bus_wdata(),
        .bus_wstrb(),
        .bus_wready(1'b0),
        .bus_werr(1'b0),
        .done(done[p]),
        .fault(fault[p]),
        .result_ptag(ptag[p]),
        .result_vtag(vtag[p]),
        .result_pte(flags[p]),
        .result_pbmt(pbmt[p]),
        .busy(busy[p])
    );
    always @(posedge clock) begin
      if (reset) begin
        reads[p] <= 0;
        pending[p] <= 0;
        rvalid[p] <= 0;
        rdata[p] <= 0;
      end else begin
        rvalid[p] <= 0;
        if (arvalid[p]) begin
          if (pending[p]) $fatal(1, "multiple outstanding walker reads");
          reads[p] <= reads[p] + 1;
          pending[p] <= 1;
          rdata[p] <= leaf;
        end
        if (pending[p] && !hold_response) begin
          pending[p] <= 0;
          rvalid[p] <= 1;
        end
      end
    end
  end
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic check(input logic ok, input string msg);
    if (!ok) $fatal(1, "%s", msg);
  endtask
  task automatic start(input int p, input logic [XLEN-1:0] addr, input logic store_access);
    @(negedge clock);
    va[p] = addr;
    store_req[p] = store_access;
    request[p] = 1;
    tick();
    @(negedge clock);
    request[p] = 0;
  endtask
  task automatic finish(input int p, input logic expect_fault);
    int cycles;
    cycles = 0;
    while (!done[p] && !fault[p] && cycles < 100) begin
      tick();
      cycles++;
    end
    check(cycles < 100, "translation timeout");
    check(fault[p] == expect_fault && done[p] != expect_fault, "wrong translation outcome");
    if (!expect_fault) begin
      check(vtag[p] == va[p][XLEN-1:12], "wrong accepted virtual page");
`ifdef RAPT_RV64
      check(ptag[p] == (XLEN - 10)'('h40000 | va[p][29:12]), "wrong superpage PPN");
`else
      check(ptag[p] == (XLEN - 10)'('h40000 | va[p][21:12]), "wrong superpage PPN");
`endif
    end
    tick();
  endtask
  task automatic translate(input int p, input logic [XLEN-1:0] addr, input logic store_access,
                           input logic expect_fault, input int expected_reads);
    int before_reads;
    before_reads = reads[p];
    start(p, addr, store_access);
    finish(p, expect_fault);
    check(reads[p] - before_reads == expected_reads, "wrong number of page-table reads");
  endtask
  initial begin
    va[0] = 0;
    va[1] = 0;
    asid[0] = 3;
    asid[1] = 3;
    root[0] = 1;
    root[1] = 1;
    tick();
    tick();
    reset = 0;
    translate(0, 'h12345000, 0, 0, 1);
    translate(1, 'h12345000, 1, 0, 0);  // I-side walk warms data-side translation.
    translate(1, 'h12445000, 0, 0, 1);  // Same low VPN index evicts first page.
    translate(0, 'h12345000, 0, 0, 1);
    asid[1] = 4;
    translate(1, 'h12345000, 0, 0, 1);
    root[1] = 2;
    translate(1, 'h12345000, 0, 0, 1);
    // A read may cache D=0, but a later store must fault without a walk.
    leaf = XLEN'((64'h40000 << 10) | 64'h4f);
    translate(0, 'h12346000, 0, 0, 1);
    translate(0, 'h12346000, 1, 1, 0);
    // Invalid and A=0 leaves must never populate the shared table.
    leaf = 0;
    translate(0, 'h12347000, 0, 1, 1);
    translate(0, 'h12347000, 0, 1, 1);
    leaf = XLEN'((64'h40000 << 10) | 64'h0f);
    translate(0, 'h12347000, 0, 1, 1);
    leaf = XLEN'((64'h40000 << 10) | 64'hef);  // Global leaf.
    translate(0, 'h12348000, 0, 0, 1);
    root[1] = 1;
    translate(1, 'h12348000, 0, 0, 0);
`ifdef RAPT_RV64
    translate(0, 64'h0000010012348000, 0, 1, 0);
    leaf = XLEN'((64'h40000 << 10) | 64'hcf | (64'h2 << 61));
    pbmte[0] = 1;
    translate(0, 'h12349000, 0, 0, 1);
    check(pbmt[0] == 2, "PBMT lost after walk");
    translate(0, 'h12349000, 0, 0, 0);
    check(pbmt[0] == 2, "PBMT lost on L2 hit");
    pbmte[0] = 0;
    translate(0, 'h12349000, 0, 1, 1);
`endif
    leaf = XLEN'((64'h40000 << 10) | 64'hcf);
    // Kill an accepted bus read, then release its response. It must drain,
    // produce no completion, and never install a stale translation.
    hold_response = 1;
    start(0, 'h1234a000, 0);
    while (!pending[0]) tick();
    @(negedge clock);
    flush = 1;
    tick();
    check(busy[0], "accepted PTE read was abandoned");
    @(negedge clock);
    flush = 0;
    hold_response = 0;
    repeat (8) begin
      tick();
      check(!done[0] && !fault[0], "cancelled walk completed");
    end
    check(!busy[0], "cancelled walk did not drain");
    translate(0, 'h1234a000, 0, 0, 1);
    // Cancel a lookup; its registered response must not complete a new owner.
    start(0, 'h1234a000, 0);
    kill[0] = 1;
    tick();
    @(negedge clock);
    kill[0] = 0;
    translate(0, 'h1234b000, 0, 0, 1);
    // A flush between PTW completion and fill acceptance must discard both
    // the pending L2 fill and the completion destined for the L1 TLB.
    start(0, 'h1234e000, 0);
    while (!l2req[0].fill) tick();
    @(negedge clock);
    flush = 1;
    tick();
    check(!done[0], "flushed pending fill completed");
    @(negedge clock);
    flush = 0;
    translate(0, 'h1234e000, 0, 0, 1);
    // Live CSR inputs may change after acceptance; fill ownership must stay
    // with the captured ASID/root, even when the return is delayed.
    hold_response = 1;
    start(0, 'h1234f000, 0);
    while (!pending[0]) tick();
    @(negedge clock);
    asid[0] = 7;
    root[0] = 9;
    hold_response = 0;
    finish(0, 0);
    asid[0] = 3;
    root[0] = 1;
    translate(0, 'h1234f000, 0, 0, 0);
    // Simultaneous misses exercise independent walkers and shared fill arbitration.
    @(negedge clock);
    va[0] = 'h1234c000;
    va[1] = 'h1234d000;
    request = 3;
    tick();
    @(negedge clock);
    request = 0;
    fork
      finish(0, 0);
      finish(1, 0);
    join
    translate(0, 'h1234d000, 0, 0, 1);  // Other ASID must miss.
    @(negedge clock);
    flush = 1;
    tick();
    @(negedge clock);
    flush = 0;
    translate(0, 'h1234d000, 0, 0, 1);
    $display(
        "PASS: cached PTWs cross-fill, permissions, collisions, faults, cancellation and concurrent requests");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
