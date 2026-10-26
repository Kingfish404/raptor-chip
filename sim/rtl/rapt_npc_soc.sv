`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_dpi_c.svh"

// verilator lint_off UNDRIVEN
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off DECLFILENAME
// verilator lint_off UNUSEDSIGNAL
module raptSoC #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit L1dWriteBack = `RAPT_L1D_WRITEBACK,
    parameter int ReadOutstanding = 8
) (
    input  clock,
    output logic writeback_error_o,
    // Device writes are reported before a later SC may complete. Pending
    // holds SC while the platform drains a finite batch of notifications.
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0,

    // JTAG ports (P0). tck implicit = clock. Always present.
    input  jtag_trst_n,
    input  jtag_tms,
    input  jtag_tdi,
    output jtag_tdo,
    input  reset
);
`ifndef SYNTHESIS
`ifdef RAPT_LRSC_OBSERVE
  `include "rapt_ioq_observe.svh"
  `include "rapt_lrsc_observe.svh"
`elsif RAPT_SPEC_OBSERVE
  `include "rapt_ioq_observe.svh"
`endif
`endif
  logic auto_master_out_awready;
  logic auto_master_out_awvalid;
  logic [3:0] auto_master_out_awid;
  logic [XLEN-1:0] auto_master_out_awaddr;
  logic [7:0] auto_master_out_awlen;
  logic [2:0] auto_master_out_awsize;
  logic [1:0] auto_master_out_awburst;
  logic auto_master_out_wready;
  logic auto_master_out_wvalid;
  logic [XLEN-1:0] auto_master_out_wdata;
  logic [XLEN/8-1:0] auto_master_out_wstrb;
  logic auto_master_out_wlast;
  logic auto_master_out_bready;
  logic auto_master_out_bvalid;
  logic [3:0] auto_master_out_bid;
  logic [1:0] auto_master_out_bresp;
  logic auto_master_out_arready;
  logic auto_master_out_arvalid;
  logic [3:0] auto_master_out_arid;
  logic [XLEN-1:0] auto_master_out_araddr;
  logic [7:0] auto_master_out_arlen;
  logic [2:0] auto_master_out_arsize;
  logic [1:0] auto_master_out_arburst;
  logic auto_master_out_rready;
  logic auto_master_out_rvalid;
  logic [3:0] auto_master_out_rid;
  logic [XLEN-1:0] auto_master_out_rdata;
  logic [1:0] auto_master_out_rresp;
  logic auto_master_out_rlast;
  logic [3:0] auto_master_out_arcache, auto_master_out_awcache;

`ifdef RAPT_AXI_OBSERVE
`ifndef SYNTHESIS
  // Observation only: record accepted transfers at the external CPU boundary.
  // Separate AW/W/B records preserve their independent handshake timing.
  longint unsigned axi_observe_cycle = 0;
  always @(posedge clock) begin
    if (reset) axi_observe_cycle <= 0;
    else begin
      axi_observe_cycle <= axi_observe_cycle + 1;
