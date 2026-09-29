`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
module tb_cache_stream #(
    parameter bit WriteBack = 0
);
  logic coherent_ready, coherent_request, coherent_write;
  logic writeback_error, writeback_idle;
  logic writeback_drain = 0;
`ifdef RAPT_TEST_RNP
  localparam bit Rnp = 1;
`else
  localparam bit Rnp = 0;
`endif
`ifdef RAPT_L2_STORE_WRITEBACK
  localparam bit L2WriteBack = !Rnp;
`else
  localparam bit L2WriteBack = 0;
`endif
  localparam int XLEN = `RAPT_XLEN;
  localparam int WordBytes = XLEN / 8;
  localparam int LineBytes = `RAPT_CACHE_LINE_BYTES;
  localparam int DemandIndex = LineBytes / WordBytes > 3 ? 3 : LineBytes / WordBytes - 1;
  localparam int CapacityBytes = (1 << `RAPT_L1D_LEN) * LineBytes * `RAPT_L1D_N_WAYS;
  localparam int Words = (L2WriteBack ? 1048576 : 65536) / WordBytes;
  logic probe_valid_i, probe_ready_o;
  logic hold_probe_ack = 0;
  logic [XLEN-1:0] probe_addr_i;
  logic probe_release_valid_o, probe_release_ready_i;
  logic [XLEN-1:0] probe_release_addr_o, probe_release_data_o;
  logic release_valid_o, release_ready_i, release_ack_i;
  logic release_has_data_o, release_mask_o, release_last_o;
  logic [XLEN-1:0] release_addr_o, release_data_o;
  int clean_releases = 0, dirty_releases = 0, release_acks = 0;
  always @(posedge clock)
    if (!reset) begin
      if (release_valid_o && release_ready_i && release_last_o) begin
        if (release_has_data_o) dirty_releases++;
        else clean_releases++;
      end
      if (release_ack_i) begin
        release_acks++;
`ifdef RAPT_L2_EN
`ifndef RAPT_TEST_RNP
        if (g_l2.l2.dir_write_clients !== 1'b0 || g_l2.l2.dir_write_state !== 2'b11)
          $fatal(1, "ReleaseAck did not move ownership to L2 Tip");
`endif
`endif
      end
`ifdef RAPT_L2_EN
`ifndef RAPT_TEST_RNP
      if (g_l2.l2.dir_client_mark && g_l2.l2.dir_write_ready && g_l2.l2.dir_write_state !== 2'b10)
        $fatal(1, "D-client acquire did not move L2 state to Trunk");
`endif
`endif
    end
  logic probe_window_i, writeback_bus_pending_o;
  logic l2_probe_valid, inject_probe_valid = 1'b0;
  logic [XLEN-1:0] l2_probe_addr, inject_probe_addr = '0;
  bit watch_real_probe = 0, saw_real_probe = 0;
  logic clock = 0, reset = 1;
  assign probe_valid_i = inject_probe_valid || l2_probe_valid;
  assign probe_addr_i = inject_probe_valid ? inject_probe_addr : l2_probe_addr;
  always @(posedge clock)
    if (watch_real_probe && l2_probe_valid && l2_probe_addr == XLEN'('h80000000))
      saw_real_probe <= 1'b1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  rou_cmu_if rou_cmu ();
  mem_link_if mem ();
  axi4_if cpu_axi (), l2_outer_axi (), axi ();
  rapt_l1d #(
      .WriteBack(WriteBack)
  ) dut (
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .*
  );
  rapt_bus bus_dut (
      .coherent_ready,
      .coherent_request,
      .coherent_write,
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .l1d_bus,
      .l1i_bus,
      .mem
  );
  rapt_axi_master adapter (
      .clock,
      .reset,
      .mem,
      .axi(cpu_axi)
  );
  if (Rnp) begin : g_rnp
    assign l2_probe_valid = 1'b0;
    assign l2_probe_addr = '0;
    assign probe_release_ready_i = 1'b0;
    assign release_ready_i = 1'b0;
    assign release_ack_i = 1'b0;
    assign probe_window_i = 1'b0;
    logic [31:0] rnp_mdata, rnp_cdata;
    logic rnp_arvalid, rnp_arready, rnp_rvalid, rnp_rready;
    logic rnp_awvalid, rnp_awready, rnp_wvalid, rnp_wready, rnp_bvalid, rnp_bready;
    logic [3:0] rnp_wstrb;
    logic [1:0] rnp_rwstate;
    axi2rnp u_axi2rnp (
        .clk(clock),
        .reset(reset),
        .axi_arburst(cpu_axi.arburst),
        .axi_arsize(cpu_axi.arsize),
        .axi_arlen(cpu_axi.arlen),
        .axi_arid(cpu_axi.arid),
        .axi_araddr(cpu_axi.araddr),
        .axi_arvalid(cpu_axi.arvalid),
        .axi_arready(cpu_axi.arready),
        .axi_rid(cpu_axi.rid),
        .axi_rlast(cpu_axi.rlast),
        .axi_rdata(cpu_axi.rdata),
        .axi_rresp(cpu_axi.rresp),
        .axi_rvalid(cpu_axi.rvalid),
        .axi_rready(cpu_axi.rready),
        .axi_awburst(cpu_axi.awburst),
        .axi_awsize(cpu_axi.awsize),
        .axi_awlen(cpu_axi.awlen),
        .axi_awid(cpu_axi.awid),
        .axi_awaddr(cpu_axi.awaddr),
        .axi_awvalid(cpu_axi.awvalid),
        .axi_awready(cpu_axi.awready),
        .axi_wlast(cpu_axi.wlast),
        .axi_wdata(cpu_axi.wdata),
        .axi_wstrb(cpu_axi.wstrb),
        .axi_wvalid(cpu_axi.wvalid),
        .axi_wready(cpu_axi.wready),
        .axi_bid(cpu_axi.bid),
        .axi_bresp(cpu_axi.bresp),
        .axi_bvalid(cpu_axi.bvalid),
        .axi_bready(cpu_axi.bready),
        .rnp_mdata(rnp_mdata),
        .rnp_cdata(rnp_cdata),
        .rnp_arvalid(rnp_arvalid),
        .rnp_arready(rnp_arready),
        .rnp_rvalid(rnp_rvalid),
        .rnp_rready(rnp_rready),
        .rnp_awvalid(rnp_awvalid),
        .rnp_awready(rnp_awready),
        .rnp_wstrb(rnp_wstrb),
        .rnp_wvalid(rnp_wvalid),
        .rnp_wready(rnp_wready),
        .rnp_bvalid(rnp_bvalid),
        .rnp_bready(rnp_bready),
        .rnp_rwstate(rnp_rwstate)
    );
    rnp2axi u_rnp2axi (
        .clk(clock),
        .reset(reset),
        .axi_arburst(axi.arburst),
        .axi_arsize(axi.arsize),
        .axi_arlen(axi.arlen),
        .axi_arid(axi.arid),
        .axi_araddr(axi.araddr),
        .axi_arvalid(axi.arvalid),
        .axi_arready(axi.arready),
        .axi_rid(axi.rid),
        .axi_rlast(axi.rlast),
        .axi_rdata(axi.rdata),
        .axi_rresp(axi.rresp),
        .axi_rvalid(axi.rvalid),
        .axi_rready(axi.rready),
        .axi_awburst(axi.awburst),
        .axi_awsize(axi.awsize),
        .axi_awlen(axi.awlen),
        .axi_awid(axi.awid),
        .axi_awaddr(axi.awaddr),
        .axi_awvalid(axi.awvalid),
        .axi_awready(axi.awready),
        .axi_wlast(axi.wlast),
        .axi_wdata(axi.wdata),
        .axi_wstrb(axi.wstrb),
        .axi_wvalid(axi.wvalid),
        .axi_wready(axi.wready),
        .axi_bid(axi.bid),
        .axi_bresp(axi.bresp),
        .axi_bvalid(axi.bvalid),
        .axi_bready(axi.bready),
        .rnp_mdata(rnp_mdata),
        .rnp_cdata(rnp_cdata),
        .rnp_arvalid(rnp_arvalid),
        .rnp_arready(rnp_arready),
        .rnp_rvalid(rnp_rvalid),
        .rnp_rready(rnp_rready),
        .rnp_awvalid(rnp_awvalid),
        .rnp_awready(rnp_awready),
        .rnp_wstrb(rnp_wstrb),
        .rnp_wvalid(rnp_wvalid),
        .rnp_wready(rnp_wready),
        .rnp_bvalid(rnp_bvalid),
        .rnp_bready(rnp_bready),
        .rnp_rwstate(rnp_rwstate)
    );
  end else begin : g_l2
    rapt_l2 l2 (
        .clock,
        .reset,
        .axi_s(cpu_axi),
        .axi_m(l2_outer_axi),
        .cbo_inval_i(cmu_bcast.cbo_inval),
        .cbo_block_i(cmu_bcast.cbo_block),
        .probe_valid_o(l2_probe_valid),
        .probe_addr_o(l2_probe_addr),
        .probe_ready_i(probe_ready_o && !hold_probe_ack),
        .probe_release_valid_i(probe_release_valid_o),
        .probe_release_addr_i(probe_release_addr_o),
        .probe_release_data_i(probe_release_data_o),
        .probe_release_ready_o(probe_release_ready_i),
        .release_valid_i(release_valid_o),
        .release_addr_i(release_addr_o),
        .release_data_i(release_data_o),
        .release_has_data_i(release_has_data_o),
        .release_mask_i(release_mask_o),
        .release_last_i(release_last_o),
        .release_ready_o(release_ready_i),
        .release_ack_o(release_ack_i),
        .l1d_writeback_pending_i(writeback_bus_pending_o),
        .probe_window_o(probe_window_i)
    );
    rapt_axi_r_buffer #(
        .XLEN(XLEN),
        .Enable(L2WriteBack)
    ) outer_r_buffer (
        .clock,
        .reset,
        .upstream(l2_outer_axi),
        .downstream(axi)
    );
`ifdef RAPT_L2_EN
    initial begin
      if (l2.BoomBankedStore ? l2.TagBits != 18 : l2.TagBits != `RAPT_PADDR_BITS -
          `RAPT_L2_LEN
          - `RAPT_L2_LINE_LEN - $clog2(
              XLEN / 8
          ))
        $fatal(1, "L2 tag width differs from its configured physical geometry");
    end
`endif
  end
  `include "tb_l1d_defaults.svh"

  logic [XLEN-1:0] ram[Words];
  logic rd_busy, wr_busy, b_wait;
  logic hold_read_response = 1'b0;
  logic hold_write_response = 1'b0;
  logic [XLEN-1:0] rd_addr, wr_addr;
  logic [7:0] rd_left, wr_left;
  logic [2:0] rd_size, wr_size;
  logic [1:0] rd_kind, wr_kind;
  logic [3:0] rd_id, wr_id;
  logic [31:0] rng = 32'h31415926;
  int rd_beat, b_delay;
  int
      read_requests = 0,
      write_requests = 0,
      read_beats = 0,
      write_beats = 0,
      responses = 0,
      l1_requests = 0;
  int error_beat=-1;
  bit check_narrow=0;
  logic [7:0] last_l1_len;
  bit write_error=0;
  function automatic int index_of(input logic [XLEN-1:0] addr);
    return int'((addr - XLEN'('h80000000)) / XLEN'(WordBytes));
  endfunction
  assign axi.arready = !rd_busy && !axi.rvalid && rng[0];
  assign axi.awready = !wr_busy && !b_wait && !axi.bvalid && rng[1];
  assign axi.wready = wr_busy && rng[2];
  always_ff @(posedge clock) begin
    if (reset) begin
      rd_busy<=0;
      wr_busy<=0;
      b_wait<=0;
      axi.rvalid<=0;
      axi.bvalid<=0;
      axi.rid<=0;
      axi.rdata<=0;
      axi.rlast<=0;
      axi.rresp<=0;
      axi.bid<=0;
      axi.bresp<=0;
    end else begin
      rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
      if (l1d_bus.arvalid && l1d_bus.rready && !l1d_bus.ar_ptw) begin
        l1_requests++;
        last_l1_len = l1d_bus.arlen;
        if (check_narrow && l1d_bus.arlen != 0)
          $fatal(1, "PMP-constrained demand became a line request");
      end
      if (axi.arvalid && axi.arready) begin
        if (index_of(axi.araddr) < 0 || index_of(axi.araddr) >= Words)
          $fatal(1, "read address outside RAM");
        if (check_narrow && axi.arlen != 0) $fatal(1, "L2 widened a PMP-constrained demand");
        rd_busy<=1;
        rd_addr<=axi.araddr;
        rd_left<=axi.arlen;
        rd_size<=axi.arsize;
        rd_kind<=axi.arburst;
        rd_id<=axi.arid;
        rd_beat<=0;
        read_requests++;
      end
      if (axi.rvalid && axi.rready) begin
        axi.rvalid <= 0;
        read_beats++;
      end
      if (rd_busy && (!axi.rvalid || axi.rready) && rng[3] && !hold_read_response) begin
        axi.rvalid<=1;
        axi.rid<=rd_id;
        axi.rdata<=ram[index_of(rd_addr)];
        axi.rresp<=rd_beat==error_beat ? 2'b10 : 2'b00;
        axi.rlast<=rd_left==0;
        rd_left<=rd_left-1;
        rd_beat<=rd_beat+1;
        if (rd_kind == 1) rd_addr <= rd_addr + (XLEN'(1) << rd_size);
        if (rd_left == 0) rd_busy <= 0;
      end
      if (axi.awvalid && axi.awready) begin
        wr_busy<=1;
        wr_addr<=axi.awaddr;
        wr_left<=axi.awlen;
        wr_size<=axi.awsize;
        wr_kind<=axi.awburst;
        wr_id<=axi.awid;
        write_requests++;
      end
      if (axi.wvalid && axi.wready) begin
        if (axi.wlast != (wr_left == 0)) $fatal(1, "WLAST does not match AWLEN");
        for (int b = 0; b < WordBytes; b++)
        if (axi.wstrb[b]) ram[index_of(wr_addr)][b*8+:8] <= axi.wdata[b*8+:8];
        write_beats++;
        wr_left <= wr_left - 1;
        if (wr_kind == 1) wr_addr <= wr_addr + (XLEN'(1) << wr_size);
        if (axi.wlast) begin
          wr_busy<=0;
          b_wait<=1;
          b_delay<=11;
        end
      end
      if (b_wait) begin
        if (b_delay != 0) b_delay <= b_delay - 1;
        else if (!hold_write_response) begin
          b_wait<=0;
          axi.bvalid<=1;
          axi.bid<=wr_id;
          axi.bresp<=write_error ? 2'b10 : 0;
        end
      end
      if (axi.bvalid && axi.bready) begin
        axi.bvalid <= 0;
        responses++;
      end
    end
  end

  task automatic idle;
    for (int n = 0; n < 10000; n++) begin
      @(negedge clock);
      if (lsu_l1d.idle && !rd_busy && !axi.rvalid && !wr_busy && !b_wait && !axi.bvalid) return;
    end
    $fatal(1, "cache stream did not drain");
  endtask
  task automatic store_response_hit_transition;
    logic [XLEN-1:0] base;
    base = XLEN'('h80078000);
    @(negedge clock);
    lsu_l1d.waddr = base;
    lsu_l1d.wdata = XLEN'('h11112222);
    lsu_l1d.walu = 8'({WordBytes{1'b1}});
    lsu_l1d.wvalid = 1;
    for (int n = 0; n < 10000 && !lsu_l1d.wready; n++) @(negedge clock);
    if (!lsu_l1d.wready) $fatal(1, "first cold store timed out");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wdata = XLEN'('h33334444);
    for (int n = 0; n < 10000; n++) begin
      #1;
      if (lsu_l1d.wready) break;
      @(negedge clock);
    end
    if (!lsu_l1d.wready) $fatal(1, "second same-word store timed out");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.waddr = base + XLEN'(LineBytes);
    lsu_l1d.wdata = XLEN'('h55556666);
    for (int n = 0; n < 10000; n++) begin
      #1;
      if (lsu_l1d.wready) break;
      @(negedge clock);
    end
    if (!lsu_l1d.wready) $fatal(1, "third different-line store timed out");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    idle();
    load(base + XLEN'(LineBytes + WordBytes), ram[index_of(base+XLEN'(LineBytes+WordBytes))]);
    load(base + XLEN'(LineBytes), XLEN'('h55556666));
    load(base, XLEN'('h33334444));
    $display("PASS: store response retains ownership across miss-to-hit transition RV%0d", XLEN);
  endtask
  task automatic clean_probe_with_pending_victim;
    logic [XLEN-1:0] base;
    base = XLEN'('h8007c100);
    @(negedge clock);
    lsu_l1d.waddr = base;
    lsu_l1d.wdata = XLEN'('h11227788);
    lsu_l1d.walu = 8'({WordBytes{1'b1}});
    lsu_l1d.wvalid = 1;
    for (int n = 0; n < 10000 && !lsu_l1d.wready; n++) @(negedge clock);
    if (!lsu_l1d.wready) $fatal(1, "partial clean-line setup timed out");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    idle();
    fork
      instruction_read(base + XLEN'(2 * WordBytes));
      begin
        bit instruction_accepted;
        instruction_accepted = 0;
        for (int cycle = 0; cycle < 10000 && !instruction_accepted; cycle++) begin
          @(posedge clock);
          instruction_accepted = cpu_axi.arvalid && cpu_axi.arready && cpu_axi.arid == 1;
        end
        if (!instruction_accepted) $fatal(1, "owner-Get test did not issue its I-side request");
        // This miss proposes releasing the clean partial L1D line on the
        // edge that the earlier I-side Get enters its owner Probe state.
        load(base + XLEN'(WordBytes), ram[index_of(base+XLEN'(WordBytes))]);
      end
    join
    load(base, XLEN'('h11227788));
    $display("PASS: clean owner Probe bypasses an unstarted voluntary victim Release RV%0d", XLEN);
  endtask
  task automatic store_word_for_probe_test(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                                           input bit require_local = 0);
    @(negedge clock);
    lsu_l1d.waddr = addr;
    lsu_l1d.wdata = data;
    lsu_l1d.walu = 8'({WordBytes{1'b1}});
    lsu_l1d.wvalid = 1;
    for (int cycle = 0; cycle < 10000; cycle++) begin
      #1;
      if (lsu_l1d.wready) break;
      @(negedge clock);
    end
    if (!lsu_l1d.wready) $fatal(1, "probe test store timed out addr=%h", addr);
    if (require_local && !dut.local_store_ready)
      $fatal(1, "other-victim setup store did not dirty locally addr=%h", addr);
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    idle();
    repeat (3) @(negedge clock);
  endtask
  task automatic clean_probe_with_other_dirty_victim;
    logic [XLEN-1:0] probe_line, victim_line;
    probe_line = XLEN'('h8007d100);
    victim_line = XLEN'('h8007d200);
    store_word_for_probe_test(probe_line, XLEN'('h11223344));
    idle();
    store_word_for_probe_test(victim_line, XLEN'('h22334455));
    idle();
    store_word_for_probe_test(victim_line, XLEN'('h55667788), 1);
    idle();
    if (!dut.dirty_any) $fatal(1, "other-victim setup did not dirty its L1D copy");
    hold_probe_ack = 1;
    fork
      begin
        bit probe_seen;
        probe_seen = 0;
        for (int cycle = 0; cycle < 10000 && !probe_seen; cycle++) begin
          @(posedge clock);
          probe_seen = l2_probe_valid;
        end
        if (!probe_seen) $fatal(1, "other-victim test did not issue its Probe");
        repeat (12) @(posedge clock);
        @(negedge clock);
        hold_probe_ack = 0;
      end
      instruction_read(probe_line + XLEN'(2 * WordBytes));
      begin
        bit instruction_accepted;
        instruction_accepted = 0;
        for (int cycle = 0; cycle < 10000 && !instruction_accepted; cycle++) begin
          @(posedge clock);
          instruction_accepted = cpu_axi.arvalid && cpu_axi.arready && cpu_axi.arid == 1;
        end
        if (!instruction_accepted) $fatal(1, "other-victim test did not issue its I-side request");
        load(victim_line + XLEN'(WordBytes), ram[index_of(victim_line+XLEN'(WordBytes))]);
      end
    join
    load(victim_line, XLEN'('h55667788));
    load(probe_line, XLEN'('h11223344));
    $display("PASS: clean Probe preserves a different dirty victim's Release ordering RV%0d", XLEN);
  endtask
  task automatic writeback_response_ownership_race;
    logic [XLEN-1:0] expected;
    int requests_before, responses_before, beats_before;
    requests_before = write_requests;
    responses_before = responses;
    beats_before = write_beats;
    expected = XLEN == 64 ? XLEN'('hcafebabe13572468) : XLEN'('h1357a568);
    hold_write_response = 1;

    // Dirty a resident word with a partial-store RMW, then issue a
    // write-through partial miss and hold its B response.  A drain requested
    // in that window must not mistake the older store response for a WB beat.
    @(negedge clock);
    lsu_l1d.waddr = XLEN'('h80000000) + (XLEN == 64 ? XLEN'(4) : XLEN'(1));
    lsu_l1d.wdata = XLEN == 64 ? XLEN'('hcafebabe) : XLEN'('ha5);
    lsu_l1d.walu = XLEN == 64 ? 8'h0f : 8'h01;
    lsu_l1d.wvalid = 1;
    #1;
    if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "partial WB store was not accepted locally");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.waddr = XLEN'('h8000e000);
    lsu_l1d.wdata = XLEN'('h5a);
    lsu_l1d.walu = 8'h01;

    for (int cycle = 0; cycle < 10000 && write_beats == beats_before; cycle++) @(negedge clock);
    if (write_beats == beats_before || !b_wait || lsu_l1d.wready)
      $fatal(1, "write-through setup did not reach a held B response");
    writeback_drain = 1;
    repeat (16) begin
      @(negedge clock);
      if (!dut.dirty_any || dut.wb_valid || lsu_l1d.wready)
        $fatal(1, "WB stole or bypassed an older L1D store response");
    end

    hold_write_response = 0;
    for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
    if (!lsu_l1d.wready || lsu_l1d.werr || dut.wb_valid)
      $fatal(1, "older L1D store response was not returned to its owner");
    @(posedge clock);
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    for (int cycle = 0; cycle < 10000 && !writeback_idle; cycle++) @(negedge clock);
    if (!writeback_idle || writeback_error || ram[0] != expected
        || write_requests - requests_before != 2 || responses - responses_before != 2)
      $fatal(
          1,
          "WB response ownership race failed data=%h expected=%h aw=%0d b=%0d",
          ram[0],
          expected,
          write_requests - requests_before,
          responses - responses_before
      );
    writeback_drain = 0;
    load(XLEN'('h80000000), expected, 1);
    lsu_l1d.waddr = XLEN'('h80000000);
    lsu_l1d.walu = 8'({WordBytes{1'b1}});
    $display("PASS: WB preserves older store response ownership RV%0d", XLEN);
  endtask
  task automatic load(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] expected,
                      input bit hot = 0, input bit early = 0);
    int before_requests;
    before_requests = l1_requests;
    @(negedge clock);
    lsu_l1d.raddr=addr;
    lsu_l1d.ralu=XLEN==64 ? 5'b00011 : 5'b00010;
    lsu_l1d.rvalid=1;
    for (int n = 0; n < 10000; n++) begin
      #1;
      if (lsu_l1d.rready) begin
        if (early && (!dut.refill_line || int'(dut.refill_word) == LineBytes / WordBytes - 1))
          $fatal(1, "demand was not returned before final refill beat");
        if (lsu_l1d.trap || lsu_l1d.rdata != expected)
          $fatal(
              1, "load %h got=%h expected=%h trap=%b", addr, lsu_l1d.rdata, expected, lsu_l1d.trap
          );
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        idle();
        if (hot && l1_requests != before_requests) $fatal(1, "resident word missed %h", addr);
        return;
      end
      @(negedge clock);
    end
    $fatal(1, "load timed out addr=%h", addr);
  endtask
  task automatic instruction_read(input logic [XLEN-1:0] addr);
    bit accepted;
    accepted = 0;
    @(negedge clock);
    l1i_bus.araddr = addr;
    l1i_bus.arburst = 0;
    l1i_bus.ar_ptw = 0;
    l1i_bus.arvalid = 1;
    for (int cycle = 0; cycle < 10000 && !accepted; cycle++) begin
      #1;
      if (l1i_bus.rready) accepted = 1;
      @(negedge clock);
    end
    if (!accepted) $fatal(1, "I-side request was not accepted addr=%h", addr);
    l1i_bus.arvalid = 0;
    for (int cycle = 0; cycle < 10000 && !l1i_bus.rvalid; cycle++) @(negedge clock);
    if (!l1i_bus.rvalid) $fatal(1, "I-side response timed out addr=%h", addr);
    if (l1i_bus.rerr || l1i_bus.rdata != ram[index_of(addr)])
      $fatal(1, "I-side refill failed addr=%h data=%h", addr, l1i_bus.rdata);
    @(posedge clock);
    @(negedge clock);
    idle();
  endtask
  task automatic invalidate(input logic [XLEN-1:0] address);
    @(negedge clock);
    cmu_bcast.cbo_block=address[XLEN-1:6];
    cmu_bcast.cbo_inval=1;
    cmu_bcast.flush_pipe=1;
    @(negedge clock);
    cmu_bcast.cbo_inval=0;
    cmu_bcast.flush_pipe=0;
    repeat (3) @(negedge clock);
  endtask
  task automatic zero_block(input logic [XLEN-1:0] addr, input bit fail_b);
    int aw0, w0, b0;
    bit maintenance_sent;
    maintenance_sent=0;
    aw0=write_requests;
    w0=write_beats;
    b0=responses;
    write_error=fail_b;
    @(negedge clock);
    lsu_l1d.waddr=addr;
    lsu_l1d.wzero=1;
    lsu_l1d.wvalid=1;
    lsu_l1d.walu=XLEN==64 ? 8'hff : 8'h0f;
    lsu_l1d.wdata=0;
    for (int n = 0; n < 10000; n++) begin
      cmu_bcast.cbo_inval=0;
      cmu_bcast.flush_pipe=0;
      if (!maintenance_sent && write_beats > w0) begin
        cmu_bcast.cbo_block=addr[XLEN-1:6];
        cmu_bcast.cbo_inval=1;
        cmu_bcast.flush_pipe=1;
        maintenance_sent=1;
      end
      #1;
      if (lsu_l1d.wready) begin
        if (L2WriteBack) begin
          if (lsu_l1d.werr || write_requests != aw0 || write_beats != w0 || responses != b0)
            $fatal(1, "BOOM L2 ZERO did not allocate locally");
        end else if (lsu_l1d.werr != fail_b || write_beats - w0 != 64 / WordBytes)
          $fatal(1, "ZERO completed before complete burst/B");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.wvalid=0;
        lsu_l1d.wzero=0;
        write_error=0;
        idle();
        if (L2WriteBack) begin
          if (write_requests != aw0 || write_beats != w0 || responses != b0)
            $fatal(1, "BOOM L2 ZERO unexpectedly wrote external memory");
          // Publish the dirty line through CBO so later capacity checks also
          // compare against the backing memory rather than a private L2 copy.
          invalidate(addr);
          for (int cycle = 0; cycle < 10000 && responses == b0; cycle++) @(negedge clock);
          if (write_requests - aw0 != 1 || write_beats - w0 != LineBytes / WordBytes
              || responses - b0 != 1)
            $fatal(1, "BOOM L2 ZERO CBO did not write back one line");
          idle();
        end else if(write_requests-aw0!=(Rnp ? 64/WordBytes : 1) || responses-b0!=(Rnp ? 64/WordBytes : 1))
          $fatal(1, "ZERO not one AW/B transaction");
        return;
      end
      @(negedge clock);
    end
    $fatal(1, "ZERO timed out");
  endtask
  task automatic cancelled_fill;
    int before_beats;
    logic [XLEN-1:0] base;
    base=XLEN'('h80002000);
    before_beats=read_beats;
    @(negedge clock);
    lsu_l1d.raddr=base+XLEN'(LineBytes-WordBytes);
    lsu_l1d.rvalid=1;
    for (int n = 0; n < 10000; n++) begin
      @(negedge clock);
      if (read_beats >= before_beats + 1) begin
        // Word zero was already read from RAM. A pending L2 install must be
        // followed by the queued CBO clear before a new request can hit it.
        ram[index_of(base)]=XLEN'('h77aa55cc);
        cmu_bcast.cbo_block=base[XLEN-1:6];
        cmu_bcast.cbo_inval=1;
        cmu_bcast.flush_pipe=1;
        #1;
        if (lsu_l1d.rready) $fatal(1, "cancelled fill completed");
        @(negedge clock);
        lsu_l1d.rvalid=0;
        cmu_bcast.cbo_inval=0;
        cmu_bcast.flush_pipe=0;
        idle();
        load(base, XLEN'('h77aa55cc));
        return;
      end
    end
    $fatal(1, "cancelled fill did not start");
  endtask
  task automatic errored_fill;
    logic [XLEN-1:0] addr;
    addr=XLEN'('h80003000)+XLEN'(DemandIndex*WordBytes);
    error_beat=DemandIndex;
    @(negedge clock);
    lsu_l1d.raddr=addr;
    lsu_l1d.rvalid=1;
    for (int n = 0; n < 10000; n++) begin
      #1;
      if (lsu_l1d.rready) begin
        if (!lsu_l1d.trap || lsu_l1d.cause != 5 || rd_busy || axi.rvalid)
          $fatal(1, "demand error did not drain burst before precise fault");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.rvalid=0;
        error_beat=-1;
        idle();
        load(addr, ram[index_of(addr)]);
        return;
      end
      @(negedge clock);
    end
    $fatal(1, "errored fill lost completion");
  endtask
  task automatic pmp_boundary(input int kind);
    logic [XLEN-1:0] base;
    int entry_id, requests_before;
    base=XLEN'('h80005000);
    entry_id=kind==1 ? 1 : 0;
    @(negedge clock);
    pmp_update.addr_we=1;
    pmp_update.addr_idx=0;
    pmp_update.raw_addr=$bits(pmp_update.raw_addr)'((base+XLEN'(LineBytes/2))>>2);
    pmp_update.napot_mask=1;
    @(negedge clock);
    if (kind == 1) begin
      pmp_update.addr_idx=1;
      pmp_update.raw_addr=$bits(pmp_update.raw_addr)'((base+XLEN'(LineBytes/2)+4)>>2);
      @(negedge clock);
    end
    pmp_update.addr_we=0;
    pmp_update.cfg_we='1;
    pmp_update.cfg_r=0;
    pmp_update.cfg_w=0;
    pmp_update.cfg_x=0;
    pmp_update.cfg_l=0;
    pmp_update.mode_off='1;
    pmp_update.mode_tor=0;
    pmp_update.mode_na4=0;
    pmp_update.mode_napot=0;
    pmp_update.cfg_l[entry_id]=1;
    pmp_update.mode_off[entry_id]=0;
    pmp_update.mode_na4[entry_id]=kind==0;
    pmp_update.mode_tor[entry_id]=kind==1;
    pmp_update.mode_napot[entry_id]=kind==2;
    @(negedge clock);
    pmp_update.cfg_we = 0;
    invalidate(base);
    idle();
    check_narrow = 1;
    load(base, ram[index_of(base)]);
    if (last_l1_len != 0) $fatal(1, "internal PMP boundary did not select word fallback");
    if (WriteBack && L2WriteBack) begin
      requests_before = l1_requests;
      load(base, ram[index_of(base)]);
      if (l1_requests == requests_before)
        $fatal(1, "L1D cached a scalar no-allocate read absent from inclusive L2");
    end
    check_narrow = 0;
    @(negedge clock);
    pmp_update.cfg_we='1;
    pmp_update.mode_off='1;
    pmp_update.mode_tor=0;
    pmp_update.mode_na4=0;
    pmp_update.mode_napot=0;
    pmp_update.cfg_l=0;
    @(negedge clock);
    pmp_update.cfg_we = 0;
    invalidate(base);
    idle();
    load(base, ram[index_of(base)]);
    if (last_l1_len != 8'(LineBytes / WordBytes - 1))
      $fatal(1, "uniform PMP did not restore line refill");
  endtask
  initial begin
    init_l1d_inputs();
    lsu_l1d.wzero=0;
    lsu_l1d.rvalid_b=0;
    l1i_bus.arvalid=0;
    l1i_bus.araddr=0;
    l1i_bus.arburst=0;
    l1i_bus.ar_ptw=0;
    l1i_bus.rpbmt=0;
    l1i_bus.noallocate = 0;
    l1i_bus.awvalid=0;
    l1i_bus.awaddr=0;
    l1i_bus.aw_ptw=0;
    l1i_bus.wvalid=0;
    l1i_bus.wdata=0;
    l1i_bus.wstrb=0;
    for (int i = 0; i < Words; i++) ram[i] = XLEN'('h12340000) + XLEN'(i);
    repeat (4) @(negedge clock);
    reset = 0;
    // A nonzero demanded offset selects its beat, then all other words hit.
    load(XLEN'('h80000000), ram[0], 0, 1);
    if (l1_requests != 1) $fatal(1, "cold line needed multiple L1D requests");
    for (int i = 0; i < LineBytes / WordBytes; i++)
    load(XLEN'('h80000000) + XLEN'(i * WordBytes), ram[i], 1);
    load(XLEN'('h80000040), ram[64/WordBytes]);
    load(XLEN'('h80001000), ram[4096/WordBytes]);
    // DMA-style memory change: clean both physical cache blocks explicitly.
    ram[0]=XLEN'('h55667788);
    ram[4096/WordBytes]=XLEN'('h33445566);
    invalidate(XLEN'('h80000000));
    invalidate(XLEN'('h80001000));
    idle();
    load(XLEN'('h80000000), ram[0]);
    load(XLEN'('h80001000), ram[4096/WordBytes]);
    load(XLEN'('h80000040), ram[64/WordBytes], 1);
    zero_block(XLEN'('h8000003f), 0);
    for (int i = 0; i < 64 / WordBytes; i++) load(XLEN'('h80000000) + XLEN'(i * WordBytes), 0);
    load(XLEN'('h80000040), ram[64/WordBytes], 1);
    zero_block(XLEN'('h80001000), !Rnp && !L2WriteBack);
    load(XLEN'('h80001000), 0);
    cancelled_fill();
    if (!Rnp) errored_fill();
    for (int kind = 0; kind < 3; kind++) pmp_boundary(kind);
    @(negedge clock);
    cmu_bcast.fence_time = 1;
    @(negedge clock);
    cmu_bcast.fence_time = 0;
    idle();
    for (int offset = 0; offset < CapacityBytes; offset += LineBytes)
    load(XLEN'('h80000000) + XLEN'(offset), ram[offset/WordBytes]);
    for (int offset = 0; offset < CapacityBytes; offset += WordBytes)
    load(XLEN'('h80000000) + XLEN'(offset), ram[offset/WordBytes], 1);
    if (!WriteBack && !Rnp && L2WriteBack) begin
      int before_probe_req;
      load(XLEN'('h80000000), ram[0], 1);
      load(XLEN'('h80001000), ram[4096/WordBytes], 1);
      before_probe_req = l1_requests;
      @(negedge clock);
      inject_probe_addr = XLEN'('h80000000);
      inject_probe_valid = 1'b1;
      for (int cycle = 0; cycle < 16 && !probe_ready_o; cycle++) @(negedge clock);
      if (!probe_ready_o) $fatal(1, "L1D did not acknowledge the L2 back-invalidation");
      inject_probe_valid = 1'b0;
      idle();
      load(XLEN'('h80001000), ram[4096/WordBytes], 1);
      if (l1_requests != before_probe_req)
        $fatal(1, "L2 probe invalidated another physical line in the same L1D set");
      load(XLEN'('h80000000), ram[0]);
      if (l1_requests != before_probe_req + 1)
        $fatal(1, "L1D retained a resident word after L2 back-invalidation");
      // Keep this D line resident while instruction requests fill competing
      // L2 ways. Exercise the actual directory-triggered probe path.
      watch_real_probe = 1;
      for (int i = 0; i < 256 && !saw_real_probe; i++)
      instruction_read(XLEN'('h80000000) + XLEN'(((i % 15) + 1) * 65536));
      watch_real_probe = 0;
      if (!saw_real_probe) $fatal(1, "L2 replacement never probed the resident L1D line");
      before_probe_req = l1_requests;
      load(XLEN'('h80000000), ram[0]);
      if (l1_requests != before_probe_req + 1)
        $fatal(1, "actual L2 replacement left a stale L1D copy");
    end
    if (WriteBack && L2WriteBack) begin
      int before_probe_req;
      int clean_before, dirty_before, ack_before;
      store_response_hit_transition();
      clean_probe_with_pending_victim();
      clean_probe_with_other_dirty_victim();
      clean_before = clean_releases;
      ack_before = release_acks;
      for (int i = 0; i < `RAPT_L1D_N_WAYS + 2; i++)
      load(XLEN'('h80050000 + i * 4096), ram[index_of(XLEN'('h80050000+i*4096))]);
      if (clean_releases <= clean_before || release_acks <= ack_before)
        $fatal(1, "clean L1D victim did not complete Release/ReleaseAck");

      // Retire a dirty L1D victim through ReleaseData. The outer RAM stays
      // stale while the L2 supplies the updated word on the next miss.
      for (int i = 0; i < `RAPT_L1D_N_WAYS; i++)
      load(XLEN'('h80068000 + i * 4096), ram[index_of(XLEN'('h80068000+i*4096))]);
      @(negedge clock);
      lsu_l1d.waddr = XLEN'('h80068000);
      lsu_l1d.wdata = XLEN'('h6a5a55a6);
      lsu_l1d.walu = 8'({WordBytes{1'b1}});
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "dirty victim setup did not stay local");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      dirty_before = dirty_releases;
      ack_before = release_acks;
      for (
          int i = `RAPT_L1D_N_WAYS; i < `RAPT_L1D_N_WAYS + 16 && dirty_releases == dirty_before; i++
      )
      load(XLEN'('h80068000 + i * 4096), ram[index_of(XLEN'('h80068000+i*4096))]);
      if (dirty_releases == dirty_before || release_acks <= ack_before)
        $fatal(1, "dirty L1D victim did not complete ReleaseData/ReleaseAck");
      if (ram[index_of(XLEN'('h80068000))] == XLEN'('h6a5a55a6))
        $fatal(1, "dirty L1D victim bypassed L2 write-back policy");
      // Force a scalar no-allocate read while that dirty line exists only
      // in L2. It must hit the L2 copy rather than stale outer RAM, and it
      // must not install an L1D line absent from a full-line refill.
      @(negedge clock);
      pmp_update.addr_we = 1;
      pmp_update.addr_idx = 0;
      pmp_update.raw_addr = $bits(pmp_update.raw_addr)'((XLEN'('h80068000)
          + XLEN'(LineBytes / 2)) >> 2);
      pmp_update.napot_mask = 1;
      @(negedge clock);
      pmp_update.addr_we = 0;
      pmp_update.cfg_we = '1;
      pmp_update.cfg_r = 0;
      pmp_update.cfg_w = 0;
      pmp_update.cfg_x = 0;
      pmp_update.cfg_l = 0;
      pmp_update.mode_off = '1;
      pmp_update.mode_tor = 0;
      pmp_update.mode_na4 = 0;
      pmp_update.mode_napot = 0;
      pmp_update.cfg_l[0] = 1;
      pmp_update.mode_off[0] = 0;
      pmp_update.mode_na4[0] = 1;
      @(negedge clock);
      pmp_update.cfg_we = 0;
      load(XLEN'('h80068000), XLEN'('h6a5a55a6));
      if (last_l1_len != 0) $fatal(1, "dirty L2 read did not use scalar fallback");
      ack_before = l1_requests;
      load(XLEN'('h80068000), XLEN'('h6a5a55a6));
      if (l1_requests == ack_before) $fatal(1, "scalar L1D fallback unexpectedly installed a line");
      @(negedge clock);
      pmp_update.cfg_we = '1;
      pmp_update.mode_off = '1;
      pmp_update.mode_na4 = 0;
      pmp_update.cfg_l = 0;
      @(negedge clock);
      pmp_update.cfg_we = 0;
      load(XLEN'('h80068000), XLEN'('h6a5a55a6));
      $display("PASS: clean/dirty voluntary L1D Release and ReleaseAck RV%0d", XLEN);

      load(XLEN'('h80000000), ram[0]);
      idle();
      @(negedge clock);
      lsu_l1d.waddr = XLEN'('h80000000);
      lsu_l1d.wdata = XLEN'('h76543210);
      lsu_l1d.walu = 8'({WordBytes{1'b1}});
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "L1D WB store did not stay local");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      load(XLEN'('h80000000), XLEN'('h76543210), 1);
      if (ram[0] == XLEN'('h76543210)) $fatal(1, "dirty L1D store reached outer memory early");
      watch_real_probe = 1;
      for (int i = 0; i < 256 && !saw_real_probe; i++)
      instruction_read(XLEN'('h80000000) + XLEN'(((i % 15) + 1) * 65536));
      watch_real_probe = 0;
      if (!saw_real_probe || ram[0] != XLEN'('h76543210))
        $fatal(1, "dirty L1D line was not released and written back on L2 replacement");
      before_probe_req = l1_requests;
      load(XLEN'('h80000000), XLEN'('h76543210));
      if (l1_requests != before_probe_req + 1)
        $fatal(1, "L2 replacement retained a dirty L1D copy");

      @(negedge clock);
      lsu_l1d.wdata = XLEN'('h13572468);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "second L1D WB store not local");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      load(XLEN'('h80000000), XLEN'('h13572468), 1);
      invalidate(XLEN'('h80000000));
      for (int cycle = 0; cycle < 10000 && ram[0] != XLEN'('h13572468); cycle++) @(negedge clock);
      if (ram[0] != XLEN'('h13572468))
        $fatal(1, "dirty L1D line was not released and written back on L2 CBO");
      before_probe_req = l1_requests;
      load(XLEN'('h80000000), XLEN'('h13572468));
      if (l1_requests != before_probe_req + 1) $fatal(1, "L2 CBO retained a dirty L1D copy");
      // A full-word L1D store miss first obtains L2 ownership, then installs
      // the word locally. Its next local hit can become dirty safely.
      @(negedge clock);
      lsu_l1d.waddr = XLEN'('h80020040);
      lsu_l1d.wdata = XLEN'('h11223344);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready) $fatal(1, "L1D store miss was not admitted by L2");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      load(XLEN'('h80020040), XLEN'('h11223344), 1);
      @(negedge clock);
      lsu_l1d.wdata = XLEN'('h44332211);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid)
        $fatal(1, "L1D store hit did not retain dirty ownership");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      invalidate(XLEN'('h80020040));
      for (
          int cycle = 0;
          cycle < 10000 && ram[index_of(XLEN'('h80020040))] != XLEN'('h44332211);
          cycle++
      )
      @(negedge clock);
      if (ram[index_of(XLEN'('h80020040))] != XLEN'('h44332211))
        $fatal(1, "store-miss owner was absent from L2 CBO probe");
      // A CBO can arrive on the same cycle as an ordinary L1D dirty drain.
      // The CBO must let that write enter L2 before scanning the directory.
      load(XLEN'('h80020040), XLEN'('h44332211));
      @(negedge clock);
      lsu_l1d.wdata = XLEN'('h55aa55aa);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "drain-race store was not local");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      writeback_drain = 1;
      cmu_bcast.cbo_block = XLEN'('h80020040) >> 6;
      cmu_bcast.cbo_inval = 1;
      cmu_bcast.flush_pipe = 1;
      @(negedge clock);
      cmu_bcast.cbo_inval = 0;
      cmu_bcast.flush_pipe = 0;
      for (int cycle = 0; cycle < 10000 && !writeback_idle; cycle++) @(negedge clock);
      if (!writeback_idle) $fatal(1, "L1D writeback and L2 CBO deadlocked");
      writeback_drain = 0;
      for (
          int cycle = 0;
          cycle < 10000 && ram[index_of(XLEN'('h80020040))] != XLEN'('h55aa55aa);
          cycle++
      )
      @(negedge clock);
      if (ram[index_of(XLEN'('h80020040))] != XLEN'('h55aa55aa))
        $fatal(1, "L2 CBO lost an overlapping L1D writeback");
      // The same ownership rule applies when the L2 line was first filled by
      // the I side and the D store finds it already resident.
      instruction_read(XLEN'('h80030080));
      @(negedge clock);
      lsu_l1d.waddr = XLEN'('h80030080);
      lsu_l1d.wdata = XLEN'('h12345678);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready) $fatal(1, "L1D store miss to resident L2 line stalled");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      load(XLEN'('h80030080), XLEN'('h12345678), 1);
      @(negedge clock);
      lsu_l1d.wdata = XLEN'('h87654321);
      lsu_l1d.wvalid = 1;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid)
        $fatal(1, "L1D local store hit after L2 hit was not dirty");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      invalidate(XLEN'('h80030080));
      for (
          int cycle = 0;
          cycle < 10000 && ram[index_of(XLEN'('h80030080))] != XLEN'('h87654321);
          cycle++
      )
      @(negedge clock);
      if (ram[index_of(XLEN'('h80030080))] != XLEN'('h87654321))
        $fatal(1, "store-hit owner was absent from L2 CBO probe");
      $display("PASS: dirty L1D release on L2 eviction and CBO RV%0d", XLEN);
    end
    if (WriteBack && !L2WriteBack) begin
      idle();
      @(negedge clock);
      lsu_l1d.waddr = XLEN'('h80000000);
      lsu_l1d.wdata = XLEN'('h76543210);
      lsu_l1d.walu = 8'({WordBytes{1'b1}});
      lsu_l1d.wvalid = 1;
      #1;
      if (!lsu_l1d.wready || l1d_bus.wvalid) $fatal(1, "WB store not local");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      repeat (4) @(negedge clock);
      load(XLEN'('h80000000), XLEN'('h76543210), 1);
      if (writeback_idle || ram[0] == XLEN'('h76543210))
        $fatal(1, "WB store did not retain dirty ownership");
      // A plain instruction refill does not imply FENCE.I. It may read the
      // old backing value while a dirty D-cache line remains private.
      @(negedge clock);
      l1i_bus.araddr = XLEN'('h80000000);
      l1i_bus.arburst = 0;
      l1i_bus.ar_ptw = 0;
      l1i_bus.arvalid = 1;
      #1;
      if (coherent_request || coherent_ready || !l1i_bus.rready)
        $fatal(1, "plain I-side refill incorrectly waited for dirty D-cache drain");
      @(posedge clock);
      @(negedge clock);
      l1i_bus.arvalid = 0;
      for (int cycle = 0; cycle < 10000 && !l1i_bus.rvalid; cycle++) @(negedge clock);
      if (!l1i_bus.rvalid || l1i_bus.rerr || l1i_bus.rdata != ram[0]
          || writeback_idle || ram[0] == XLEN'('h76543210))
        $fatal(1, "plain I-side refill did not preserve the dirty D-cache owner");
      @(posedge clock);
      @(negedge clock);

      // FENCE.I retirement requests this drain before L1I invalidation.
      writeback_drain = 1;
      for (int cycle = 0; cycle < 10000 && !writeback_idle; cycle++) @(negedge clock);
      if (!writeback_idle || ram[0] != XLEN'('h76543210))
        $fatal(1, "FENCE.I-style drain did not publish the dirty instruction line");
      writeback_drain = 0;
      l1i_bus.arvalid = 1;
      #1;
      if (!l1i_bus.rready) $fatal(1, "post-drain instruction refill was not accepted");
      @(posedge clock);
      @(negedge clock);
      l1i_bus.arvalid = 0;
      for (int cycle = 0; cycle < 10000 && !l1i_bus.rvalid; cycle++) @(negedge clock);
      if (!l1i_bus.rvalid || l1i_bus.rerr || l1i_bus.rdata != XLEN'('h76543210))
        $fatal(1, "post-drain instruction refill returned stale data");
      @(posedge clock);
      @(negedge clock);

      // A PTW read, unlike a plain refill, is coherent with committed D-side
      // page-table writes and retains the outstanding-read order barrier.
      hold_read_response = 1;
      l1i_bus.araddr = XLEN'('h8000f000);
      l1i_bus.ar_ptw = 1;
      l1i_bus.arvalid = 1;
      #1;
      if (!l1i_bus.rready) $fatal(1, "cold I-side PTW read was not captured");
      @(posedge clock);
      @(negedge clock);
      l1i_bus.arvalid = 0;
      lsu_l1d.wdata = XLEN'('h13572468);
      lsu_l1d.wvalid = 1;
      repeat (16) begin
        #1;
        if (lsu_l1d.wready || l1d_bus.wvalid)
          $fatal(1, "D-side store overtook outstanding I-side read");
        @(negedge clock);
      end
      hold_read_response = 0;
      for (int cycle = 0; cycle < 10000 && !l1i_bus.ptw_rvalid; cycle++) @(negedge clock);
      if (!l1i_bus.ptw_rvalid || l1i_bus.ptw_rerr || l1i_bus.rdata != ram[index_of(
              XLEN'('h8000f000)
          )])
        $fatal(1, "cold I-side PTW read response mismatch");
      l1i_bus.ar_ptw = 0;
      for (int cycle = 0; cycle < 10000 && !lsu_l1d.wready; cycle++) @(negedge clock);
      if (!lsu_l1d.wready || l1d_bus.wvalid)
        $fatal(1, "D-side store did not resume locally after I-side response");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      repeat (4) @(negedge clock);
      load(XLEN'('h80000000), XLEN'('h13572468), 1);
      writeback_drain = 1;
      for (int cycle = 0; cycle < 10000 && !writeback_idle; cycle++) @(negedge clock);
      if (!writeback_idle || writeback_error || ram[0] != XLEN'('h13572468))
        $fatal(1, "WB AXI drain after I-side coherence failed");
      writeback_drain = 0;
      $display("PASS: WB FENCE.I publication, PTW ordering and AXI drain RV%0d", XLEN);
      writeback_response_ownership_race();
      @(negedge clock);
      lsu_l1d.wdata = XLEN'('h24681357);
      lsu_l1d.wvalid = 1;
      #1;
      if (!lsu_l1d.wready) $fatal(1, "error-path WB store not accepted");
      @(negedge clock);
      lsu_l1d.wvalid = 0;
      repeat (4) @(negedge clock);
      write_error = 1;
      writeback_drain = 1;
      for (int cycle = 0; cycle < 10000 && !writeback_error; cycle++) @(negedge clock);
      if (!writeback_error) $fatal(1, "AXI B error did not reach WB");
      write_error = 0;
      repeat (32) begin
        @(negedge clock);
        if (!writeback_error || writeback_idle || !dut.dirty_any
            || l1d_bus.wvalid || l1d_bus.arvalid)
          $fatal(1, "AXI WB error did not preserve fail-stop");
      end
      $display("PASS: WB AXI error fail-stop RV%0d", XLEN);
    end
    $display("PASS: capacity %0d bytes, every refilled word hot; RNP=%0d", CapacityBytes, Rnp);
    if (L2WriteBack)
      $display(
          "PASS: cache stream RV%0d full-line refill, hot words, ZERO local allocate/CBO writeback, fill kill/error, PMP boundary fallback",
          XLEN
      );
    else
      $display(
          "PASS: cache stream RV%0d full-line refill, hot words, set CBO across L2, ZERO one AW/B, delayed/error B, fill kill/error, NA4/TOR/NAPOT boundary fallback",
          XLEN
      );
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "cache stream watchdog");
  end
endmodule
