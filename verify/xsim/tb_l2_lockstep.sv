`include "rapt.svh"
`include "rapt_soc_if.svh"

// Build with a prior rapt_l2 source renamed to rapt_l2_reference. Both DUTs
// see one transaction stream and one delayed outer AXI responder.
module tb_l2_lockstep;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int WordBytes = XLEN / 8;

  logic clock = 1'b0, reset = 1'b1;
  always #5 clock = ~clock;

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) s_new ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) s_ref ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) m_new ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) m_ref ();

  logic probe_ready = 1'b1;
  logic probe_new_valid, probe_ref_valid;
  logic [XLEN-1:0] probe_new_addr, probe_ref_addr;
  logic release_new_ready, release_ref_ready;
  logic release_new_ack, release_ref_ack;
  logic probe_new_release_ready, probe_ref_release_ready;
  logic probe_new_window, probe_ref_window;

  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .probe_ready_i(probe_ready),
      .probe_valid_o(probe_new_valid),
      .probe_addr_o(probe_new_addr),
      .probe_release_ready_o(probe_new_release_ready),
      .release_ready_o(release_new_ready),
      .release_ack_o(release_new_ack),
      .probe_window_o(probe_new_window),
      .axi_s(s_new),
      .axi_m(m_new)
  );
  rapt_l2_reference #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) reference (
      .clock,
      .reset,
      .probe_ready_i(probe_ready),
      .probe_valid_o(probe_ref_valid),
      .probe_addr_o(probe_ref_addr),
      .probe_release_ready_o(probe_ref_release_ready),
      .release_ready_o(release_ref_ready),
      .release_ack_o(release_ref_ack),
      .probe_window_o(probe_ref_window),
      .axi_s(s_ref),
      .axi_m(m_ref)
  );

  assign s_ref.araddr = s_new.araddr;
  assign s_ref.arid = s_new.arid;
  assign s_ref.arlen = s_new.arlen;
  assign s_ref.arsize = s_new.arsize;
  assign s_ref.arburst = s_new.arburst;
  assign s_ref.arcache = s_new.arcache;
  assign s_ref.arvalid = s_new.arvalid;
  assign s_ref.rready = s_new.rready;
  assign s_ref.awaddr = s_new.awaddr;
  assign s_ref.awid = s_new.awid;
  assign s_ref.awlen = s_new.awlen;
  assign s_ref.awsize = s_new.awsize;
  assign s_ref.awburst = s_new.awburst;
  assign s_ref.awcache = s_new.awcache;
  assign s_ref.awvalid = s_new.awvalid;
  assign s_ref.wdata = s_new.wdata;
  assign s_ref.wstrb = s_new.wstrb;
  assign s_ref.wlast = s_new.wlast;
  assign s_ref.wvalid = s_new.wvalid;
  assign s_ref.bready = s_new.bready;

  assign m_ref.arready = m_new.arready;
  assign m_ref.rid = m_new.rid;
  assign m_ref.rdata = m_new.rdata;
  assign m_ref.rresp = m_new.rresp;
  assign m_ref.rlast = m_new.rlast;
  assign m_ref.rvalid = m_new.rvalid;
  assign m_ref.awready = m_new.awready;
  assign m_ref.wready = m_new.wready;
  assign m_ref.bid = m_new.bid;
  assign m_ref.bresp = m_new.bresp;
  assign m_ref.bvalid = m_new.bvalid;

  int cycles = 0, evictions = 0, bypasses = 0, reads = 0, writes = 0;
  always @(posedge clock) begin
    cycles++;
    if (!reset) begin
      if ({s_new.arready, s_new.rvalid, s_new.rdata, s_new.rid, s_new.rresp,
           s_new.rlast, s_new.awready, s_new.wready, s_new.bvalid, s_new.bid,
           s_new.bresp} !==
          {s_ref.arready, s_ref.rvalid, s_ref.rdata, s_ref.rid, s_ref.rresp,
           s_ref.rlast, s_ref.awready, s_ref.wready, s_ref.bvalid, s_ref.bid,
           s_ref.bresp}) begin
        $display("new AR/R: arready=%b rvalid=%b rdata=%h rid=%h rresp=%h rlast=%b", s_new.arready,
                 s_new.rvalid, s_new.rdata, s_new.rid, s_new.rresp, s_new.rlast);
        $display("new AW/W/B: awready=%b wready=%b bvalid=%b bid=%h bresp=%h", s_new.awready,
                 s_new.wready, s_new.bvalid, s_new.bid, s_new.bresp);
        $display("ref AR/R: arready=%b rvalid=%b rdata=%h rid=%h rresp=%h rlast=%b", s_ref.arready,
                 s_ref.rvalid, s_ref.rdata, s_ref.rid, s_ref.rresp, s_ref.rlast);
        $display("ref AW/W/B: awready=%b wready=%b bvalid=%b bid=%h bresp=%h", s_ref.awready,
                 s_ref.wready, s_ref.bvalid, s_ref.bid, s_ref.bresp);
        $display("state: new=%0d parent=%0d bypass=%0d started=%b ref=%0d arvalid=%b rvalid=%b",
                 dut.rs, dut.rs_parent, dut.bypass_phase, dut.u_bypass_ctrl.started_q,
                 reference.rs, m_new.arvalid, m_new.rvalid);
        $fatal(1, "upstream mismatch at cycle %0d", cycles);
      end
      if ({m_new.arvalid, m_new.araddr, m_new.arid, m_new.arlen, m_new.arsize,
           m_new.arburst, m_new.arcache, m_new.rready, m_new.awvalid, m_new.awaddr,
           m_new.awid, m_new.awlen, m_new.awsize, m_new.awburst, m_new.awcache,
           m_new.wvalid, m_new.wdata, m_new.wstrb, m_new.wlast, m_new.bready} !==
          {m_ref.arvalid, m_ref.araddr, m_ref.arid, m_ref.arlen, m_ref.arsize,
           m_ref.arburst, m_ref.arcache, m_ref.rready, m_ref.awvalid, m_ref.awaddr,
           m_ref.awid, m_ref.awlen, m_ref.awsize, m_ref.awburst, m_ref.awcache,
           m_ref.wvalid, m_ref.wdata, m_ref.wstrb, m_ref.wlast, m_ref.bready})
        $fatal(1, "downstream mismatch at cycle %0d", cycles);
      if ({probe_new_valid, probe_new_addr, probe_new_release_ready,
           release_new_ready, release_new_ack, probe_new_window} !==
          {probe_ref_valid, probe_ref_addr, probe_ref_release_ready,
           release_ref_ready, release_ref_ack, probe_ref_window})
        $fatal(1, "probe/release mismatch at cycle %0d", cycles);
      if (dut.rs !== reference.rs)
        $fatal(1, "read phase mismatch at cycle %0d: %0d vs %0d", cycles, dut.rs, reference.rs);
      if (dut.evict_valid && dut.evict_phase == 0) evictions++;
      if (dut.bypass_valid && dut.bypass_phase == 1) bypasses++;
      if (s_new.arvalid && s_new.arready) reads++;
      if (s_new.awvalid && s_new.awready) writes++;
    end
  end

  logic read_busy = 1'b0, write_busy = 1'b0, b_pending = 1'b0;
  logic [XLEN-1:0] read_addr;
  logic [IdW-1:0] read_id, write_id;
  logic [7:0] read_len, read_beat;
  int read_delay = 0, b_delay = 0;
  int seed = 1;

  always @(posedge clock) begin
    if (reset) begin
      read_busy = 1'b0;
      write_busy = 1'b0;
      b_pending = 1'b0;
    end else begin
      if (m_new.arvalid && m_new.arready) begin
        read_busy = 1'b1;
        read_addr = m_new.araddr;
        read_id = m_new.arid;
        read_len = m_new.arlen;
        read_beat = 0;
        read_delay = $urandom_range(0, 11);
      end else if (read_busy && m_new.rvalid && m_new.rready) begin
        if (read_beat == read_len) read_busy = 1'b0;
        else begin
          read_beat++;
          read_delay = $urandom_range(0, 11);
        end
      end else if (read_busy && read_delay > 0) read_delay--;

      if (m_new.awvalid && m_new.awready) begin
        write_busy = 1'b1;
        write_id = m_new.awid;
      end
      if (write_busy && m_new.wvalid && m_new.wready && m_new.wlast) begin
        write_busy = 1'b0;
        b_pending = 1'b1;
        b_delay = $urandom_range(0, 11);
      end else if (b_pending && m_new.bvalid && m_new.bready) b_pending = 1'b0;
      else if (b_pending && b_delay > 0) b_delay--;
    end
  end

  always @(negedge clock) begin
    m_new.arready = !read_busy && $urandom_range(0, 3) != 0;
    m_new.rvalid = read_busy && read_delay == 0;
    m_new.rid = read_id;
    m_new.rdata = read_addr ^ XLEN'('h5a5a0000 + read_beat * 17);
    m_new.rresp = 2'b00;
    m_new.rlast = read_beat == read_len;
    m_new.awready = !write_busy && !b_pending && $urandom_range(0, 3) != 0;
    m_new.wready = write_busy && $urandom_range(0, 3) != 0;
    m_new.bvalid = b_pending && b_delay == 0;
    m_new.bid = write_id;
    m_new.bresp = 2'b00;
    s_new.rready = $urandom_range(0, 3) != 0;
    s_new.bready = $urandom_range(0, 3) != 0;
    probe_ready = $urandom_range(0, 3) != 0;
  end

  task automatic read_one(input logic [XLEN-1:0] addr, input logic [3:0] cache);
    @(negedge clock);
    s_new.araddr = addr;
    s_new.arid = IdW'(2);
    s_new.arlen = 0;
    s_new.arsize = 3'($clog2(WordBytes));
    s_new.arburst = 2'b01;
    s_new.arcache = cache;
    s_new.arvalid = 1'b1;
    for (int wait_cycle = 0; wait_cycle < 2000; wait_cycle++) begin
      @(posedge clock);
      if (s_new.arready) break;
      if (wait_cycle == 1999) $fatal(1, "upstream AR timeout");
    end
    @(negedge clock);
    s_new.arvalid = 1'b0;
    for (int wait_cycle = 0; wait_cycle < 2000; wait_cycle++) begin
      @(posedge clock);
      if (s_new.rvalid && s_new.rready && s_new.rlast) break;
      if (wait_cycle == 1999) $fatal(1, "upstream R timeout");
    end
  endtask

  task automatic write_one(input logic [XLEN-1:0] addr);
    @(negedge clock);
    s_new.awaddr = addr;
    s_new.awid = IdW'(3);
    s_new.awlen = 0;
    s_new.awsize = 3'($clog2(WordBytes));
    s_new.awburst = 2'b01;
    s_new.awcache = 4'hf;
    s_new.awvalid = 1'b1;
    for (int wait_cycle = 0; wait_cycle < 2000; wait_cycle++) begin
      @(posedge clock);
      if (s_new.awready) break;
      if (wait_cycle == 1999) $fatal(1, "upstream AW timeout");
    end
    @(negedge clock);
    s_new.awvalid = 1'b0;
    s_new.wdata = addr ^ XLEN'('ha5a50000);
    s_new.wstrb = '1;
    s_new.wlast = 1'b1;
    s_new.wvalid = 1'b1;
    for (int wait_cycle = 0; wait_cycle < 2000; wait_cycle++) begin
      @(posedge clock);
      if (s_new.wready) break;
      if (wait_cycle == 1999) $fatal(1, "upstream W timeout");
    end
    @(negedge clock);
    s_new.wvalid = 1'b0;
    for (int wait_cycle = 0; wait_cycle < 2000; wait_cycle++) begin
      @(posedge clock);
      if (s_new.bvalid && s_new.bready) break;
      if (wait_cycle == 1999) $fatal(1, "upstream B timeout");
    end
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($urandom(seed));
    s_new.arvalid = 0;
    s_new.rready = 0;
    s_new.awvalid = 0;
    s_new.wvalid = 0;
    s_new.bready = 0;
    m_new.arready = 0;
    m_new.rvalid = 0;
    m_new.awready = 0;
    m_new.wready = 0;
    m_new.bvalid = 0;
    repeat (4) @(negedge clock);
    reset = 1'b0;
    for (int wait_cycle = 0; wait_cycle < 3000; wait_cycle++) begin
      @(negedge clock);
      if (s_new.arready) break;
      if (wait_cycle == 2999) $fatal(1, "L2 reset wipe timeout");
    end
    for (int txn = 0; txn < 600; txn++) begin
      logic [XLEN-1:0] addr;
      int kind;
      addr = XLEN'('h80000000) + (XLEN'($urandom_range(0, 11)) << 16);
      kind = $urandom_range(0, 10);
      if (kind <= 2) write_one(addr);
      else if (kind <= 4) read_one(XLEN'('h10000000) + (XLEN'(txn) << 3), 4'h0);
      else read_one(addr, 4'hf);
    end
    repeat (100) @(negedge clock);
    if (reads < 100 || writes < 100 || bypasses < 20 || evictions < 1)
      $fatal(
          1,
          "coverage reads=%0d writes=%0d bypasses=%0d evictions=%0d",
          reads,
          writes,
          bypasses,
          evictions
      );
    $display("PASS: L2 lockstep seed=%0d cycles=%0d reads=%0d writes=%0d bypass=%0d evict=%0d",
             seed, cycles, reads, writes, bypasses, evictions);
    $finish;
  end
endmodule