`ifdef RAPT_SPEC_OBSERVE
      if (cpu.core.memory_subsystem.l1i_cache.slow_active)
        $display(
            "IFETCH_OBS %0d STATE %h %h %h %h %h %h",
            axi_observe_cycle,
            cpu.core.ifetch_io_owner_pc,
            cpu.core.memory_subsystem.l1i_cache.u_word_fetch.state,
            cpu.core.memory_subsystem.l1i_cache.slow_read_pbmt,
            cpu.core.ifetch_io_authorized,
            cpu.core.memory_subsystem.l1i_cache.slow_cancel,
            cpu.core.memory_subsystem.l1i_cache.u_word_fetch.io_owned
        );
      if (cpu.core.ifetch_io_start)
        $display("IFETCH_OBS %0d START %h", axi_observe_cycle, cpu.core.ifetch_io_owner_pc);
      // Correlate wrong-path queue residency with actual recovery and commit.
      // These hierarchical probes are test observations, never control inputs.
      for (int q = 0; q < rapt_pkg::CoreConfig.ioq_entries; q++) begin
        if (cpu.core.backend.lsu.u_ioq.ioq_valid[q] && cpu.core.backend.lsu.u_ioq.ioq_ren[q]
            && cpu.core.backend.lsu.u_ioq.ioq_pr1[q] == 0
            && cpu.core.backend.lsu.u_ioq.ioq_pr2[q] == 0)
          $display(
              "SPEC_OBS %0d Q %h %h %h %h %h",
              axi_observe_cycle,
              cpu.core.backend.lsu.u_ioq.ioq_pc[q],
              cpu.core.backend.lsu.u_ioq.ioq_eff_addr[q],
              cpu.core.backend.lsu.u_ioq.ioq_dest[q],
              ioq_observe_generation[q],
              cpu.core.cmu_bcast.rob_head
          );
      end
      if (cpu.core.recovery.redirect_valid)
        $display(
            "SPEC_OBS %0d REDIRECT %h %h",
            axi_observe_cycle,
            {
              cpu.core.backend.rou.uop_pl[cpu.core.recovery.owner].pc, 1'b0
            },
            cpu.core.recovery.target
        );
      if (cpu.core.cmu_bcast.flush_pipe) $display("SPEC_OBS %0d FLUSH", axi_observe_cycle);
      for (int c = 0; c < rapt_pkg::CommitWidth; c++)
      if (cpu.core.backend.rou_cmu.slot[c].valid)
        $display(
            "SPEC_OBS %0d COMMIT %h %h",
            axi_observe_cycle,
            cpu.core.backend.rou_cmu.slot[c].pc,
            cpu.core.backend.rou_cmu.slot[c].npc
        );
`endif
      if (auto_master_out_arvalid && auto_master_out_arready)
        $display(
            "AXI_OBS %0d AR %h %h %h %h %h %h",
            axi_observe_cycle,
            auto_master_out_arid,
            auto_master_out_araddr,
            auto_master_out_arsize,
            auto_master_out_arlen,
            auto_master_out_arburst,
            auto_master_out_arcache
        );
      if (auto_master_out_rvalid && auto_master_out_rready)
        $display(
            "AXI_OBS %0d R %h %h %h",
            axi_observe_cycle,
            auto_master_out_rid,
            auto_master_out_rresp,
            auto_master_out_rlast
        );
      if (auto_master_out_awvalid && auto_master_out_awready)
        $display(
            "AXI_OBS %0d AW %h %h %h %h %h %h",
            axi_observe_cycle,
            auto_master_out_awid,
            auto_master_out_awaddr,
            auto_master_out_awsize,
            auto_master_out_awlen,
            auto_master_out_awburst,
            auto_master_out_awcache
        );
      if (auto_master_out_wvalid && auto_master_out_wready)
        $display(
            "AXI_OBS %0d W %h %h %h",
            axi_observe_cycle,
            auto_master_out_wdata,
            auto_master_out_wstrb,
            auto_master_out_wlast
        );
      if (auto_master_out_bvalid && auto_master_out_bready)
        $display(
            "AXI_OBS %0d B %h %h", axi_observe_cycle, auto_master_out_bid, auto_master_out_bresp
        );
    end
  end
