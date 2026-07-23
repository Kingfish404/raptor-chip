`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 8
`endif
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

module rapt_bus #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    // Internal memory transaction port
    mem_link_if.master mem,

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    csr_bcast_if.in csr_bcast,
    cmu_bcast_if.in cmu_bcast,

    input reset
);
  typedef enum logic [3:0] {
    L1I  = 1,
    L1D  = 2,
    TLBI = 3,
    TLBD = 4
  } state_lds_t;  // load source

  // =========================================================================
  // Multi-outstanding read AR pipeline.
  //
  // The bus exposes two independent AR slots so L1I and L1D can have ARs in
  // flight simultaneously. The downstream router/SoC handle multi-outstanding
  // responses via request IDs; per-master response de-mux is by ID below.
  //
  //   - L1I slot: 2-deep FIFO. The L1I miss FSM (rapt_l1i.sv RD_0->RD_1)
  //     issues two sequential ARs gated only on `l1i_bus.rready` pulses, so
  //     the bus must accept both back-to-back without waiting for the first
  //     response.
  //   - L1D slot: 1-deep, held until the response's `rlast` so the captured
  //     `l1d_load_is_mmio` flag stays valid across the round trip.
  //
  //   - `*_bus.rready` pulses for one cycle on FIFO push: this preserves the
  //     master-side "AR accepted, advance" semantic that the L1I FSM relies on.
  //
  //   - Arbiter: L1D priority over L1I (matches the original FSM order).
  //     Downstream requests are registered/stable until `rd_req_ready`.
  // =========================================================================
  localparam int L1iARDepth = `RAPT_L1I_REFILL_WORDS;
  localparam int L1iARPtrW = (L1iARDepth <= 1) ? 1 : $clog2(L1iARDepth);
  localparam int L1iARCntW = $clog2(L1iARDepth + 1);

  // L1I AR FIFO (depth 2)
  logic [XLEN-1:0] l1i_q_addr                                     [L1iARDepth];
  logic            l1i_q_burst                                    [L1iARDepth];
  logic            l1i_q_ptw                                      [L1iARDepth];
  logic [L1iARPtrW-1:0] l1i_q_rdptr;
  logic [L1iARPtrW-1:0] l1i_q_wrptr;
  logic [L1iARCntW-1:0] l1i_q_cnt;
  logic l1i_q_full, l1i_q_empty;
  assign l1i_q_full  = (l1i_q_cnt == L1iARCntW'(L1iARDepth));
  assign l1i_q_empty = (l1i_q_cnt == '0);

  // L1D AR slot. Lifetime: capture .. R-rlast (so difftest_skip stays valid).
  logic            l1d_slot_busy;  // pending: AR accepted or in flight or awaiting R
  logic            l1d_slot_issued;  // AR has been handed to downstream
  logic [XLEN-1:0] l1d_slot_addr;
  logic [     2:0] l1d_slot_size;
  logic            l1d_slot_mmio;
  logic            l1d_slot_ptw;

  // Master-side capture handshakes (each pulses *_bus.rready for one cycle).
  //
  // The L1I bus does not expose an arready back to the masters (L1I refill FSM
  // and PTW share `l1i_bus.arvalid`). Both masters hold arvalid high until they
  // observe a response, so a naive `arvalid && !full` push will FIFO the same
  // address multiple times. Gate the push to one capture per (arvalid window,
  // araddr) pair using a captured flag plus last-pushed-address register.
  logic l1i_push, l1d_push;
  logic l1i_captured;
  logic [XLEN-1:0] l1i_last_push_addr;
  logic l1i_last_push_ptw;
  logic l1i_new_request;
  assign l1i_new_request = !l1i_captured
                         || (l1i_bus.araddr != l1i_last_push_addr)
                         || (l1i_bus.ar_ptw != l1i_last_push_ptw);
  assign l1i_push       = l1i_bus.arvalid && !l1i_q_full && l1i_new_request;
  assign l1d_push       = l1d_bus.arvalid && !l1d_slot_busy;
  assign l1i_bus.rready = l1i_push;
  assign l1d_bus.rready = l1d_push;

  // Downstream issue arbiter (L1D priority).
  logic issue_l1d, issue_l1i, l1i_pop;
  assign issue_l1d = l1d_slot_busy && !l1d_slot_issued;
  assign issue_l1i = !issue_l1d && !l1i_q_empty;
  assign l1i_pop = issue_l1i && mem.rd_req_ready;

  logic [XLEN-1:0] l1i_q_head_addr;
  logic            l1i_q_head_burst;
  assign l1i_q_head_addr = l1i_q_addr[l1i_q_rdptr];
  assign l1i_q_head_burst = l1i_q_burst[l1i_q_rdptr];

  // ifu read demux
  assign l1i_bus.rdata = mem.rd_rsp_data;
  assign l1i_bus.rvalid = (mem.rd_rsp_id == L1I) && mem.rd_rsp_valid;
  assign l1i_bus.ptw_rvalid = (mem.rd_rsp_id == TLBI) && mem.rd_rsp_valid;
  assign l1i_bus.rlast = (mem.rd_rsp_id == L1I) && mem.rd_rsp_last;
  assign l1i_bus.rerr = (mem.rd_rsp_id == L1I) && mem.rd_rsp_valid && mem.rd_rsp_error;

  // lsu read demux
  // Gate L1D response by slot_issued: do not forward a response to L1D until
  // our AR has been handed to the slave. This prevents accepting stale
  // responses (e.g. ysyxSoC `sdram_axi` response-FIFO mis-sync) that arrive
  // before our request has been issued.
  assign l1d_bus.rdata = mem.rd_rsp_data;
  assign l1d_bus.rvalid = l1d_slot_issued && !l1d_slot_ptw
                       && (mem.rd_rsp_id == L1D) && mem.rd_rsp_valid;
  assign l1d_bus.ptw_rvalid = l1d_slot_issued && l1d_slot_ptw
                           && (mem.rd_rsp_id == TLBD) && mem.rd_rsp_valid;
  assign l1d_bus.rlast = l1d_slot_issued && !l1d_slot_ptw
                      && (mem.rd_rsp_id == L1D) && mem.rd_rsp_last;
  assign l1d_bus.difftest_skip = l1d_slot_busy && l1d_slot_mmio;
  assign l1d_bus.rerr = l1d_slot_issued && !l1d_slot_ptw && (mem.rd_rsp_id == L1D)
                     && mem.rd_rsp_valid && mem.rd_rsp_error;

  // Downstream AR drive (combinational; backed by registered slot/queue).
  assign mem.rd_req_valid = issue_l1d || issue_l1i;
  assign mem.rd_req_id = issue_l1d ? (l1d_slot_ptw ? 4'(TLBD) : 4'(L1D))
                                   : (l1i_q_ptw[l1i_q_rdptr] ? 4'(TLBI) : 4'(L1I));
  assign mem.rd_req_addr = issue_l1d ? l1d_slot_addr : l1i_q_head_addr;
  assign mem.rd_req_size = issue_l1d ? l1d_slot_size : 3'b010;
  assign mem.rd_req_burst = (issue_l1i && l1i_q_head_burst) ? 2'b01 : 2'b00;
  assign mem.rd_req_len = (issue_l1i && l1i_q_head_burst) ? 8'h1 : 8'h0;
  assign mem.rd_rsp_ready = 1'b1;

  // L1D arsize from rstrb (matches original encoding).
  logic [2:0] l1d_arsize_enc;
  assign l1d_arsize_enc =
      ({3{l1d_bus.rstrb == 8'h01}} & 3'b000) |
      ({3{l1d_bus.rstrb == 8'h03}} & 3'b001) |
      ({3{l1d_bus.rstrb == 8'h0f}} & 3'b010) |
      ({3{l1d_bus.rstrb == 8'hff}} & 3'b011);

  always_ff @(posedge clock) begin
    if (reset) begin
      l1i_q_rdptr <= '0;
      l1i_q_wrptr <= '0;
      l1i_q_cnt   <= '0;
      for (int i = 0; i < L1iARDepth; i++) begin
        l1i_q_addr[i]  <= '0;
        l1i_q_burst[i] <= 1'b0;
        l1i_q_ptw[i]   <= 1'b0;
      end
      l1i_captured       <= 1'b0;
      l1i_last_push_addr <= '0;
      l1i_last_push_ptw  <= 1'b0;
      l1d_slot_busy      <= 1'b0;
      l1d_slot_issued    <= 1'b0;
      l1d_slot_addr      <= '0;
      l1d_slot_size      <= 3'b000;
      l1d_slot_mmio      <= 1'b0;
      l1d_slot_ptw       <= 1'b0;
    end else begin
      // L1I FIFO: push on capture, pop on downstream AR handshake.
      if (l1i_push) begin
        l1i_q_addr[l1i_q_wrptr]  <= l1i_bus.araddr;
        l1i_q_burst[l1i_q_wrptr] <= l1i_bus.arburst;
        l1i_q_ptw[l1i_q_wrptr]   <= l1i_bus.ar_ptw;
        l1i_q_wrptr              <= l1i_q_wrptr + 1'b1;
        l1i_captured             <= 1'b1;
        l1i_last_push_addr       <= l1i_bus.araddr;
        l1i_last_push_ptw        <= l1i_bus.ar_ptw;
      end else if (!l1i_bus.arvalid) begin
        // arvalid dropped -> window closed; reopen capture window.
        l1i_captured <= 1'b0;
      end
      if (l1i_pop) begin
        l1i_q_rdptr <= l1i_q_rdptr + 1'b1;
      end
      // Combined count update: handles same-cycle push+pop.
      unique case ({
        l1i_push, l1i_pop
      })
        2'b10:   l1i_q_cnt <= l1i_q_cnt + 1'b1;
        2'b01:   l1i_q_cnt <= l1i_q_cnt - 1'b1;
        default: l1i_q_cnt <= l1i_q_cnt;
      endcase

      // L1D slot: capture, mark issued on AR handshake, free on rlast.
      if (l1d_push) begin
        l1d_slot_busy   <= 1'b1;
        l1d_slot_issued <= 1'b0;
        l1d_slot_addr   <= l1d_bus.araddr;
        l1d_slot_size   <= l1d_arsize_enc;
        l1d_slot_mmio   <= rapt_pkg::addr_mmio(l1d_bus.araddr);
        l1d_slot_ptw    <= l1d_bus.ar_ptw;
      end
      if (issue_l1d && mem.rd_req_ready) begin
        l1d_slot_issued <= 1'b1;
      end
      if (l1d_slot_busy && l1d_slot_issued && mem.rd_rsp_valid && mem.rd_rsp_last
          && (mem.rd_rsp_id == (l1d_slot_ptw ? 4'(TLBD) : 4'(L1D)))) begin
        l1d_slot_busy   <= 1'b0;
        l1d_slot_issued <= 1'b0;
        l1d_slot_mmio   <= 1'b0;
        l1d_slot_ptw    <= 1'b0;
      end
    end
  end

  typedef enum logic {
    WR_IDLE,
    WR_WAIT
  } write_state_t;

  write_state_t write_state;
  state_lds_t store_bridge;
  state_lds_t store_source;
  logic [XLEN-1:0] store_awaddr;
  logic [XLEN-1:0] store_wdata;
  logic [7:0] store_wstrb;
  logic store_awvalid;
  logic store_wvalid;

  assign store_bridge = l1i_bus.awvalid ? (l1i_bus.aw_ptw ? TLBI : L1I)
                                        : (l1d_bus.aw_ptw ? TLBD : L1D);
  assign store_awaddr = (store_bridge inside {L1I, TLBI}) ? l1i_bus.awaddr : l1d_bus.awaddr;
  assign store_wdata = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wdata : l1d_bus.wdata;
  assign store_wstrb = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wstrb : l1d_bus.wstrb;
  assign store_awvalid = (store_bridge inside {L1I, TLBI}) ? l1i_bus.awvalid : l1d_bus.awvalid;
  assign store_wvalid = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wvalid : l1d_bus.wvalid;

  assign mem.wr_req_valid = (write_state == WR_IDLE) && store_awvalid && store_wvalid;
  assign mem.wr_req_id = 4'(store_bridge);
  assign mem.wr_req_addr = store_awaddr;
  assign mem.wr_req_size =
      ({3{store_wstrb == 8'h01}} & 3'b000)
    | ({3{store_wstrb == 8'h03}} & 3'b001)
    | ({3{store_wstrb == 8'h0f}} & 3'b010)
    | ({3{store_wstrb == 8'hff}} & 3'b011);
  assign mem.wr_req_data = store_wdata;
  assign mem.wr_req_strb = store_wstrb[XLEN/8-1:0];
  assign mem.wr_rsp_ready = write_state == WR_WAIT;

  assign l1i_bus.wready = (write_state == WR_WAIT) && (store_source == L1I)
                       && mem.wr_rsp_valid;
  assign l1i_bus.werr = (store_source == L1I) && mem.wr_rsp_valid && mem.wr_rsp_error;
  assign l1i_bus.ptw_wready = (write_state == WR_WAIT) && (store_source == TLBI)
                           && mem.wr_rsp_valid;
  assign l1i_bus.ptw_werr = (store_source == TLBI) && mem.wr_rsp_valid && mem.wr_rsp_error;
  assign l1d_bus.wready = (write_state == WR_WAIT) && (store_source == L1D)
                       && mem.wr_rsp_valid;
  assign l1d_bus.werr = (store_source == L1D) && mem.wr_rsp_valid && mem.wr_rsp_error;
  assign l1d_bus.ptw_wready = (write_state == WR_WAIT) && (store_source == TLBD)
                           && mem.wr_rsp_valid;
  assign l1d_bus.ptw_werr = (store_source == TLBD) && mem.wr_rsp_valid && mem.wr_rsp_error;

  always_ff @(posedge clock) begin
    if (reset) begin
      write_state <= WR_IDLE;
      store_source <= L1D;
    end else begin
      unique case (write_state)
        WR_IDLE: begin
          if (mem.wr_req_valid && mem.wr_req_ready) begin
            store_source <= store_bridge;
            write_state <= WR_WAIT;
          end
        end
        WR_WAIT: begin
          if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
            write_state <= WR_IDLE;
          end
        end
        default: write_state <= WR_IDLE;
      endcase
    end
  end

  `RAPT_SVA_IMPLY(clock, reset, BUS_STORE_RESPONSE_OK, mem.wr_rsp_valid, !mem.wr_rsp_error)

endmodule
