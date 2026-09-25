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
    input logic coherent_ready = 1'b1,
    output logic coherent_request,
    output logic coherent_write,

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
  // The bus exposes independent I, legacy D/PTW and MSHR slots for reads in
  // flight simultaneously. The downstream router/SoC handle multi-outstanding
  // responses via request IDs; per-master response de-mux is by ID below.
  //
  //   - L1I slot: refill-depth FIFO. The L1I miss FSM can issue sequential
  //     ARs gated only on `l1i_bus.rready` pulses, so the bus must accept a
  //     complete refill without waiting for its first response.
  //   - Legacy L1D/PTW slot: 1-deep, held until `rlast` so the captured
  //     `l1d_load_is_mmio` flag stays valid across the round trip.
  //
  //   - `*_bus.rready` pulses for one cycle on FIFO push: this preserves the
  //     master-side "AR accepted, advance" semantic that the L1I FSM relies on.
  //
  //   - MSHRs: dedicated IDs 8..11, with ownership retained through RLAST.
  //   - Arbiter: legacy D/PTW, then MSHRs, then L1I.
  //     Downstream requests are registered/stable until `rd_req_ready`.
  // =========================================================================
  localparam int L1iARDepth = `RAPT_L1I_REFILL_WORDS;
  localparam int L1iARPtrW  = (L1iARDepth <= 1) ? 1 : $clog2(L1iARDepth);
  localparam int L1iARCntW  = $clog2(L1iARDepth + 1);

  // L1I AR FIFO (one entry per refill word)
  logic [XLEN-1:0] l1i_q_addr                                     [L1iARDepth];
  logic            l1i_q_burst                                    [L1iARDepth];
  logic [1:0]      l1i_q_pbmt [L1iARDepth];
  logic l1i_q_noallocate[L1iARDepth];
  logic            l1i_q_ptw                                      [L1iARDepth];
  logic [L1iARPtrW-1:0] l1i_q_rdptr;
  logic [L1iARPtrW-1:0] l1i_q_wrptr;
  logic [L1iARCntW-1:0] l1i_q_cnt;
  logic l1i_q_full, l1i_q_empty;
  assign l1i_q_full  = (l1i_q_cnt == L1iARCntW'(L1iARDepth));
  assign l1i_q_empty = (l1i_q_cnt == '0);

  // L1D AR slot. Lifetime: capture .. R-rlast (so difftest_skip stays valid).
  logic            l1d_slot_busy;  // pending: buffered, in flight, or awaiting R
  logic            l1d_slot_held;  // ownership transferred to downstream/skid
  logic            l1d_slot_issued;  // AR handshake completed with downstream
  logic [XLEN-1:0] l1d_slot_addr;
  logic [     2:0] l1d_slot_size;
  logic [7:0] l1d_slot_len;
  logic l1d_slot_noallocate, rd_skid_noallocate, source_noallocate;
  logic            l1d_slot_mmio;
  logic            l1d_slot_ptw;
  logic [1:0]      l1d_slot_pbmt;

  logic rd_output_fire;
  logic [2:0] l1d_arsize_enc;

  // Dedicated MSHR IDs 8..11, independent of legacy D/PTW IDs 2/4.
  // Ownership lasts through RLAST even across pipeline cancellation.
  logic [3:0] miss_busy, miss_held, miss_issued;
  logic [XLEN-1:0] miss_addr[4];
  logic [7:0] miss_len[4];
  logic [2:0] miss_size[4];
  logic miss_push, miss_available, source_miss, take_miss, miss_response;
  logic [1:0] miss_select;
  always_comb begin
    miss_available = 0;
    miss_select = 0;
    for (int i = 3; i >= 0; i--)
    if (miss_busy[i] && !miss_held[i]) begin
      miss_available = 1;
      miss_select = 2'(i);
    end
  end
  assign miss_push = (`RAPT_L1D_MSHRS > 0) && l1d_bus.arvalid && l1d_bus.ar_mshr
      && !miss_busy[l1d_bus.ar_mshr_id];
  assign miss_response = mem.rd_rsp_valid && mem.rd_rsp_id[3:2] == 2'b10
      && miss_issued[mem.rd_rsp_id[1:0]];
  assign l1d_bus.r_mshr = miss_response;
  assign l1d_bus.r_mshr_id = mem.rd_rsp_id[1:0];
  always_ff @(posedge clock) begin
    if (reset) begin
      miss_busy <= '0;
      miss_held <= '0;
      miss_issued <= '0;
    end else begin
      if (miss_push) begin
        miss_busy[l1d_bus.ar_mshr_id] <= 1;
        miss_held[l1d_bus.ar_mshr_id] <= 0;
        miss_issued[l1d_bus.ar_mshr_id] <= 0;
        miss_addr[l1d_bus.ar_mshr_id] <= l1d_bus.araddr;
        miss_len[l1d_bus.ar_mshr_id] <= l1d_bus.arlen;
        miss_size[l1d_bus.ar_mshr_id] <= l1d_arsize_enc;
      end
      if (take_miss) miss_held[miss_select] <= 1;
      if (rd_output_fire && mem.rd_req_id[3:2] == 2'b10) miss_issued[mem.rd_req_id[1:0]] <= 1;
      if (miss_response && mem.rd_rsp_last) begin
        miss_busy[mem.rd_rsp_id[1:0]] <= 0;
        miss_held[mem.rd_rsp_id[1:0]] <= 0;
        miss_issued[mem.rd_rsp_id[1:0]] <= 0;
      end
    end
  end

  // Master-side capture handshakes (each pulses *_bus.rready for one cycle).
  //
  // The L1I bus does not expose an arready back to the masters (L1I refill FSM
  // and PTW share `l1i_bus.arvalid`). Both masters hold arvalid high until they
  // observe a response, so a naive `arvalid && !full` push will FIFO the same
  // address multiple times. Gate the push to one capture per (arvalid window,
  // araddr) pair using a captured flag plus last-pushed-address register.
  logic l1i_push, l1d_push;
  // Only instruction-side PTW reads require D-cache writeback coherence.
  // Ordinary instruction refills may see old code until FENCE.I retires;
  // that instruction drains the D-cache and invalidates L1I before refetch.
  logic [15:0] coherent_reads;
  logic coherent_read_done;
  logic l1i_arvalid_q;
  assign coherent_read_done = mem.rd_rsp_valid && mem.rd_rsp_last && mem.rd_rsp_id == 4'(TLBI);
  always_ff @(posedge clock) begin
    if (reset) begin
      coherent_reads <= '0;
      l1i_arvalid_q  <= 1'b0;
    end else begin
      // Register the PTW drain request: a direct valid -> drain -> memory-idle
      // -> IO-authorize -> valid path would form a combinational loop.
      l1i_arvalid_q <= l1i_bus.arvalid && l1i_bus.ar_ptw;
      case ({
        l1i_push && l1i_bus.ar_ptw, coherent_read_done
      })
        2'b10: coherent_reads <= coherent_reads + 1'b1;
        2'b01: if (coherent_reads != 0) coherent_reads <= coherent_reads - 1'b1;
        default: coherent_reads <= coherent_reads;
      endcase
    end
  end
  logic l1i_captured;
  logic [XLEN-1:0] l1i_last_push_addr;
  logic l1i_last_push_ptw;
  logic l1i_new_request;
  assign l1i_new_request = !l1i_captured
                         || (l1i_bus.araddr != l1i_last_push_addr)
                         || (l1i_bus.ar_ptw != l1i_last_push_ptw);
  assign l1i_push       = l1i_bus.arvalid && !l1i_q_full && l1i_new_request
      && (!l1i_bus.ar_ptw || coherent_ready);
  assign l1d_push       = l1d_bus.arvalid && !l1d_bus.ar_mshr && !l1d_slot_busy;
  assign l1i_bus.rready = l1i_push;
  assign l1d_bus.rready = l1d_push || miss_push;

  // Downstream AR fall-through skid buffer (L1D priority).
  //
  // The normal ready path remains combinational, matching the latency and
  // throughput of the known-good implementation.  On backpressure, the skid
  // entry takes ownership of the complete AR payload and holds it stable until
  // handshake.  When a buffered request handshakes, the entry can be replaced
  // in the same cycle, so recovery from a stall also has no valid bubble.
  logic rd_skid_valid;
  logic [3:0] rd_skid_id;
  logic [XLEN-1:0] rd_skid_addr;
  logic [2:0] rd_skid_size;
  logic [7:0] rd_skid_len;
  logic [1:0] rd_skid_burst;
  logic [1:0] rd_skid_pbmt;
  logic source_l1d, source_l1i, source_valid;
  logic [3:0] source_id;
  logic [XLEN-1:0] source_addr;
  logic [2:0] source_size;
  logic [7:0] source_len;
  logic [1:0] source_burst;
  logic [1:0] source_pbmt;
  logic rd_skid_available, rd_capture_source;
  logic take_l1d, take_l1i, l1i_pop;

  assign rd_skid_available = !rd_skid_valid || mem.rd_req_ready;
  assign source_l1d = l1d_slot_busy && !l1d_slot_held;
  assign source_miss = !source_l1d && miss_available;
  assign source_l1i = !source_l1d && !source_miss && !l1i_q_empty
      && (!l1i_q_ptw[l1i_q_rdptr] || coherent_ready);
  assign source_valid = source_l1d || source_miss || source_l1i;
  assign take_miss = rd_skid_available && source_miss;
  assign take_l1d = rd_skid_available && source_l1d;
  assign take_l1i = rd_skid_available && source_l1i;
  assign l1i_pop = take_l1i;

  logic [XLEN-1:0] l1i_q_head_addr;
  logic            l1i_q_head_burst;
  assign l1i_q_head_addr = l1i_q_addr[l1i_q_rdptr];
  assign l1i_q_head_burst = l1i_q_burst[l1i_q_rdptr];

  // ifu read demux
  assign l1i_bus.rdata = mem.rd_rsp_data;
  assign l1i_bus.rvalid = (mem.rd_rsp_id == L1I) && mem.rd_rsp_valid;
  assign l1i_bus.ptw_rvalid = (mem.rd_rsp_id == TLBI) && mem.rd_rsp_valid;
  assign l1i_bus.ptw_rerr = l1i_bus.ptw_rvalid && mem.rd_rsp_error;
  assign l1i_bus.rlast = (mem.rd_rsp_id == L1I) && mem.rd_rsp_last;
  assign l1i_bus.rerr = (mem.rd_rsp_id == L1I) && mem.rd_rsp_valid && mem.rd_rsp_error;

  // lsu read demux
  // Gate L1D response by slot_issued: do not forward a response to L1D until
  // our AR has been handed to the slave. This prevents accepting stale
  // responses that arrive
  // before our request has been issued.
  assign l1d_bus.rdata = mem.rd_rsp_data;
  assign l1d_bus.rvalid = miss_response || (l1d_slot_issued && !l1d_slot_ptw
                       && (mem.rd_rsp_id == L1D) && mem.rd_rsp_valid);
  assign l1d_bus.ptw_rvalid = l1d_slot_issued && l1d_slot_ptw
                           && (mem.rd_rsp_id == TLBD) && mem.rd_rsp_valid;
  assign l1d_bus.rlast = mem.rd_rsp_last && (miss_response || (l1d_slot_issued && !l1d_slot_ptw
                      && (mem.rd_rsp_id == L1D)));
  assign l1d_bus.difftest_skip = !miss_response && l1d_slot_busy && l1d_slot_mmio;
  assign l1d_bus.rerr = l1d_bus.rvalid && mem.rd_rsp_error;
  assign l1d_bus.ptw_rerr = l1d_bus.ptw_rvalid && mem.rd_rsp_error;

  assign source_id = source_l1d ? (l1d_slot_ptw ? 4'(TLBD) : 4'(L1D))
                                : source_miss ? {2'b10, miss_select} : (l1i_q_ptw[l1i_q_rdptr] ? 4'(TLBI) : 4'(L1I));
  assign source_pbmt = source_l1d ? l1d_slot_pbmt : source_miss ? 2'b00 : l1i_q_pbmt[l1i_q_rdptr];
  assign source_addr = source_l1d ? l1d_slot_addr : source_miss ? miss_addr[miss_select] : l1i_q_head_addr;
  // RV64 page-table entries are 64 bits.  L1I/PTW requests share the L1I
  // queue, but only ordinary instruction refills are 32-bit reads. Sending
  // a 4-byte PTW read through LiteX's AXI64->AXI32 converter returns only one
  // half of the PTE and loses the physical page number on FPGA.
`ifdef RAPT_RV64
  localparam logic [2:0] PtwReadSize = 3'b011;
`else
  localparam logic [2:0] PtwReadSize = 3'b010;
`endif
  assign source_size = source_l1d ? l1d_slot_size
                                  : source_miss ? miss_size[miss_select] : (l1i_q_ptw[l1i_q_rdptr] ? PtwReadSize : 3'b010);
  assign source_burst = (source_miss || (source_l1d && l1d_slot_len != 0) || (source_l1i
      && l1i_q_head_burst)) ? 2'b01 : 2'b00;
  assign source_len = source_l1d ? l1d_slot_len : source_miss ? miss_len[miss_select] : (source_l1i && l1i_q_head_burst)
      ? 8'h01 : 8'h00;

  // Bypass when the skid entry is empty; use only registered payload while
  // stalled.  This is the only driver of the downstream AR channel.
  assign mem.rd_req_valid = rd_skid_valid || source_valid;
  assign mem.rd_req_id = rd_skid_valid ? rd_skid_id : source_id;
  assign mem.rd_req_addr = rd_skid_valid ? rd_skid_addr : source_addr;
  assign mem.rd_req_size = rd_skid_valid ? rd_skid_size : source_size;
  assign mem.rd_req_burst = rd_skid_valid ? rd_skid_burst : source_burst;
  assign mem.rd_req_pbmt = rd_skid_valid ? rd_skid_pbmt : source_pbmt;
  assign source_noallocate = source_l1d ? l1d_slot_noallocate : source_miss ? 1'b1 : l1i_q_noallocate[l1i_q_rdptr];
  assign mem.rd_req_noallocate = rd_skid_valid ? rd_skid_noallocate : source_noallocate;
  assign mem.rd_req_len = rd_skid_valid ? rd_skid_len : source_len;
  assign rd_output_fire = mem.rd_req_valid && mem.rd_req_ready;
  assign rd_capture_source = rd_skid_available && source_valid
                           && (rd_skid_valid || !mem.rd_req_ready);
  assign mem.rd_rsp_ready = 1'b1;

  // L1D arsize from rstrb (matches original encoding).
  assign l1d_arsize_enc =
      ({3{l1d_bus.rstrb == 8'h01}} & 3'b000) |
      ({3{l1d_bus.rstrb == 8'h03}} & 3'b001) |
      ({3{l1d_bus.rstrb == 8'h0f}} & 3'b010) |
      ({3{l1d_bus.rstrb == 8'hff}} & 3'b011);

  always_ff @(posedge clock) begin
    if (reset) begin
      rd_skid_valid <= 1'b0;
      // Invalid skid payload is never selected. Capture rewrites every
      // field together with valid, including PBMT/noallocate attributes.
    end else if (rd_skid_available) begin
      rd_skid_valid <= rd_capture_source;
      if (rd_capture_source) begin
        rd_skid_id    <= source_id;
        rd_skid_addr  <= source_addr;
        rd_skid_size  <= source_size;
        rd_skid_len   <= source_len;
        rd_skid_burst <= source_burst;
        rd_skid_pbmt <= source_pbmt;
        rd_skid_noallocate <= source_noallocate;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      l1i_q_rdptr <= '0;
      l1i_q_wrptr <= '0;
      l1i_q_cnt   <= '0;
      // l1i_q_* payload and l1d_slot_addr/size stay unreset: every read is
      // gated by l1i_q_cnt != 0 (source_l1i) or l1d_slot_busy/held, both
      // of which reset here; push/pop always rewrite the payload together
      // with the pointer/count update.  l1d_slot_mmio/ptw are cleared on
      // slot free.
      l1i_captured       <= 1'b0;
      // !l1i_captured accepts the first request regardless of old identity.
      // A capture rewrites address/PTW together before comparisons matter.
      l1d_slot_busy      <= 1'b0;
      l1d_slot_held      <= 1'b0;
      l1d_slot_issued    <= 1'b0;
    end else begin
      // L1I FIFO: push on capture, pop when ownership transfers to the
      // downstream channel or its skid entry.
      if (l1i_push) begin
        l1i_q_addr[l1i_q_wrptr]  <= l1i_bus.araddr;
        l1i_q_burst[l1i_q_wrptr] <= l1i_bus.arburst;
        l1i_q_ptw[l1i_q_wrptr]   <= l1i_bus.ar_ptw;
        l1i_q_noallocate[l1i_q_wrptr] <= l1i_bus.ar_ptw || l1i_bus.noallocate;
        l1i_q_pbmt[l1i_q_wrptr] <= l1i_bus.ar_ptw ? 2'b00 : l1i_bus.rpbmt;
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

      // L1D slot: capture, transfer ownership to the downstream AR channel or
      // its skid entry, then free on the matching final response beat.
      if (l1d_push) begin
        l1d_slot_busy   <= 1'b1;
        l1d_slot_held   <= 1'b0;
        l1d_slot_issued <= 1'b0;
        l1d_slot_addr   <= l1d_bus.araddr;
        l1d_slot_size   <= l1d_arsize_enc;
        l1d_slot_len <= l1d_bus.ar_ptw ? 8'd0 : l1d_bus.arlen;
        l1d_slot_noallocate <= l1d_bus.ar_ptw || l1d_bus.noallocate;
        l1d_slot_mmio   <= rapt_pkg::addr_mmio(l1d_bus.araddr);
        l1d_slot_ptw    <= l1d_bus.ar_ptw;
        l1d_slot_pbmt <= l1d_bus.ar_ptw ? 2'b00 : l1d_bus.rpbmt;
      end
      if (take_l1d) begin
        l1d_slot_held <= 1'b1;
      end
      if (rd_output_fire && (mem.rd_req_id inside {4'(L1D), 4'(TLBD)})) begin
        l1d_slot_issued <= 1'b1;
      end
      if (l1d_slot_busy && l1d_slot_issued && mem.rd_rsp_valid && mem.rd_rsp_last
          && (mem.rd_rsp_id == (l1d_slot_ptw ? 4'(TLBD) : 4'(L1D)))) begin
        l1d_slot_busy   <= 1'b0;
        l1d_slot_held   <= 1'b0;
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

  assign coherent_request = l1i_arvalid_q || l1i_bus.awvalid
      || coherent_reads != 0
      || (write_state == WR_WAIT && store_source inside {L1I, TLBI});
  assign coherent_write = l1i_bus.awvalid
      || (write_state == WR_WAIT && store_source inside {L1I, TLBI});
  assign store_bridge = l1i_bus.awvalid && coherent_ready ? (l1i_bus.aw_ptw ? TLBI : L1I)
                                        : (l1d_bus.aw_ptw ? TLBD : L1D);
  assign store_awaddr = (store_bridge inside {L1I, TLBI}) ? l1i_bus.awaddr : l1d_bus.awaddr;
  assign store_wdata = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wdata : l1d_bus.wdata;
  assign store_wstrb = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wstrb : l1d_bus.wstrb;
  assign store_awvalid = (store_bridge inside {L1I, TLBI}) ? l1i_bus.awvalid : l1d_bus.awvalid;
  assign store_wvalid = (store_bridge inside {L1I, TLBI}) ? l1i_bus.wvalid : l1d_bus.wvalid;

  assign l1d_bus.idle = !(|miss_busy) && !l1d_slot_busy && !l1d_bus.arvalid
      && write_state == WR_IDLE && !store_awvalid && !store_wvalid;

  assign mem.wr_req_valid = (write_state == WR_IDLE) && store_awvalid && store_wvalid;
  assign mem.wr_req_zero = store_bridge == L1D && l1d_bus.wzero;
  assign mem.wr_req_id = 4'(store_bridge);
  assign mem.wr_req_addr = store_awaddr;
  assign mem.wr_req_pbmt = store_bridge == L1D ? l1d_bus.wpbmt : 2'b00;
  // Right-aligned one- and two-byte requests can use narrow AXI transfers.
  // Wider or lane-shifted partial masks come from aligned misaligned-store
  // beats; cover the highest asserted lane with a 4- or 8-byte transfer and
  // let WSTRB select the architectural bytes. The AXI master also accounts
  // for AWADDR's byte offset when sizing the final bus-lane transfer span.
  assign mem.wr_req_size = (store_wstrb == 8'h01) ? 3'b000
                         : (store_wstrb == 8'h03) ? 3'b001
                         : (store_wstrb[7:4] == 4'h0) ? 3'b010
                         : 3'b011;
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

  `RAPT_SVA_IMPLY(clock, reset, BUS_STORE_RESPONSE_OWNED, mem.wr_rsp_valid,
                  write_state == WR_WAIT && mem.wr_rsp_id == 4'(store_source))

endmodule