`endif
`endif

  // ---------------------------------------------------------------
  // External IRQ delivery (replaces legacy backdoor pokes).
  // Each posedge clock we call DPI to consume the C++-side pulse vector
  // and drive the rising edge into rapt.ext_irq_i[]. The PLIC edge-detect
  // FSM latches it as pending, exactly as a real device line would.
  // ---------------------------------------------------------------
  logic [31:0] ext_irq_pulse_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      ext_irq_pulse_q <= '0;
    end else begin
      automatic int tmp_irq;
      `RAPT_DPI_C_NPC_GET_EXT_IRQ_VECTOR(tmp_irq);
      ext_irq_pulse_q <= 32'(tmp_irq);
    end
  end

  rapt #(
      .L1dWriteBack(L1dWriteBack)
  ) cpu (
      .writeback_error_o(writeback_error_o),
      .external_write_valid_i,
      .external_write_pending_i,
      .external_write_first_i,
      .external_write_last_i,
      // src/CPU.scala:38:21
      .clock            (clock),
      .io_interrupt     (1'h0),
      .ext_irq_i        (ext_irq_pulse_q[`RAPT_PLIC_NDEV:1]),
      .io_master_awready(auto_master_out_awready),
      .io_master_awvalid(auto_master_out_awvalid),
      .io_master_awid   (auto_master_out_awid),
      .io_master_awaddr (auto_master_out_awaddr),
      .io_master_awlen  (auto_master_out_awlen),
      .io_master_awsize (auto_master_out_awsize),
      .io_master_awburst(auto_master_out_awburst),
      .io_master_awcache(auto_master_out_awcache),
      .io_master_wready (auto_master_out_wready),
      .io_master_wvalid (auto_master_out_wvalid),
      .io_master_wdata  (auto_master_out_wdata),
      .io_master_wstrb  (auto_master_out_wstrb),
      .io_master_wlast  (auto_master_out_wlast),
      .io_master_bready (auto_master_out_bready),
      .io_master_bvalid (auto_master_out_bvalid),
      .io_master_bid    (auto_master_out_bid),
      .io_master_bresp  (auto_master_out_bresp),
      .io_master_arready(auto_master_out_arready),
      .io_master_arvalid(auto_master_out_arvalid),
      .io_master_arid   (auto_master_out_arid),
      .io_master_araddr (auto_master_out_araddr),
      .io_master_arlen  (auto_master_out_arlen),
      .io_master_arsize (auto_master_out_arsize),
      .io_master_arburst(auto_master_out_arburst),
      .io_master_arcache(auto_master_out_arcache),
      .io_master_rready (auto_master_out_rready),
      .io_master_rvalid (auto_master_out_rvalid),
      .io_master_rid    (auto_master_out_rid),
      .io_master_rdata  (auto_master_out_rdata),
      .io_master_rresp  (auto_master_out_rresp),
      .io_master_rlast  (auto_master_out_rlast),


      .jtag_trst_n(jtag_trst_n),
      .jtag_tms   (jtag_tms),
      .jtag_tdi   (jtag_tdi),
      .jtag_tdo   (jtag_tdo),

      .reset(reset)
  );
  rapt_npc_soc #(
      .ReadOutstanding(ReadOutstanding)
  ) perip (
      .clock(clock),
      .arburst(auto_master_out_arburst),
      .arsize(auto_master_out_arsize),
      .arlen(auto_master_out_arlen),
      .arid(auto_master_out_arid),
      .araddr(auto_master_out_araddr),
      .arvalid(auto_master_out_arvalid),
      .out_arready(auto_master_out_arready),
      .out_rid(auto_master_out_rid),
      .out_rlast(auto_master_out_rlast),
      .out_rdata(auto_master_out_rdata),
      .out_rresp(auto_master_out_rresp),
      .out_rvalid(auto_master_out_rvalid),
      .rready(auto_master_out_rready),
      .awburst(auto_master_out_awburst),
      .awsize(auto_master_out_awsize),
      .awlen(auto_master_out_awlen),
      .awid(auto_master_out_awid),
      .awaddr(auto_master_out_awaddr),
      .awvalid(auto_master_out_awvalid),
      .out_awready(auto_master_out_awready),
      .wlast(auto_master_out_wlast),
      .wdata(auto_master_out_wdata),
      .wstrb(auto_master_out_wstrb),
      .wvalid(auto_master_out_wvalid),
      .out_wready(auto_master_out_wready),
      .out_bid(auto_master_out_bid),
      .out_bresp(auto_master_out_bresp),
      .out_bvalid(auto_master_out_bvalid),
      .bready(auto_master_out_bready),
      .reset(reset)
  );
endmodule

module rapt_npc_soc #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit SerializeWrites = 1'b0,
    parameter int ReadOutstanding = 8
) (
    input clock,

    input [1:0] arburst,
    input [2:0] arsize,
    input [7:0] arlen,
    input [3:0] arid,
    input [XLEN-1:0] araddr,
    input arvalid,
    output logic out_arready,

    output logic [3:0] out_rid,
    output logic out_rlast,
    output logic [XLEN-1:0] out_rdata,
    output logic [1:0] out_rresp,
    output logic out_rvalid,
    input rready,

    input [1:0] awburst,
    input [2:0] awsize,
    input [7:0] awlen,
    input [3:0] awid,
    input [XLEN-1:0] awaddr,
    input awvalid,
    output out_awready,

    input wlast,
    input [XLEN-1:0] wdata,
    input [XLEN/8-1:0] wstrb,
    input wvalid,
    output logic out_wready,

    output logic [3:0] out_bid,
    output logic [1:0] out_bresp,
    output logic out_bvalid,
    input bready,

    input reset
);
  localparam int ByteLanes = XLEN / 8;
  localparam int MaxSize = $clog2(ByteLanes);
  localparam int ReadIndexWidth = ReadOutstanding > 1 ? $clog2(ReadOutstanding) : 1;
  localparam int ReadCountWidth = $clog2(ReadOutstanding + 1);
  localparam int MaxWriteOutstanding = 64;
  localparam int BIndexWidth = $clog2(MaxWriteOutstanding);
  localparam logic [1:0] AXIRespOKAY = 2'b00;
  localparam logic [1:0] AXIRespSlverr = 2'b10;
  localparam logic [1:0] AXIRespDecerr = 2'b11;
  localparam logic [1:0] AXIBurstFixed = 2'b00;
  localparam logic [1:0] AXIBurstIncr = 2'b01;
  localparam logic [1:0] AXIBurstWrap = 2'b10;
  localparam logic [XLEN-1:0] AlignMask = ~XLEN'(ByteLanes - 1);
