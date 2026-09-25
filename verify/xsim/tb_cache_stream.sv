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
  localparam int XLEN = `RAPT_XLEN;
  localparam int WordBytes = XLEN / 8;
  localparam int LineBytes = `RAPT_CACHE_LINE_BYTES;
  localparam int DemandIndex = LineBytes / WordBytes > 3 ? 3 : LineBytes / WordBytes - 1;
  localparam int CapacityBytes = (1 << `RAPT_L1D_LEN) * LineBytes * `RAPT_L1D_N_WAYS;
  localparam int Words = 65536 / WordBytes;
  logic clock = 0, reset = 1;
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
  axi4_if cpu_axi (), axi ();
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
        .axi_m(axi),
        .cbo_inval_i(cmu_bcast.cbo_inval),
        .cbo_block_i(cmu_bcast.cbo_block)
    );
`ifdef RAPT_L2_EN
    initial begin
      if ($bits(
              l2.line_tag[0][0]
          ) != `RAPT_PADDR_BITS -
          `RAPT_L2_LEN
          - `RAPT_L2_LINE_LEN - $clog2(
              XLEN / 8
          ))
        $fatal(1, "L2 tag stores non-physical, index or offset bits");
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
  task automatic invalidate(input logic [11:6] block_id);
    @(negedge clock);
    cmu_bcast.cbo_block=block_id;
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
        cmu_bcast.cbo_block=addr[11:6];
        cmu_bcast.cbo_inval=1;
        cmu_bcast.flush_pipe=1;
        maintenance_sent=1;
      end
      #1;
      if (lsu_l1d.wready) begin
        if (lsu_l1d.werr != fail_b || write_beats - w0 != 64 / WordBytes)
          $fatal(1, "ZERO completed before complete burst/B");
        @(posedge clock);
        @(negedge clock);
        lsu_l1d.wvalid=0;
        lsu_l1d.wzero=0;
        write_error=0;
        idle();
        if(write_requests-aw0!=(Rnp ? 64/WordBytes : 1) || responses-b0!=(Rnp ? 64/WordBytes : 1))
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
        cmu_bcast.cbo_block=base[11:6];
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
    int entry_id;
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
    invalidate(base[11:6]);
    idle();
    check_narrow = 1;
    load(base, ram[index_of(base)]);
    if (last_l1_len != 0) $fatal(1, "internal PMP boundary did not select word fallback");
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
    invalidate(base[11:6]);
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
    // DMA-style memory change: clear both physical L2 colors selected by VA.
    ram[0]=XLEN'('h55667788);
    ram[4096/WordBytes]=XLEN'('h33445566);
    invalidate(0);
    idle();
    load(XLEN'('h80000000), ram[0]);
    load(XLEN'('h80001000), ram[4096/WordBytes]);
    load(XLEN'('h80000040), ram[64/WordBytes], 1);
    zero_block(XLEN'('h8000003f), 0);
    for (int i = 0; i < 64 / WordBytes; i++) load(XLEN'('h80000000) + XLEN'(i * WordBytes), 0);
    load(XLEN'('h80000040), ram[64/WordBytes], 1);
    zero_block(XLEN'('h80001000), !Rnp);
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
    if (WriteBack) begin
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
    $display(
        "PASS: cache stream RV%0d full-line refill, hot words, set CBO across L2, ZERO one AW/B, delayed/error B, fill kill/error, NA4/TOR/NAPOT boundary fallback",
        XLEN);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "cache stream watchdog");
  end
endmodule
