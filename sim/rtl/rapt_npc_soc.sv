`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_dpi_c.svh"

// verilator lint_off UNDRIVEN
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off DECLFILENAME
// verilator lint_off UNUSEDSIGNAL
module raptSoC #(
    parameter int XLEN = `RAPT_XLEN
) (
    input  clock,
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
`ifdef RAPT_LRSC_OBSERVE
`ifndef SYNTHESIS
  `include "rapt_lrsc_observe.svh"
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
      if (cpu.core.l1i_cache.slow_active)
        $display(
            "IFETCH_OBS %0d STATE %h %h %h %h %h %h",
            axi_observe_cycle,
            cpu.core.ifetch_io_owner_pc,
            cpu.core.l1i_cache.u_word_fetch.state,
            cpu.core.l1i_cache.slow_read_pbmt,
            cpu.core.ifetch_io_authorized,
            cpu.core.l1i_cache.slow_cancel,
            cpu.core.l1i_cache.u_word_fetch.io_owned
        );
      if (cpu.core.ifetch_io_start)
        $display("IFETCH_OBS %0d START %h", axi_observe_cycle, cpu.core.ifetch_io_owner_pc);
      // Correlate wrong-path queue residency with actual recovery and commit.
      // These hierarchical probes are test observations, never control inputs.
      for (int q = 0; q < rapt_pkg::CoreConfig.ioq_entries; q++) begin
        if (cpu.core.lsu.u_ioq.ioq_valid[q] && cpu.core.lsu.u_ioq.ioq_ren[q]
            && cpu.core.lsu.u_ioq.ioq_pr1[q] == 0
            && cpu.core.lsu.u_ioq.ioq_pr2[q] == 0)
          $display(
              "SPEC_OBS %0d Q %h %h %h %h %h",
              axi_observe_cycle,
              cpu.core.lsu.u_ioq.ioq_pc[q],
              cpu.core.lsu.u_ioq.ioq_eff_addr[q],
              cpu.core.lsu.u_ioq.ioq_dest[q],
              cpu.core.lsu.u_ioq.ioq_generation[q],
              cpu.core.cmu_bcast.rob_head
          );
      end
      if (cpu.core.recovery.redirect_valid)
        $display(
            "SPEC_OBS %0d REDIRECT %h %h",
            axi_observe_cycle,
            cpu.core.rou.uop_pl[cpu.core.recovery.owner].pc,
            cpu.core.recovery.target
        );
      if (cpu.core.cmu_bcast.flush_pipe) $display("SPEC_OBS %0d FLUSH", axi_observe_cycle);
      for (int c = 0; c < rapt_pkg::CommitWidth; c++)
      if (cpu.core.rou_cmu.slot[c].valid)
        $display(
            "SPEC_OBS %0d COMMIT %h %h",
            axi_observe_cycle,
            cpu.core.rou_cmu.slot[c].pc,
            cpu.core.rou_cmu.slot[c].npc
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

  rapt cpu (
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
  rapt_npc_soc perip (
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
    parameter int XLEN = `RAPT_XLEN
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
  // AXI4 response encoding
  localparam logic [1:0] AXIRespOKAY = 2'b00;
  localparam logic [1:0] AXIRespDecerr = 2'b11;
  // AXI4 burst type encoding (FIXED/INCR exercised; WRAP folded into INCR by
  // burst_next_addr below — no current master uses WRAP).
  localparam logic [1:0] AXIBurstFixed = 2'b00;

  localparam logic [XLEN-1:0] AlignMask = ~XLEN'(int'(XLEN / 8 - 1));

  // -------------------------------------------------------------------------
  // Address range validation: check if address falls within any known region.
  // In RV64 mode with `-mcmodel=medany`, code linked at 0x80000000 is loaded
  // so that `lui`-materialised addresses are sign-extended (e.g. a5 = 0xffffffff80000000).
  // The physical memory map is 32-bit, so compare the low 32 bits only and
  // require the upper bits to be either all-zero or all-one (canonical sign-extension).
  // -------------------------------------------------------------------------
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
    || (a >= 32'h30000000 && a < 32'h40000000)  // FLASH
    || (a >= 32'h80000000 && a < 32'h90000000)  // PMEM (main memory, 256 MiB)
    || (a >= 32'ha0000000 && a < 32'ha2000000)  // SDRAM
    || (a >= 32'hf0001000 && a < 32'hf0001100)  // LiteX UART (egos HARDWARE)
    || (a >= 32'hf0008000 && a < 32'hf0008100)  // LiteX SPI SD-card controller
    || (a >= 32'hf0010000 && a < 32'hf0020000));  // CLINT alias (egos HARDWARE)
  endfunction

  // INCR/FIXED address step. WRAP not exercised by current masters; emulated as INCR.
  function automatic logic [XLEN-1:0] burst_next_addr(input logic [XLEN-1:0] cur,
                                                      input logic [2:0] sz, input logic [1:0] bt);
    logic [XLEN-1:0] step;
    step = (XLEN'(1) << sz);
    if (bt == AXIBurstFixed) return cur;
    return cur + step;
  endfunction

  // -------------------------------------------------------------------------
  // Read pipeline (skid buffer): allows accepting a new AR in the same cycle
  // that the current R beat is being consumed. Average throughput ≈ 1
  // transaction / cycle instead of the previous 2 cycles/transaction.
  // For multi-beat bursts (arlen > 0), beats stream out one per cycle while
  // rready is held; new ARs queue once the burst's last beat handshakes.
  // -------------------------------------------------------------------------
  logic            r_busy;  // a beat is currently presented on R channel
  logic [     3:0] r_id_q;
  logic [XLEN-1:0] r_data_q;
  logic [     1:0] r_resp_q;
  logic            r_last_q;
  logic [     7:0] r_beats_left;  // beats remaining AFTER current (counts down)
  logic [XLEN-1:0] r_next_addr;  // address for the NEXT beat
  logic [     2:0] r_size_q;
  logic [     1:0] r_burst_q;
  logic [    31:0] r_delay_q;

  // -------------------------------------------------------------------------
  // Write pipeline. AW captured into a single-entry holding register; W beats
  // stream in and fire DPI writes; on wlast, a single-entry B response is
  // posted. A new AW can be accepted while B is still draining.
  // -------------------------------------------------------------------------
  logic            aw_busy;  // AW captured, W stream in progress
  logic [     3:0] aw_id_q;
  logic [XLEN-1:0] aw_addr_q;  // current beat address
  logic [     2:0] aw_size_q;
  logic [     1:0] aw_burst_q;
  logic [     7:0] aw_beats_left;
  logic [     1:0] aw_resp_acc;  // accumulated B response (sticky DECERR)

  logic            b_busy;  // B response pending
  logic [     3:0] b_id_q;
  logic [     1:0] b_resp_q;
  logic [    31:0] w_delay_q;
  logic [    31:0] b_delay_q;

  // Combinational AR-handshake helpers (skid: free when current beat exits)
  logic r_slot_free, aw_slot_free;
  assign r_slot_free  = !r_busy || (out_rvalid && rready && r_last_q);
  assign aw_slot_free = !aw_busy;

  assign out_arready  = r_slot_free;
  assign out_rvalid   = r_busy && (r_delay_q == 0);
  assign out_rdata    = r_data_q;
  assign out_rid      = r_id_q;
  assign out_rresp    = r_resp_q;
  assign out_rlast    = r_last_q;

  assign out_awready  = aw_slot_free;
  // Accept W beats whenever AW has been captured (write-data-before-AW is
  // tolerated by waiting: out_wready stays low until aw_busy). We also gate
  // on `!b_busy` so the final beat never races a still-occupied B slot —
  // this is conservative (stalls mid-burst too when B is busy) but avoids
  // a combinational dependence on the master-driven `wlast`, which would
  // otherwise close a loop through the AXI interface.
  assign out_wready   = aw_busy && !b_busy && (w_delay_q == 0);
  assign out_bvalid   = b_busy && (b_delay_q == 0);
  assign out_bid      = b_id_q;
  assign out_bresp    = b_resp_q;

  // -------------------------------------------------------------------------
  // Timeout watchdog: catch logic bugs that stall a channel indefinitely.
  // -------------------------------------------------------------------------
  localparam logic [19:0] AXITimeout = 20'hf_ffff;  // ~1M cycles
  logic [19:0] r_timeout_cnt;
  logic [19:0] w_timeout_cnt;

  // Per-cycle "next-state" helpers for the read pipeline (combinational).
  // These let us simultaneously consume the current beat AND accept a new AR.
  logic accept_ar;
  assign accept_ar = arvalid && r_slot_free;

  function automatic logic [31:0] random_delay();
    logic [31:0] delay;
    `RAPT_DPI_C_MEM_RANDOM_DELAY(delay);
    return delay;
  endfunction

  // ==========================================================================
  // Sequential update — single always_ff drives both channels.
  // ==========================================================================
  always_ff @(posedge clock) begin
    if (reset) begin
      r_busy        <= 1'b0;
      r_id_q        <= '0;
      r_data_q      <= '0;
      r_resp_q      <= AXIRespOKAY;
      r_last_q      <= 1'b0;
      r_beats_left  <= '0;
      r_next_addr   <= '0;
      r_size_q      <= '0;
      r_burst_q     <= '0;
      r_delay_q     <= '0;

      aw_busy       <= 1'b0;
      aw_id_q       <= '0;
      aw_addr_q     <= '0;
      aw_size_q     <= '0;
      aw_burst_q    <= '0;
      aw_beats_left <= '0;
      aw_resp_acc   <= AXIRespOKAY;

      b_busy        <= 1'b0;
      b_id_q        <= '0;
      b_resp_q      <= AXIRespOKAY;
      w_delay_q     <= '0;
      b_delay_q     <= '0;

      r_timeout_cnt <= '0;
      w_timeout_cnt <= '0;
    end else begin
      // -------------------- READ CHANNEL --------------------
      // (1) Consume current beat if handshake fires.
      if (r_delay_q != 0) begin
        r_delay_q <= r_delay_q - 1;
      end
      if (out_rvalid && rready) begin
        if (r_last_q) begin
          // Burst complete; slot becomes free this cycle.
          r_busy <= 1'b0;
        end else begin
          // Advance to next beat in burst (same cycle issuance of DPI read).
          automatic logic [XLEN-1:0] na = r_next_addr;
          automatic logic [XLEN-1:0] tmp;
          if (addr_valid(na)) begin
            `RAPT_DPI_C_PMEM_READ(na, {5'b0, r_size_q}, tmp);
            r_data_q <= tmp;
            r_resp_q <= AXIRespOKAY;
          end else begin
            tmp = '0;
            r_data_q <= '0;
            r_resp_q <= AXIRespDecerr;
          end
          r_next_addr  <= burst_next_addr(na, r_size_q, r_burst_q);
          r_beats_left <= r_beats_left - 8'd1;
          r_last_q     <= (r_beats_left == 8'd1);
          r_delay_q    <= random_delay();
        end
      end

      // (2) Accept new AR if slot is free. Note: when r_last_q + rready fires,
      //     r_slot_free is high and we can overwrite r_busy in the SAME cycle.
      if (accept_ar) begin
        automatic logic [XLEN-1:0] tmp;
        automatic logic            v;
        v = addr_valid(araddr);
        if (v) begin
          `RAPT_DPI_C_PMEM_READ(araddr, {5'b0, arsize}, tmp);
        end else begin
          tmp = '0;
          $display("NPC_SOC: AXI read decode error addr=%0h, arid=%0d", araddr, arid);
        end
        r_busy       <= 1'b1;
        r_id_q       <= arid;
        r_data_q     <= tmp;
        // Speculative consumers own cancellation; the target must report an
        // actual decode error rather than turn an invalid read into data.
        r_resp_q     <= v ? AXIRespOKAY : AXIRespDecerr;
        r_size_q     <= arsize;
        r_burst_q    <= arburst;
        r_beats_left <= arlen;  // beats remaining after first
        r_last_q     <= (arlen == 8'd0);
        r_next_addr  <= burst_next_addr(araddr, arsize, arburst);
        r_delay_q    <= random_delay();
      end

      // -------------------- WRITE CHANNEL --------------------
      if (w_delay_q != 0) begin
        w_delay_q <= w_delay_q - 1;
      end
      if (b_delay_q != 0) begin
        b_delay_q <= b_delay_q - 1;
      end
      // (1) Accept new AW if slot is free.
      if (awvalid && aw_slot_free) begin
        aw_busy       <= 1'b1;
        aw_id_q       <= awid;
        aw_addr_q     <= awaddr;
        aw_size_q     <= awsize;
        aw_burst_q    <= awburst;
        aw_beats_left <= awlen;  // beats after first
        aw_resp_acc   <= addr_valid(awaddr) ? AXIRespOKAY : AXIRespDecerr;
        w_delay_q     <= random_delay();
        if (!addr_valid(awaddr)) begin
          $display("NPC_SOC: AXI write decode error addr=%0h, awid=%0d", awaddr, awid);
        end
      end

      // (2) Consume W beat: gated by the actual wready handshake (which also
      //     stalls a final beat against a busy B slot, see out_wready above).
      if (wvalid && out_wready) begin
        // Deliver one accepted AXI beat with its complete byte enables.
        // Device models must see a register command once, after all its
        // selected bytes are available; RAM applies the same byte mask.
        if (aw_resp_acc == AXIRespOKAY)
          `RAPT_DPI_C_PMEM_WRITE(aw_addr_q & AlignMask, wdata, 8'(wstrb));
        if (wlast) begin
          // out_wready gating guarantees b_busy is false here, so the post
          // always succeeds.
          b_busy   <= 1'b1;
          b_id_q   <= aw_id_q;
          b_resp_q <= aw_resp_acc;
          aw_busy  <= 1'b0;  // free AW slot for next transaction
          b_delay_q <= random_delay();
        end else begin
          aw_addr_q <= burst_next_addr(aw_addr_q, aw_size_q, aw_burst_q);
          aw_beats_left <= aw_beats_left - 8'd1;
          w_delay_q <= random_delay();
        end
      end

      // (3) Drain B on handshake.
      if (out_bvalid && bready) begin
        b_busy <= 1'b0;
      end

      // Diagnostic only: AXI has no response cancellation on timeout.
      // Keep all accepted transaction state and stalled payloads intact.
      // Count cycles without progress, saturating to report once per stall.
      if (r_busy && !(out_rvalid && rready)) begin
        if (r_timeout_cnt != AXITimeout) r_timeout_cnt <= r_timeout_cnt + 1'b1;
        if (r_timeout_cnt == AXITimeout - 1'b1)
          $display("NPC_SOC: [WARNING] AXI read stalled (rid=%0d)", r_id_q);
      end else begin
        r_timeout_cnt <= '0;
      end
      if ((aw_busy || b_busy) && !(out_wready && wvalid) && !(out_bvalid && bready)) begin
        if (w_timeout_cnt != AXITimeout) w_timeout_cnt <= w_timeout_cnt + 1'b1;
        if (w_timeout_cnt == AXITimeout - 1'b1)
          $display("NPC_SOC: [WARNING] AXI write stalled (id=%0d)", aw_busy ? aw_id_q : b_id_q);
      end else begin
        w_timeout_cnt <= '0;
      end
    end
  end
endmodule

// verilator lint_on PINCONNECTEMPTY
// verilator lint_on UNDRIVEN
// verilator lint_on DECLFILENAME
// verilator lint_on UNUSEDSIGNAL