`ifdef RAPT_LARGE_PMEM
  localparam bit LargePmem = 1'b1;
`else
  localparam bit LargePmem = 1'b0;
`endif

  function automatic logic addr_valid(input logic [XLEN-1:0] addr);
    logic [31:0] a = addr[31:0];
    logic        upper_ok;
`ifdef RAPT_RV64
    upper_ok = (addr[XLEN-1:32] == '0) || (&addr[XLEN-1:32]);
`else
    upper_ok = 1'b1;
`endif
    return upper_ok && ((0)  // --- IGNORE ---
    || (a >= 32'h00100000 && a < 32'h00101000)  // sifive,test finisher
    || (a >= 32'h02000000 && a < 32'h020c0000)  // CLINT
    || (a >= 32'h0c000000 && a < 32'h0d000000)  // PLIC
    || (a >= 32'h0f000000 && a < 32'h0f002000)  // SRAM
    || (a >= 32'h10000000 && a < 32'h10012000)  // serial / peripherals
    || (a >= 32'h20000000 && a < 32'h20010000)  // MROM
    || (a >= 32'h30000000 && a < 32'h40000000)  // FLASH / SDHCI PCI ECAM
    || (a >= 32'h40000000 && a < 32'h40000100)  // QEMU SDHCI BAR
    || (a >= 32'h80000000 && (LargePmem || a < 32'h90000000))  // PMEM
    || (!LargePmem && a >= 32'ha0000000 && a < 32'ha2000000)  // legacy SDRAM
    || (a >= 32'h11000000 && a < 32'h12000000)  // LiteX CSR banks
    || (a >= 32'h18000000 && a < 32'h19000000));  // LiteEth buffers
  endfunction

  function automatic logic memory_addr(input logic [XLEN-1:0] addr);
    return addr[31:0] >= 32'h80000000
        && (LargePmem || addr[31:0] < 32'h90000000
            || (addr[31:0] >= 32'ha0000000 && addr[31:0] < 32'ha2000000));
  endfunction

  function automatic logic [XLEN-1:0] burst_first_addr(
      input logic [XLEN-1:0] addr, input logic [7:0] len, input logic [2:0] size,
      input logic [1:0] burst);
    logic [XLEN-1:0] span;
    span = (XLEN'(len) + 1) << size;
    return burst == AXIBurstWrap ? addr & ~(span - 1) : addr;
  endfunction

  function automatic logic [XLEN:0] burst_end_addr(input logic [XLEN-1:0] addr,
                                                   input logic [7:0] len, input logic [2:0] size,
                                                   input logic [1:0] burst);
    logic [XLEN:0] step, base;
    step = (XLEN+1)'(1) << size;
    base = {1'b0, burst_first_addr(addr, len, size, burst)};
    if (burst == AXIBurstWrap) return base + (((XLEN + 1)'(len) + 1) << size) - 1;
    return ({1'b0, addr} & ~(step - 1))
        + ((XLEN+1)'(burst == AXIBurstFixed ? 0 : len) << size) + step - 1;
  endfunction

  function automatic logic [1:0] burst_response(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                                input logic [2:0] size, input logic [1:0] burst);
    logic [XLEN:0] last;
    logic [XLEN-1:0] first;
    if (size > 3'(MaxSize) || burst == 2'b11) return AXIRespSlverr;
    if (burst == AXIBurstFixed && len > 15) return AXIRespSlverr;
    if (burst == AXIBurstWrap && (!(len inside {1, 3, 7, 15})
        || (addr & ((XLEN'(1) << size) - 1)) != 0))
      return AXIRespSlverr;
    first = burst_first_addr(addr, len, size, burst);
    last = burst_end_addr(addr, len, size, burst);
    if (last[XLEN] || first[XLEN-1:12] != last[XLEN-1:12]) return AXIRespSlverr;
    if (!addr_valid(first) || !addr_valid(last[XLEN-1:0])) return AXIRespDecerr;
    return AXIRespOKAY;
  endfunction

  typedef struct packed {
    logic [XLEN-1:0] addr, first_addr, last_addr, wrap_mask;
    logic [7:0] len;
    logic [3:0] id;
    logic [2:0] size;
    logic [1:0] burst, resp;
    logic memory_access;
  } request_t;

  function automatic request_t make_request(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                            input logic [3:0] id, input logic [2:0] size,
                                            input logic [1:0] burst);
    request_t req;
    req.addr = addr;
    req.first_addr = burst_first_addr(addr, len, size, burst);
    req.last_addr = XLEN'(burst_end_addr(addr, len, size, burst));
    req.wrap_mask = ((XLEN'(len) + 1) << size) - 1;
    req.len = len;
    req.id = id;
    req.size = size;
    req.burst = burst;
    req.resp = burst_response(addr, len, size, burst);
    req.memory_access = memory_addr(addr);
    return req;
  endfunction

  function automatic logic [XLEN-1:0] burst_next_addr(input request_t req);
    logic [XLEN-1:0] step, next_addr;
    step = XLEN'(1) << req.size;
    next_addr = (req.addr & ~(step - 1)) + step;
    if (req.burst == AXIBurstFixed) return req.addr;
    if (req.burst == AXIBurstWrap) return (req.addr & ~req.wrap_mask) | (next_addr & req.wrap_mask);
    return next_addr;
  endfunction

  function automatic logic [ByteLanes-1:0] write_lane_mask(input request_t req);
    logic [ByteLanes-1:0] mask;
    int first, limit;
    mask = '0;
    if (req.size > 3'(MaxSize)) return mask;
    first = int'(req.addr & XLEN'(ByteLanes - 1));
    limit = (first & ~((1 << req.size) - 1)) + (1 << req.size);
    for (int i = 0; i < ByteLanes; i++) if (i >= first && i < limit) mask[i] = 1'b1;
    return mask;
  endfunction

  function automatic logic overlaps(input logic [XLEN-1:0] first_a, last_a, first_b, last_b);
    // The host map aliases canonical RV64 addresses onto the low 32 bits.
    return first_a[31:0] > last_a[31:0] || first_b[31:0] > last_b[31:0]
        || (first_a[31:0] <= last_b[31:0] && first_b[31:0] <= last_a[31:0]);
  endfunction

  function automatic logic [31:0] random_delay();
    logic [31:0] delay;
    `RAPT_DPI_C_MEM_RANDOM_DELAY(delay);
    return delay;
  endfunction

  // Queue payloads are meaningful only when their corresponding valid bit is
  // set. Independent IDs can interleave; same-ID dependencies clear on RLAST.
  request_t read_q[ReadOutstanding];
  logic [ReadOutstanding-1:0] read_valid_q, read_last_issued_q;
  logic [ReadOutstanding-1:0] read_older_q[ReadOutstanding];
  longint unsigned read_ready_cycle_q[ReadOutstanding];
  logic [ReadCountWidth-1:0] read_count_q;
  logic [ReadIndexWidth-1:0] read_rr_q, r_slot_q, read_free_slot;
  logic read_has_space, read_hazard, write_hazard;
  logic [XLEN-1:0] ar_first_addr, ar_last_addr, aw_first_addr, aw_last_addr;
  logic r_busy, r_last_q;
  logic [3:0] r_id_q;
  logic [XLEN-1:0] r_data_q;
  logic [1:0] r_resp_q;
  logic r_pop, read_release, accept_ar, accept_aw;
  logic [ReadOutstanding-1:0] read_release_mask;

  request_t aw_q;
  logic aw_busy;
  logic [31:0] w_delay_q;
  logic w_pending;
  logic [XLEN-1:0] w_data_q;
  logic [ByteLanes-1:0] w_strb_q;
  logic w_last_q;
  logic w_accept, write_space, old_write_ready, old_write_finish;

  logic [3:0] b_id_q[MaxWriteOutstanding];
  logic [1:0] b_resp_q[MaxWriteOutstanding];
  logic [XLEN-1:0] b_first_addr_q[MaxWriteOutstanding], b_last_addr_q[MaxWriteOutstanding];
  logic b_memory_q[MaxWriteOutstanding];
  longint unsigned b_ready_cycle_q[MaxWriteOutstanding];
  logic [BIndexWidth-1:0] b_head_q, b_tail_q;
  logic [BIndexWidth:0] b_count_q;
  logic b_pop, serialize_writes;
  int unsigned write_outstanding_q;
  logic [31:0] read_latency_q, write_latency_q;
  longint unsigned cycle_q;

  localparam logic [19:0] AXITimeout = 20'hf_ffff;
  logic [19:0] r_timeout_cnt, w_timeout_cnt;

  assign out_rvalid = !reset && r_busy;
  assign out_rid = r_id_q;
  assign out_rdata = r_data_q;
  assign out_rresp = r_resp_q;
  assign out_rlast = r_last_q;
  assign r_pop = out_rvalid && rready;
  assign read_release = r_pop && r_last_q;
  assign read_release_mask = read_release ? ReadOutstanding'(1) << r_slot_q : '0;

  assign out_bvalid = !reset && b_count_q != 0 && cycle_q >= b_ready_cycle_q[b_head_q];
  assign out_bid = b_id_q[b_head_q];
  assign out_bresp = b_resp_q[b_head_q];
  assign b_pop = out_bvalid && bready;
  assign write_space = int'(b_count_q) < write_outstanding_q || b_pop;
  assign old_write_ready = aw_busy && w_delay_q == 0 && write_space;
  assign old_write_finish = old_write_ready && (w_pending || wvalid)
      && ((w_pending ? w_last_q : wlast) || aw_q.len == 0);
  // One elastic W beat permits W-before-AW without applying an unidentified
  // device write. A consumed buffered beat may be replaced on the same edge.
  assign out_wready = !reset && (!w_pending || old_write_ready);
  assign w_accept = wvalid && out_wready;

  always_comb begin
    ar_first_addr = burst_first_addr(araddr, arlen, arsize, arburst);
    ar_last_addr = XLEN'(burst_end_addr(araddr, arlen, arsize, arburst));
    aw_first_addr = burst_first_addr(awaddr, awlen, awsize, awburst);
    aw_last_addr = XLEN'(burst_end_addr(awaddr, awlen, awsize, awburst));
    read_has_space = 1'b0;
    read_free_slot = '0;
    for (int i = 0; i < ReadOutstanding; i++) begin
      if (!read_has_space && (!read_valid_q[i] || read_release_mask[i])) begin
        read_has_space = 1'b1;
        read_free_slot = ReadIndexWidth'(i);
      end
    end
    read_hazard = 1'b0;
    write_hazard = 1'b0;
    // Devices are barriers. RAM hazards cover the complete burst footprint.
    // Scan only on offered requests to keep idle simulator evaluation cheap.
    if (arvalid || awvalid) begin
      for (int i = 0; i < ReadOutstanding; i++) begin
        if (read_valid_q[i] && !read_release_mask[i]) begin
          read_hazard |= !memory_addr(araddr) || !read_q[i].memory_access;
          write_hazard |= !memory_addr(
              awaddr
          ) || !read_q[i].memory_access || overlaps(
              aw_first_addr, aw_last_addr, read_q[i].first_addr, read_q[i].last_addr
          );
        end
      end
      if (aw_busy) begin
        read_hazard |= !memory_addr(
            araddr
        ) || !aw_q.memory_access || overlaps(
            ar_first_addr, ar_last_addr, aw_q.first_addr, aw_q.last_addr
        );
        // Address lookahead must not admit a device boundary before the
        // finishing write has also retired its B response.
        write_hazard |= !memory_addr(awaddr) || !aw_q.memory_access;
      end
      for (int i = 0; i < int'(b_count_q); i++) begin
        if (!(i == 0 && b_pop)) begin
          read_hazard |= !memory_addr(
              araddr
          ) || !b_memory_q[BIndexWidth'(b_head_q+i)] || overlaps(
              ar_first_addr,
              ar_last_addr,
              b_first_addr_q[BIndexWidth'(b_head_q+i)],
              b_last_addr_q[BIndexWidth'(b_head_q+i)]
          );
          write_hazard |= !memory_addr(awaddr) || !b_memory_q[BIndexWidth'(b_head_q+i)];
        end
      end
      // Give a concurrent conflicting write priority, matching the core bus.
      if (awvalid)
        read_hazard |= !memory_addr(
            araddr
        ) || !memory_addr(
            awaddr
        ) || overlaps(
            ar_first_addr, ar_last_addr, aw_first_addr, aw_last_addr
        );
    end
  end
  assign out_arready = !reset && read_has_space && !read_hazard;
  assign out_awready = !reset && !write_hazard
      && (!aw_busy || (!serialize_writes && old_write_finish))
      && (!serialize_writes || b_count_q == 0)
      && (write_outstanding_q == 1 || write_space);
  assign accept_ar = arvalid && out_arready;
  assign accept_aw = awvalid && out_awready;

`ifndef SYNTHESIS
  import "DPI-C" function int unsigned npc_mem_serialize_writes();
`endif
  initial begin
    if (ReadOutstanding < 1 || ReadOutstanding > 16)
      $fatal(1, "NPC_SOC: read capacity must be between 1 and 16");
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      automatic int unsigned read_latency, write_latency, write_capacity;
      `RAPT_DPI_C_MEM_READ_LATENCY(read_latency);
      `RAPT_DPI_C_MEM_WRITE_LATENCY(write_latency);
      `RAPT_DPI_C_MEM_WRITE_OUTSTANDING(write_capacity);
      if (write_capacity < 1 || write_capacity > MaxWriteOutstanding)
        $fatal(1, "NPC_SOC: invalid write response capacity");
      read_q <= '{default: '0};
      read_valid_q <= '0;
      read_last_issued_q <= '0;
      read_older_q <= '{default: '0};
      read_ready_cycle_q <= '{default: '0};
      read_count_q <= '0;
      read_rr_q <= '0;
      r_slot_q <= '0;
      r_busy <= 1'b0;
      r_id_q <= '0;
      r_data_q <= '0;
      r_resp_q <= AXIRespOKAY;
      r_last_q <= 1'b0;
      aw_q <= '0;
      aw_busy <= 1'b0;
      w_delay_q <= '0;
      w_pending <= 1'b0;
      w_data_q <= '0;
      w_strb_q <= '0;
      w_last_q <= 1'b0;
      b_id_q <= '{default: '0};
      b_resp_q <= '{default: AXIRespOKAY};
      b_first_addr_q <= '{default: '0};
      b_last_addr_q <= '{default: '0};
      b_memory_q <= '{default: '0};
      b_ready_cycle_q <= '{default: '0};
      b_head_q <= '0;
      b_tail_q <= '0;
      b_count_q <= '0;
      cycle_q <= '0;
      read_latency_q <= read_latency;
      write_latency_q <= write_latency;
      write_outstanding_q <= write_capacity;
`ifndef SYNTHESIS
      serialize_writes <= SerializeWrites || npc_mem_serialize_writes() != 0;
`else
      serialize_writes <= SerializeWrites;
`endif
      r_timeout_cnt <= '0;
      w_timeout_cnt <= '0;
    end else begin
      automatic request_t incoming = '0;
      automatic logic [ReadOutstanding-1:0] incoming_older = '0;
      automatic logic [31:0] incoming_delay = 0;
      automatic logic [31:0] next_read_delay = 0;
      automatic logic push_b = 1'b0;
      cycle_q <= cycle_q + 1;

      if (r_pop && !r_last_q) begin
        next_read_delay = random_delay();
        read_ready_cycle_q[r_slot_q] <= cycle_q + 64'(next_read_delay);
      end
      if (read_release) begin
        read_valid_q[r_slot_q] <= 1'b0;
        read_last_issued_q[r_slot_q] <= 1'b0;
        for (int i = 0; i < ReadOutstanding; i++) read_older_q[i][r_slot_q] <= 1'b0;
      end
      if (accept_ar) begin
        incoming = make_request(araddr, arlen, arid, arsize, arburst);
        incoming_delay = read_latency_q + random_delay();
        for (int i = 0; i < ReadOutstanding; i++)
        incoming_older[i] = read_valid_q[i] && !read_release_mask[i] && read_q[i].id == arid;
        read_q[read_free_slot] <= incoming;
        read_valid_q[read_free_slot] <= 1'b1;
        read_last_issued_q[read_free_slot] <= 1'b0;
        read_older_q[read_free_slot] <= incoming_older;
        read_ready_cycle_q[read_free_slot] <= cycle_q + 64'(incoming_delay);
      end
      case ({
        accept_ar, read_release
      })
        2'b10: read_count_q <= read_count_q + 1'b1;
        2'b01: read_count_q <= read_count_q - 1'b1;
        default: ;
      endcase

      // The single output register owns a beat through all R backpressure.
      // A new zero-latency AR may feed that register at its acceptance edge:
      // no extra queue cycle, and never a response before the AR handshake.
      if ((read_valid_q != '0 || accept_ar) && (!r_busy || r_pop)) begin
        automatic logic found = 1'b0;
        r_busy <= 1'b0;
        for (int offset = 0; offset < ReadOutstanding; offset++) begin
          automatic int index = int'(read_rr_q) + offset;
          automatic logic eligible;
          if (index >= ReadOutstanding) index -= ReadOutstanding;
          eligible = read_valid_q[index] && !read_last_issued_q[index]
              && (read_older_q[index] & ~read_release_mask) == '0
              && cycle_q >= read_ready_cycle_q[index];
          if (r_pop && !r_last_q && index == int'(r_slot_q)) eligible &= next_read_delay == 0;
          if (accept_ar && index == int'(read_free_slot)) begin
            eligible = incoming_delay == 0 && incoming_older == '0;
          end
          if (!found && eligible) begin
            automatic request_t selected = accept_ar && index == int'(read_free_slot)
                ? incoming : read_q[index];
            automatic logic [XLEN-1:0] data = '0;
            if (selected.resp == AXIRespOKAY)
              `RAPT_DPI_C_PMEM_READ(selected.addr, {5'b0, selected.size}, data);
            r_busy <= 1'b1;
            r_id_q <= selected.id;
            r_data_q <= data;
            r_resp_q <= selected.resp;
            r_last_q <= selected.len == 0;
            r_slot_q <= ReadIndexWidth'(index);
            read_q[index].addr <= burst_next_addr(selected);
            read_q[index].len <= selected.len == 0 ? 0 : selected.len - 1'b1;
            read_last_issued_q[index] <= selected.len == 0;
            read_rr_q <= index == ReadOutstanding - 1 ? '0 : ReadIndexWidth'(index + 1);
            found = 1'b1;
          end
        end
      end

      if (w_delay_q != 0) w_delay_q <= w_delay_q - 1'b1;
      if (w_accept) begin
        w_data_q <= wdata;
        w_strb_q <= wstrb;
        w_last_q <= wlast;
        w_pending <= 1'b1;
      end
      if (aw_busy || accept_aw) begin
        automatic request_t current = aw_q;
        automatic logic [31:0] delay = w_delay_q;
        if (accept_aw) begin
          automatic request_t next_aw = make_request(awaddr, awlen, awid, awsize, awburst);
          automatic logic [31:0] next_delay = random_delay();
          aw_q <= next_aw;
          aw_busy <= 1'b1;
          w_delay_q <= next_delay;
          if (!aw_busy) begin
            current = next_aw;
            delay = next_delay;
          end
        end
        if ((aw_busy || accept_aw) && (w_pending || w_accept) && delay == 0 && write_space) begin
          automatic logic [XLEN-1:0] data = w_pending ? w_data_q : wdata;
          automatic logic [ByteLanes-1:0] strb = w_pending ? w_strb_q : wstrb;
          automatic logic last = w_pending ? w_last_q : wlast;
          automatic logic [1:0] resp = current.resp;
          if (resp == AXIRespOKAY && ((strb & ~write_lane_mask(
                  current
              )) != 0 || last != (current.len == 0)))
            resp = AXIRespSlverr;
          if (resp == AXIRespOKAY && strb != 0)
            `RAPT_DPI_C_PMEM_WRITE(current.addr & AlignMask, data, 8'(strb));
          if (!w_pending || !w_accept) w_pending <= 1'b0;
          if (last || current.len == 0) begin
            b_id_q[b_tail_q] <= current.id;
            b_resp_q[b_tail_q] <= resp;
            b_first_addr_q[b_tail_q] <= current.first_addr;
            b_last_addr_q[b_tail_q] <= current.last_addr;
            b_memory_q[b_tail_q] <= current.memory_access;
            b_ready_cycle_q[b_tail_q] <= cycle_q + 64'(write_latency_q)
                + 64'(random_delay()) + 1;
            b_tail_q <= b_tail_q + 1'b1;
            push_b = 1'b1;
            if (!aw_busy || !accept_aw) aw_busy <= 1'b0;
          end else begin
            aw_q.addr <= burst_next_addr(current);
            aw_q.len <= current.len - 1'b1;
            aw_q.resp <= resp;
            w_delay_q <= random_delay();
          end
        end
      end
      if (b_pop) b_head_q <= b_head_q + 1'b1;
      case ({
        push_b, b_pop
      })
        2'b10: b_count_q <= b_count_q + 1'b1;
        2'b01: b_count_q <= b_count_q - 1'b1;
        default: ;
      endcase

      // Watchdogs diagnose a stuck manager; they never cancel AXI responses.
      if ((read_valid_q != '0 || r_busy) && !r_pop) begin
        if (r_timeout_cnt != AXITimeout) r_timeout_cnt <= r_timeout_cnt + 1'b1;
        if (r_timeout_cnt == AXITimeout - 1'b1)
          $display("NPC_SOC: [WARNING] AXI read stalled (rid=%0d)", r_id_q);
      end else r_timeout_cnt <= '0;
      if ((aw_busy || w_pending || b_count_q != 0) && !(wvalid && out_wready) && !b_pop) begin
        if (w_timeout_cnt != AXITimeout) w_timeout_cnt <= w_timeout_cnt + 1'b1;
        if (w_timeout_cnt == AXITimeout - 1'b1) $display("NPC_SOC: [WARNING] AXI write stalled");
      end else w_timeout_cnt <= '0;
    end
  end
endmodule
