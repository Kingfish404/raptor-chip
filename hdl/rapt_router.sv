`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module rapt_router #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,
    input reset,

    axi4_if.slave core_axi,
    axi4_if.master offchip_axi,
    clint_bus_if.master clint_bus,
    plic_bus_if.master plic_bus
);
  typedef enum logic [1:0] {
    INT_NONE  = 2'd0,
    INT_CLINT,
    INT_PLIC
  } int_slave_t;

  localparam int IntByteOffW = $clog2(XLEN / 8);

  function automatic logic [XLEN-1:0] internal_rdata_to_axi(input logic [XLEN-1:0] data,
                                                            input logic [IntByteOffW-1:0] byte_off);
    logic [$clog2(XLEN)-1:0] shamt;
    begin
      shamt = {byte_off, 3'b000};
      internal_rdata_to_axi = data << shamt;
    end
  endfunction

  function automatic logic [XLEN-1:0] axi_wdata_to_internal(input logic [XLEN-1:0] data,
                                                            input logic [IntByteOffW-1:0] byte_off);
    logic [$clog2(XLEN)-1:0] shamt;
    begin
      shamt = {byte_off, 3'b000};
      axi_wdata_to_internal = data >> shamt;
    end
  endfunction

  function automatic int_slave_t addr_decode(input logic [XLEN-1:0] a);
    if ((a >= `RAPT_CLINT_BASE) && (a < (`RAPT_CLINT_BASE + XLEN'(32'h000c0000)))) begin
      addr_decode = INT_CLINT;
    end else if ((a >= `RAPT_PLIC_BASE) && (a < `RAPT_PLIC_BASE + `RAPT_PLIC_SIZE)) begin
      addr_decode = INT_PLIC;
    end else begin
      addr_decode = INT_NONE;
    end
  endfunction

  // Live read addresses fan out to all internal slaves (combinational reads).
  assign clint_bus.araddr = core_axi.araddr;
  assign plic_bus.araddr  = core_axi.araddr;

  // ----- Read channel router -----
  // Multi-outstanding capable. Two response sources are merged onto the
  // R channel back to the core:
  //
  //   1. Offchip path: AR is forwarded combinationally to `offchip_axi`
  //      (no FSM gating). The interconnect / memory may have any number
  //      of in-flight reads -- AXI4 only requires same-ID responses to
  //      come back in order, which the slave/interconnect already
  //      guarantees. The router never reorders offchip beats.
  //
  //   2. Internal path (CLINT / PLIC): AR completes in 1 cycle; the
  //      response (id + data) is captured into a small FIFO. The
  //      cluster-internal slaves are combinational read, so we sample
  //      them in the same cycle as the AR handshake.
  //
  // R-channel arbitration: AXI4 forbids beat-interleaving WITHIN a
  // burst. We therefore lock the channel to the offchip stream for the
  // duration of a multi-beat burst. Single-beat bursts (the common
  // case) impose no lock -- when an offchip burst is not in progress,
  // the FIFO drains first (to keep CLINT / PLIC latency low and avoid
  // head-of-line blocking against an offchip burst that is still
  // waiting for data). Beat-level interleaving across IDs is therefore
  // never produced; whole bursts may complete out of order across
  // different IDs (which AXI4 explicitly permits).
  //
  // Forward-compatibility: removing the single-outstanding restriction
  // means the upstream `axi4_if` (rapt_bus) can be extended to issue
  // L1I and L1D ARs concurrently with no router change. The internal
  // FIFO depth (`INT_RESP_DEPTH`, default 2) sets how many internal
  // reads may queue while an offchip burst is in flight; raise it if
  // additional internal slaves are added.
  // -------------------------------------------------------------------
  localparam int INT_RESP_DEPTH = 2;
  localparam int INT_RESP_IDX_W = $clog2(INT_RESP_DEPTH);
  localparam int INT_RESP_CNT_W = $clog2(INT_RESP_DEPTH + 1);

  typedef struct packed {
    logic [3:0]      id;
    logic [XLEN-1:0] data;
  } int_resp_t;

  int_resp_t int_resp_q[INT_RESP_DEPTH];
  logic [INT_RESP_IDX_W-1:0] int_resp_head, int_resp_tail;
  logic [INT_RESP_CNT_W-1:0] int_resp_count;
  logic int_resp_empty, int_resp_full;
  assign int_resp_empty = (int_resp_count == '0);
  assign int_resp_full  = (int_resp_count == INT_RESP_CNT_W'(INT_RESP_DEPTH));

  // Tracks whether we're partway through forwarding an offchip burst.
  // Set when an offchip beat handshakes that is NOT rlast; cleared on
  // the rlast handshake. Used to lock the R-mux to offchip mid-burst.
  logic offchip_in_burst;

  int_slave_t            ar_int;
  logic                  ar_is_int;
  assign ar_int = addr_decode(core_axi.araddr);
  assign ar_is_int = (ar_int != INT_NONE);

  // ----- AR forwarding -----
  assign offchip_axi.arvalid = core_axi.arvalid && !ar_is_int;
  assign offchip_axi.arburst = core_axi.arburst;
  assign offchip_axi.arsize  = core_axi.arsize;
  assign offchip_axi.arlen   = core_axi.arlen;
  assign offchip_axi.arid    = core_axi.arid;
  assign offchip_axi.araddr  = core_axi.araddr;

  // Internal AR completes immediately when there is FIFO space.
  // Offchip AR completes when downstream is ready.
  assign core_axi.arready = ar_is_int ? !int_resp_full : offchip_axi.arready;

  // PLIC ar_commit is a 1-cycle pulse on the internal AR handshake
  // (used by PLIC to clear claim-side state). Matches the original
  // semantics -- fired exactly once per accepted internal AR.
  assign plic_bus.ar_commit = core_axi.arvalid && core_axi.arready
                              && (ar_int == INT_PLIC);

  // ----- R-channel arbiter -----
  // Drain the internal FIFO whenever (a) it has data AND (b) we are
  // not in the middle of an offchip burst. Offchip burst lock-in
  // prevents AXI4-illegal beat interleaving within one burst.
  logic drain_int;
  assign drain_int = !int_resp_empty && !offchip_in_burst;

  assign core_axi.rvalid = drain_int || offchip_axi.rvalid;
  assign core_axi.rdata  = drain_int ? int_resp_q[int_resp_head].data : offchip_axi.rdata;
  assign core_axi.rid    = drain_int ? int_resp_q[int_resp_head].id   : offchip_axi.rid;
  assign core_axi.rlast  = drain_int ? 1'b1                            : offchip_axi.rlast;
  assign core_axi.rresp  = drain_int ? 2'b00                           : offchip_axi.rresp;

  // Backpressure to offchip: only assert rready downstream when we are
  // actually forwarding the offchip beat (i.e. not draining the FIFO).
  assign offchip_axi.rready = !drain_int && core_axi.rready;

  // ----- FIFO + burst-tracking sequential -----
  logic push_int_resp;
  logic pop_int_resp;
  logic offchip_beat;

  assign push_int_resp = core_axi.arvalid && core_axi.arready && ar_is_int;
  assign pop_int_resp  = drain_int && core_axi.rready;
  assign offchip_beat  = offchip_axi.rvalid && offchip_axi.rready;

  always_ff @(posedge clock) begin
    if (reset) begin
      int_resp_head    <= '0;
      int_resp_tail    <= '0;
      int_resp_count   <= '0;
      offchip_in_burst <= 1'b0;
      // int_resp_q payload stays unreset: drain_int (count != 0) gates
      // every read of int_resp_q[int_resp_head], and a push always
      // rewrites the tail entry together with the count increment.
    end else begin
      // Push: capture the internal slave's combinational read result
      // in the same cycle as the AR handshake.
      if (push_int_resp) begin
        int_resp_q[int_resp_tail].id <= core_axi.arid;
        unique case (ar_int)
          INT_CLINT:
          int_resp_q[int_resp_tail].data <=
              internal_rdata_to_axi(clint_bus.rdata, core_axi.araddr[IntByteOffW-1:0]);
          INT_PLIC:
          int_resp_q[int_resp_tail].data <=
              internal_rdata_to_axi(plic_bus.rdata, core_axi.araddr[IntByteOffW-1:0]);
          default: int_resp_q[int_resp_tail].data <= '0;
        endcase
        int_resp_tail <= (int_resp_tail == INT_RESP_IDX_W'(INT_RESP_DEPTH - 1))
                       ? '0 : int_resp_tail + 1'b1;
      end
      if (pop_int_resp) begin
        int_resp_head <= (int_resp_head == INT_RESP_IDX_W'(INT_RESP_DEPTH - 1))
                       ? '0 : int_resp_head + 1'b1;
      end
      unique case ({
        push_int_resp, pop_int_resp
      })
        2'b10:   int_resp_count <= int_resp_count + 1'b1;
        2'b01:   int_resp_count <= int_resp_count - 1'b1;
        default: int_resp_count <= int_resp_count;
      endcase

      // Offchip burst tracking: enter "in burst" on a non-last beat;
      // exit on rlast. Only updates when we are actually forwarding
      // offchip (not draining the FIFO), so a same-cycle FIFO drain
      // does not perturb this flag.
      if (offchip_beat && !drain_int) begin
        offchip_in_burst <= !offchip_axi.rlast;
      end
    end
  end

  // SVA: the router must never produce R-channel beat interleaving
  // within a burst. If we are forwarding offchip and have not yet seen
  // rlast for the burst, the next R beat must also come from offchip
  // (i.e. drain_int must be 0).
  `RAPT_SVA_IMPLY(clock, reset, ROUTER_R_NO_INTERLEAVE, offchip_in_burst, !drain_int)


  // ----- Write channel router -----
  typedef enum logic [2:0] {
    W_IDLE,
    W_INT_W,
    W_INT_B,
    W_IO_W,
    W_IO_B
  } w_state_t;

  w_state_t w_state, w_state_next;
  int_slave_t            w_int_target;
  logic       [     3:0] w_int_id;
  logic       [XLEN-1:0] w_int_awaddr;
  logic       [XLEN-1:0] w_int_data;

  assign clint_bus.awaddr = (w_int_target == INT_CLINT) ? w_int_awaddr : '0;
  assign plic_bus.awaddr  = (w_int_target == INT_PLIC) ? w_int_awaddr : '0;

  int_slave_t aw_int;
  logic       aw_is_int;
  assign aw_int = addr_decode(core_axi.awaddr);
  assign aw_is_int = (aw_int != INT_NONE);

  assign offchip_axi.awvalid = (w_state == W_IDLE) && core_axi.awvalid && !aw_is_int;
  assign offchip_axi.awburst = core_axi.awburst;
  assign offchip_axi.awsize = core_axi.awsize;
  assign offchip_axi.awlen = core_axi.awlen;
  assign offchip_axi.awid = core_axi.awid;
  assign offchip_axi.awaddr = core_axi.awaddr;

  assign core_axi.awready = (w_state == W_IDLE) && (aw_is_int ? 1'b1 : offchip_axi.awready);

  // W-channel forwarding: AXI4 permits the master to assert AW and W
  // simultaneously, and some downstream slaves (e.g. the AXI4 SDRAM
  // controller used by ysyxSoC) require WVALID=1 alongside AWVALID
  // before they will assert AWREADY. Gating WVALID strictly on the
  // AW handshake completing (W_IO_W) deadlocks against such slaves.
  // Forward WVALID combinationally to offchip whenever the upcoming
  // (or in-flight) W beat is destined for offchip -- i.e. either we
  // have already entered W_IO_W, or we are still in W_IDLE with a
  // valid offchip AW request pending.
  assign offchip_axi.wvalid = ((w_state == W_IO_W) ||
                               (w_state == W_IDLE && core_axi.awvalid && !aw_is_int))
                              && core_axi.wvalid;
  assign offchip_axi.wlast = core_axi.wlast;
  assign offchip_axi.wdata = core_axi.wdata;
  assign offchip_axi.wstrb = core_axi.wstrb;

  // WREADY back to the core: accept W in the same cycle as the AW handshake
  // for offchip transactions (W_IDLE && awvalid && !aw_is_int) so the master
  // can complete a single-beat write atomically. The internal CLINT/PLIC
  // path keeps its existing W_INT_W behaviour because those slaves are
  // strictly AW-then-W via the router-internal FSM.
  assign core_axi.wready = (w_state == W_INT_W)
                         || ((w_state == W_IO_W) && offchip_axi.wready)
                         || (w_state == W_IDLE && core_axi.awvalid && !aw_is_int
                             && offchip_axi.wready);

  assign w_int_data = axi_wdata_to_internal(core_axi.wdata, w_int_awaddr[IntByteOffW-1:0]);
  assign clint_bus.wdata = w_int_data;
  assign plic_bus.wdata = w_int_data;
  assign clint_bus.wvalid = (w_state == W_INT_W) && core_axi.wvalid && core_axi.wready
                            && (w_int_target == INT_CLINT);
  assign plic_bus.wvalid  = (w_state == W_INT_W) && core_axi.wvalid && core_axi.wready
                            && (w_int_target == INT_PLIC);

  assign core_axi.bvalid = (w_state == W_INT_B) || ((w_state == W_IO_B) && offchip_axi.bvalid);
  assign core_axi.bid = (w_state == W_INT_B) ? w_int_id : offchip_axi.bid;
  assign core_axi.bresp = (w_state == W_INT_B) ? 2'b00 : offchip_axi.bresp;

  assign offchip_axi.bready = (w_state == W_IO_B) && core_axi.bready;

  always_comb begin
    w_state_next = w_state;
    unique case (w_state)
      W_IDLE: begin
        if (core_axi.awvalid && core_axi.awready) begin
          if (aw_is_int) begin
            w_state_next = W_INT_W;
          end else if (core_axi.wvalid && core_axi.wready && core_axi.wlast) begin
            // AW+W handshake fired in the same cycle (allowed when target
            // is offchip). Skip W_IO_W and wait for the B response.
            w_state_next = W_IO_B;
          end else begin
            w_state_next = W_IO_W;
          end
        end
      end
      W_INT_W: begin
        if (core_axi.wvalid && core_axi.wready) w_state_next = W_INT_B;
      end
      W_INT_B: begin
        if (core_axi.bvalid && core_axi.bready) w_state_next = W_IDLE;
      end
      W_IO_W: begin
        if (core_axi.wvalid && core_axi.wready && core_axi.wlast) w_state_next = W_IO_B;
      end
      W_IO_B: begin
        if (offchip_axi.bvalid && offchip_axi.bready) w_state_next = W_IDLE;
      end
      default: w_state_next = W_IDLE;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      w_state      <= W_IDLE;
      w_int_target <= INT_NONE;
      w_int_id     <= '0;
      w_int_awaddr <= '0;
    end else begin
      w_state <= w_state_next;
      if (w_state == W_IDLE && core_axi.awvalid && core_axi.awready && aw_is_int) begin
        w_int_target <= aw_int;
        w_int_id     <= core_axi.awid;
        w_int_awaddr <= core_axi.awaddr;
      end
    end
  end
endmodule
