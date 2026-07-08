/**
 * rapt_l2 -- L2 unified cache (AXI4-slave on CPU side, AXI4-master on
 * memory side).
 *
 * Sits between `rapt_bus` and the external `io_master` AXI port:
 *
 *   L1I -+
 *        +-> rapt_bus --> rapt_l2 --> io_master (external)
 *   L1D -+
 *
 * Both ports are AXI4. When `RAPT_L2_EN` is not defined the module
 * collapses to a transparent passthrough, so adding the instantiation
 * is a no-op until L2 is opted in.
 *
 * --- Design summary (RAPT_L2_EN) ---
 *
 *   * Direct-mapped (L2_N_WAYS=1 supported today; >1 reserved).
 *   * Line size  = 1 << L2_LINE_LEN words (default 4 words / 16 B @ RV32).
 *   * Sets       = 1 << L2_LEN (default 128 sets -> 8 KB @ RV32 / 16 KB @ RV64).
 *   * Tag + valid stored in flops; data stored in SRAM-style word banks so
 *     FPGA builds infer local RAM instead of a 100k+ FF data array.
 *   * Cacheable region: external main memory windows only. MMIO/ROM/SRAM
 *     traffic is forwarded straight through with no cache lookup.
 *   * Read policy : on miss allocate a full-line refill from memory
 *     (INCR burst of LineSize beats). The first matching beat is
 *     forwarded to the requester as it streams in (early-restart);
 *     remaining beats are returned from the line buffer once the fill
 *     completes.
 *   * Write policy: write-through, no write-allocate. Stores update
 *     the cached line on hit and are always forwarded downstream so
 *     external memory stays coherent. Burst writes are passed through.
 *   * Single in-flight read miss / single in-flight write at a time.
 *     Concurrent (R + W) channel use is supported.
 *   * AXI ID is preserved end-to-end so multi-master upstream traffic
 *     (L1I/L1D) keeps its rid/bid routing.
 *
 * Known TODO / future work:
 *   * Multi-outstanding miss tracking (MSHR).
 *   * Set-associative + LRU.
 *   * Write-back (dirty bit) -- currently write-through.
 *   * Optional SRAM macro mapping via `rapt_sram_1r1w`.
 */
`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

`ifndef RAPT_L2_LEN
`define RAPT_L2_LEN 7
`endif
`ifndef RAPT_L2_LINE_LEN
`define RAPT_L2_LINE_LEN 2
`endif
`ifndef RAPT_L2_N_WAYS
`define RAPT_L2_N_WAYS 1
`endif

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module rapt_l2 #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int L2_LEN = `RAPT_L2_LEN,
    parameter int L2_LINE_LEN = `RAPT_L2_LINE_LEN,
    parameter int L2_N_WAYS = `RAPT_L2_N_WAYS
) (
    input clock,
    input reset,

    // CPU / rapt_bus side
    axi4_if.slave  axi_s,
    // External memory side
    axi4_if.master axi_m
);

// The active L2 cache is only instantiated when explicitly enabled
// (`RAPT_L2_EN`) AND the build does not target the third-party ysyxSoC
// (`RAPT_SOC`). The ysyxSoC `sdram_axi` / xbar slaves cannot service the
// L2's multi-beat burst line fills (the same incompatibility that forces
// the legacy single-outstanding bus FSM under `RAPT_SOC`); an allocate on a
// store/load miss never completes, hanging the SQ/ROB on the first SDRAM
// store (e.g. `sb` to 0xa000_000a during the MROM->SDRAM copy loop). For
// SoC builds the L2 therefore collapses to a pure passthrough.
`ifdef RAPT_L2_EN
`ifndef RAPT_SOC
`define RAPT_L2_ACTIVE
`endif
`endif

`ifndef RAPT_L2_ACTIVE
  // =====================================================================
  // Pure passthrough (L2 disabled). Kept lint-clean.
  // =====================================================================
  assign axi_m.arvalid = axi_s.arvalid;
  assign axi_m.araddr  = axi_s.araddr;
  assign axi_m.arid    = axi_s.arid;
  assign axi_m.arlen   = axi_s.arlen;
  assign axi_m.arsize  = axi_s.arsize;
  assign axi_m.arburst = axi_s.arburst;
  assign axi_s.arready = axi_m.arready;

  assign axi_s.rvalid  = axi_m.rvalid;
  assign axi_s.rdata   = axi_m.rdata;
  assign axi_s.rid     = axi_m.rid;
  assign axi_s.rresp   = axi_m.rresp;
  assign axi_s.rlast   = axi_m.rlast;
  assign axi_m.rready  = axi_s.rready;

  assign axi_m.awvalid = axi_s.awvalid;
  assign axi_m.awaddr  = axi_s.awaddr;
  assign axi_m.awid    = axi_s.awid;
  assign axi_m.awlen   = axi_s.awlen;
  assign axi_m.awsize  = axi_s.awsize;
  assign axi_m.awburst = axi_s.awburst;
  assign axi_s.awready = axi_m.awready;

  assign axi_m.wvalid  = axi_s.wvalid;
  assign axi_m.wdata   = axi_s.wdata;
  assign axi_m.wstrb   = axi_s.wstrb;
  assign axi_m.wlast   = axi_s.wlast;
  assign axi_s.wready  = axi_m.wready;

  assign axi_s.bvalid  = axi_m.bvalid;
  assign axi_s.bid     = axi_m.bid;
  assign axi_s.bresp   = axi_m.bresp;
  assign axi_m.bready  = axi_s.bready;
`else
  // =====================================================================
  // Active L2 cache implementation.
  // =====================================================================
  localparam int LineSize = 1 << L2_LINE_LEN;  // words per line
  localparam int LineBits = LineSize * XLEN;
  localparam int NSets = 1 << L2_LEN;
  localparam int WordBytes = XLEN / 8;
  localparam int OffsetBits = L2_LINE_LEN + $clog2(WordBytes);
  localparam int IndexBits = L2_LEN;
  localparam int TagBits = XLEN - IndexBits - OffsetBits;
  localparam int ByteOffsetBits = $clog2(WordBytes);
  localparam int WordOffsetLsb = ByteOffsetBits;
  localparam int WordOffsetMsb = ByteOffsetBits + L2_LINE_LEN - 1;
  localparam int IndexLsb = OffsetBits;
  localparam int IndexMsb = OffsetBits + IndexBits - 1;
  localparam int TagLsb = OffsetBits + IndexBits;

  // ---------------------------------------------------------------------
  // Storage. L2_N_WAYS > 1 reserved for future use; current logic only walks
  // way 0. Tag/valid stay in flops for reset simplicity; the data array is
  // banked by word offset and implemented with the standard 1R1W SRAM wrapper
  // to avoid expanding the default 16 KiB L2 into ~131k data FFs on FPGA.
  // ---------------------------------------------------------------------
  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */
  logic                line_valid[L2_N_WAYS][NSets];
  logic [TagBits-1:0] line_tag  [L2_N_WAYS][NSets];
  logic [    XLEN-1:0] line_data_r[LineSize];
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------
  // L2 is intentionally narrower than the L1 addr_cacheable() allowlist: keep
  // ROM/SRAM/flash single-beat through the LiteX fabric and reserve L2 line
  // fills for external main memory where Linux/app payloads execute.
  function automatic logic cacheable(input logic [XLEN-1:0] a);
    return (0)
        || (a >= 'h80000000 && a < 'h90000000)  // FPGA main RAM / PMEM window.
        || (a >= 'ha0000000 && a < 'ha2000000); // legacy SDRAM window.
  endfunction

  // =====================================================================
  // READ PATH
  // =====================================================================
  typedef enum logic [3:0] {
    R_IDLE,
    R_HIT,
    R_MISS_AR,
    R_MISS_R,
    R_INSTALL_WAIT,
    R_BYPASS_WAIT,
    R_BYPASS_AR,
    R_BYPASS_R
  } state_r_t;

  state_r_t rs;
  logic [ID_W-1:0] r_id;
  logic [XLEN-1:0] r_addr;  // captured AR address (start of req)
  logic [7:0] r_len;  // remaining beats - 1 of upstream burst
  logic [2:0] r_size;
  logic [1:0] r_burst;
  logic [L2_LINE_LEN-1:0] r_word;  // current word offset within line
  logic [XLEN-1:0] r_line_buf[LineSize];
  logic [L2_LINE_LEN-1:0] r_fill_cnt;  // next word slot to write on fill
  logic [1:0] r_resp;  // sticky worst rresp during fill
  logic r_up_done;  // upstream burst fully delivered (early-restart latch)

  // Hit detection on currently latched address (only meaningful while
  // rs == R_IDLE handshake or in R_HIT/R_MISS_*).
  logic [IndexBits-1:0] r_idx_q;
  logic [TagBits-1:0] r_tag_q;
  logic r_hit_q;
  assign r_idx_q = r_addr[IndexMsb:IndexLsb];
  assign r_tag_q = r_addr[XLEN-1:TagLsb];
  assign r_hit_q = line_valid[0][r_idx_q] && (line_tag[0][r_idx_q] == r_tag_q);

  // ---------------------------------------------------------------------
  // Slave side R driver
  // ---------------------------------------------------------------------
  logic rs_rvalid;
  logic [XLEN-1:0] rs_rdata;
  logic rs_rlast;
  logic [1:0] rs_rresp;
  logic [ID_W-1:0] rs_rid;

  assign axi_s.rvalid = rs_rvalid;
  assign axi_s.rdata  = rs_rdata;
  assign axi_s.rlast  = rs_rlast;
  assign axi_s.rresp  = rs_rresp;
  assign axi_s.rid    = rs_rid;

    logic r_hit_beat_fire;
    logic [IndexBits-1:0] data_sram_raddr;
    assign r_hit_beat_fire = (rs == R_HIT) && r_hit_q && (!rs_rvalid || axi_s.rready);
    assign data_sram_raddr =
      (rs == R_IDLE && axi_s.arvalid && axi_s.arready && cacheable(axi_s.araddr))
        ? axi_s.araddr[IndexMsb:IndexLsb]
      : (r_hit_beat_fire && (r_len != 8'd0) && (r_word == L2_LINE_LEN'(LineSize - 1)))
          ? (r_idx_q + IndexBits'(1))
      : r_idx_q;

  // ---------------------------------------------------------------------
  // AR acceptance: only when read FSM idle.
  // ---------------------------------------------------------------------
  assign axi_s.arready = (rs == R_IDLE);

  // ---------------------------------------------------------------------
  // Master-side AR (issued during R_MISS_AR or R_BYPASS_AR).
  // ---------------------------------------------------------------------
  logic            m_arvalid;
  logic [XLEN-1:0] m_araddr;
  logic [ID_W-1:0] m_arid;
  logic [     7:0] m_arlen;
  logic [     2:0] m_arsize;
  logic [     1:0] m_arburst;

  assign axi_m.arvalid = m_arvalid;
  assign axi_m.araddr  = m_araddr;
  assign axi_m.arid    = m_arid;
  assign axi_m.arlen   = m_arlen;
  assign axi_m.arsize  = m_arsize;
  assign axi_m.arburst = m_arburst;

  // Miss fills can always be accepted into the line buffer. Bypass reads only
  // accept a downstream beat when the single upstream holding register is free.
  assign axi_m.rready  = (rs == R_MISS_R) || ((rs == R_BYPASS_R) && (!rs_rvalid || axi_s.rready));

  // ---------------------------------------------------------------------
  // Cache write port (drive on fill completion)
  // ---------------------------------------------------------------------
  logic cache_install;
  logic [IndexBits-1:0] install_idx;
  logic [TagBits-1:0] install_tag;

  // ---------------------------------------------------------------------
  // Posted Write Buffer (PWB)
  // ---------------------------------------------------------------------
  // Decouples upstream B from downstream B: the upstream master sees its
  // store complete as soon as AW+W are captured in the buffer, while the
  // drain engine pushes the store to memory in the background. This lets
  // the upstream bus pipeline its next AW/W against our skid instead of
  // stalling on memory roundtrip latency.
  //
  // Stores from rapt_bus are single-beat (axi.awlen==0), so each buffer
  // entry holds the whole transaction. A small B-id FIFO records the
  // upstream id ordering for posted-B emission, independent of the
  // downstream drain pointer.
  //
  // PPA: WbufDepth=2 -> ~180 FFs + a handful of pointers. Tiny.
  //
  // Future extensions (left as TODO comments below):
  //   - Write coalescing: on AW enqueue, scan buffer for same-line entries
  //     and merge wstrb into existing entry (saves a downstream beat).
  //   - Read MSHR: mirror this structure on the read side (multiple
  //     outstanding fills), today `r_*` is a single-entry placeholder.
  //   - L1D write-back path: dirty evicts enqueue here directly.
  localparam int WbufDepth = 2;
  localparam int WbufPtrW = $clog2(WbufDepth);
  localparam int WbufCntW = $clog2(WbufDepth + 1);

  typedef struct packed {
    logic              busy;   // slot in use (AW captured, not yet freed)
    logic              has_w;  // W beat captured -> slot drainable
    logic [XLEN-1:0]   addr;
    logic [ID_W-1:0]   id;
    logic [2:0]        size;
    logic [7:0]        len;    // 0 for single-beat stores from rapt_bus
    logic [1:0]        burst;
    logic [XLEN-1:0]   wdata;
    logic [XLEN/8-1:0] wstrb;
    logic              wlast;
    logic              posted;
    logic [WbufPtrW-1:0] rsp_slot;
  } wbuf_ent_t;

  wbuf_ent_t wbuf[WbufDepth];
  logic [WbufPtrW-1:0] aw_wptr;  // next AW capture slot
  logic [WbufPtrW-1:0] w_wptr;  // next W capture slot (trails aw_wptr)
  logic [WbufPtrW-1:0] d_rptr;  // drain head slot

  // Posted-B id FIFO (one id per W beat captured; consumed on upstream bready).
  logic [ID_W-1:0] b_id_q[WbufDepth];
  logic [1:0] b_resp_q[WbufDepth];
  logic b_ready_q[WbufDepth];
  logic [WbufPtrW-1:0] b_wptr;
  logic [WbufPtrW-1:0] b_rptr;
  logic [WbufCntW-1:0] b_count;
  logic bq_full;
  assign bq_full = (b_count == WbufCntW'(WbufDepth));

  // Any-busy: used to serialize reads vs all in-flight writes (AXI memory
  // models may reorder AR vs same- or other-line AW).
  logic any_write_in_flight;
  logic read_bypass_in_progress;
  assign any_write_in_flight = wbuf[0].busy || wbuf[1].busy;
  assign read_bypass_in_progress = (rs == R_BYPASS_WAIT) || (rs == R_BYPASS_AR)
                                 || (rs == R_BYPASS_R);

  // Snoop hit-merge: fires when a W beat is captured into wbuf[w_wptr].
  // The slot's AW addr was registered one cycle earlier, so derive snoop
  // index/tag/word from the slot directly.
  logic [XLEN-1:0] w_snoop_addr;
  logic [IndexBits-1:0] w_idx_q;
  logic [TagBits-1:0] w_tag_q;
  logic w_hit_q;
  logic [L2_LINE_LEN-1:0] w_word_now;
  logic w_full_strobe;
  assign w_snoop_addr = wbuf[w_wptr].addr;
  assign w_idx_q = w_snoop_addr[IndexMsb:IndexLsb];
  assign w_tag_q = w_snoop_addr[XLEN-1:TagLsb];
  assign w_hit_q = line_valid[0][w_idx_q] && (line_tag[0][w_idx_q] == w_tag_q);
  assign w_word_now = w_snoop_addr[WordOffsetMsb:WordOffsetLsb];
  assign w_full_strobe = &axi_s.wstrb;
  logic w_hit_update;

  generate
    for (genvar gi = 0; gi < LineSize; gi++) begin : gen_data_bank
      logic bank_store_wen;
      assign bank_store_wen = w_hit_update && w_full_strobe
                            && (w_word_now == L2_LINE_LEN'(gi));
      rapt_sram_1r1w #(
          .ADDR_WIDTH(L2_LEN),
          .DATA_WIDTH(XLEN),
          .INST_ID(200 + gi),
          .USE_BWE(0)
      ) u_data_sram (
          .bwe({(XLEN/8){1'b1}}),
          .clock(clock),
          .ren  (1'b1),
          .raddr(data_sram_raddr),
          .rdata(line_data_r[gi]),
          .wen  (cache_install || bank_store_wen),
          .waddr(cache_install ? install_idx : w_idx_q),
          .wdata(cache_install ? r_line_buf[gi] : axi_s.wdata)
      );
    end
  endgenerate

  // Drain FSM placed before the read FSM because read miss-issue
  // serializes against write activity to avoid AR/AW ordering races.
  typedef enum logic [1:0] {
    W_IDLE,
    W_AW,    // legacy slot -- unused with combinational AW drive; kept for clarity
    W_W,
    W_B
  } state_w_t;

  state_w_t ws;

  // ---------------------------------------------------------------------
  // Read FSM
  // ---------------------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      rs         <= R_IDLE;
      m_arvalid  <= 1'b0;
      rs_rvalid  <= 1'b0;
      rs_rlast   <= 1'b0;
      rs_rresp   <= 2'b00;
      rs_rid     <= '0;
      rs_rdata   <= '0;
      r_id       <= '0;
      r_addr     <= '0;
      r_len      <= '0;
      r_size     <= '0;
      r_burst    <= '0;
      r_word     <= '0;
      r_fill_cnt <= '0;
      r_resp     <= 2'b00;
      r_up_done  <= 1'b0;
      for (int i = 0; i < LineSize; i++) begin
        r_line_buf[i] <= '0;
      end
      cache_install <= 1'b0;
      install_idx   <= '0;
      install_tag   <= '0;
      for (int w = 0; w < L2_N_WAYS; w++) begin
        for (int s = 0; s < NSets; s++) begin
          line_valid[w][s] <= 1'b0;
          line_tag[w][s]   <= '0;
        end
      end
    end else begin
      // Default deassert of pulses
      cache_install <= 1'b0;
      // R-channel handshake: clear rvalid on accepted beat
      if (rs_rvalid && axi_s.rready) begin
        rs_rvalid <= 1'b0;
        rs_rlast  <= 1'b0;
      end
      // AR-channel handshake: clear m_arvalid when accepted
      if (m_arvalid && axi_m.arready) begin
        m_arvalid <= 1'b0;
      end

      unique case (rs)
        // -----------------------------------------------------------------
        R_IDLE: begin
          if (axi_s.arvalid && axi_s.arready) begin
            r_id    <= axi_s.arid;
            r_addr  <= axi_s.araddr;
            r_len   <= axi_s.arlen;
            r_size  <= axi_s.arsize;
            r_burst <= axi_s.arburst;
            r_word  <= axi_s.araddr[WordOffsetMsb:WordOffsetLsb];
            r_resp  <= 2'b00;
            if (cacheable(axi_s.araddr)) begin
              // Lookup is combinational on r_addr_next; but since we
              // sample on the same edge we must wait one cycle for
              // r_addr to be latched, then decide. Use a transient state:
              rs <= R_HIT;
            end else begin
              // Forward AR straight through.
              if (any_write_in_flight || axi_s.awvalid) begin
                rs <= R_BYPASS_WAIT;
              end else begin
                m_arvalid <= 1'b1;
                m_araddr  <= axi_s.araddr;
                m_arid    <= axi_s.arid;
                m_arlen   <= axi_s.arlen;
                m_arsize  <= axi_s.arsize;
                m_arburst <= axi_s.arburst;
                rs <= R_BYPASS_AR;
              end
            end
          end
        end

        // -----------------------------------------------------------------
        // Resolve hit / miss against the (now-latched) request.
        R_HIT: begin
          if (r_hit_q) begin
            // Drive next beat from cache. May take multiple cycles for
            // a burst -- we hold this state until the burst completes.
            if (!rs_rvalid || axi_s.rready) begin
              rs_rvalid <= 1'b1;
              rs_rdata  <= line_data_r[r_word];
              rs_rresp  <= 2'b00;
              rs_rid    <= r_id;
              rs_rlast  <= (r_len == 8'd0);
              // Advance address / counters
              if (r_len == 8'd0) begin
                rs <= R_IDLE;
              end else begin
                r_len  <= r_len - 8'd1;
                r_word <= r_word + 1'b1;
                r_addr <= r_addr + (XLEN / 8);
                // INCR burst that crosses a line boundary: re-lookup.
                // Detect: next-word overflows current line. Since
                // L2_LINE_LEN bits roll over to 0, just check.
                if (r_word == L2_LINE_LEN'(LineSize - 1)) begin
                  // Stay in R_HIT -- r_addr_q updates and re-evaluates
                  // r_hit_q automatically next cycle. If next line
                  // misses, the next-cycle branch below catches it.
                end
              end
            end
          end else begin
            // Miss: issue line-aligned fill burst.
            //
            // Read-after-write coherence: AXI does not order AR vs an
            // outstanding/incoming AW/W to the same line. Stall the
            // miss issue while ANY write is in the posted write buffer
            // (or arriving this cycle) to avoid memory-level reordering.
            //
            // We cover three races:
            //  1) An AW already captured in the buffer (any slot busy).
            //  2) AW is being accepted THIS cycle (axi_s.awvalid).
            //  3) Any write activity at all (worst-case fallback): the
            //     bus-level model may reorder AR vs AW for different
            //     addresses too, so be conservative.
            if (any_write_in_flight || axi_s.awvalid) begin
              // hold in R_HIT; re-evaluate next cycle
            end else begin
              r_fill_cnt <= '0;
              r_resp     <= 2'b00;
              r_up_done  <= 1'b0;
              m_arvalid  <= 1'b1;
              m_araddr   <= {r_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
              m_arid     <= r_id;
              m_arlen    <= 8'(LineSize - 1);
              m_arsize   <= 3'($clog2(WordBytes));
              m_arburst  <= 2'b01;  // INCR
              rs         <= R_MISS_AR;
            end
          end
        end

        // -----------------------------------------------------------------
        R_MISS_AR: begin
          if (!m_arvalid) begin
            rs <= R_MISS_R;
          end
        end

        // -----------------------------------------------------------------
        R_MISS_R: begin
          // Collect fill beats. Early-restart: forward the wanted word
          // (the beat indexed by r_word) the cycle it arrives, so the
          // upstream single-beat load completes before line install.
          // One-shot, gated to r_len==0 (L1D miss = single-beat).
          if (axi_m.rvalid) begin
            r_line_buf[r_fill_cnt] <= axi_m.rdata;
            if (axi_m.rresp != 2'b00) r_resp <= axi_m.rresp;
            r_fill_cnt <= r_fill_cnt + 1'b1;

            if (!r_up_done && (r_len == 8'd0)
                && (r_fill_cnt == r_word)
                && (axi_m.rresp == 2'b00) && (r_resp == 2'b00)
                && (!rs_rvalid || axi_s.rready)) begin
              rs_rvalid <= 1'b1;
              rs_rdata  <= axi_m.rdata;
              rs_rresp  <= 2'b00;
              rs_rid    <= r_id;
              rs_rlast  <= 1'b1;
              r_up_done <= 1'b1;
            end

            if (axi_m.rlast) begin
              // Install line (only if no bus error -- keep cache clean).
              if (axi_m.rresp == 2'b00 && r_resp == 2'b00) begin
                cache_install <= 1'b1;
                install_idx   <= r_idx_q;
                install_tag   <= r_tag_q;
              end
              if (r_up_done
                  || ((r_len == 8'd0) && (r_fill_cnt == r_word)
                      && (axi_m.rresp == 2'b00) && (r_resp == 2'b00)
                      && (!rs_rvalid || axi_s.rready))) begin
                rs <= R_IDLE;
              end else begin
                rs <= R_INSTALL_WAIT;  // allow SRAM install/read to settle
              end
            end
          end
        end

        // -----------------------------------------------------------------
        R_INSTALL_WAIT: begin
          // cache_install is a registered pulse asserted after the final fill
          // beat. Wait one cycle so tag/valid commit and the SRAM write-first
          // read for install_idx is visible before R_HIT consumes line_data_r.
          rs <= R_HIT;
        end

        // -----------------------------------------------------------------
        R_BYPASS_WAIT: begin
          if (!any_write_in_flight) begin
            m_arvalid <= 1'b1;
            m_araddr  <= r_addr;
            m_arid    <= r_id;
            m_arlen   <= r_len;
            m_arsize  <= r_size;
            m_arburst <= r_burst;
            rs <= R_BYPASS_AR;
          end
        end

        // -----------------------------------------------------------------
        R_BYPASS_AR: begin
          if (!m_arvalid) rs <= R_BYPASS_R;
        end

        // -----------------------------------------------------------------
        R_BYPASS_R: begin
          // Forward downstream R beats to upstream verbatim.
          if (axi_m.rvalid && (!rs_rvalid || axi_s.rready)) begin
            rs_rvalid <= 1'b1;
            rs_rdata  <= axi_m.rdata;
            rs_rresp  <= axi_m.rresp;
            rs_rid    <= axi_m.rid;
            rs_rlast  <= axi_m.rlast;
            if (axi_m.rlast) rs <= R_IDLE;
          end
        end

        default: rs <= R_IDLE;
      endcase

      // ---------------------------------------------------------------
      // Cache install (write port on fill completion)
      // ---------------------------------------------------------------
      if (cache_install) begin
        line_valid[0][install_idx] <= 1'b1;
        line_tag[0][install_idx]   <= install_tag;
      end

      // ---------------------------------------------------------------
      // Write-through hit update (snoop). Full-word stores update the SRAM
      // bank directly. Partial stores invalidate the L2 line instead of
      // requiring a second read/modify/write port; the write still drains to
      // memory, and later reads miss/refill after write-buffer serialization.
      // ---------------------------------------------------------------
      if (w_hit_update && !w_full_strobe) begin
        line_valid[0][w_idx_q] <= 1'b0;
      end
    end
  end

  // =====================================================================
  // WRITE PATH (write-through, no write-allocate, posted writes)
  // =====================================================================
  // Posted Write Buffer architecture: upstream AW/W capture into wbuf[]
  // and upstream B is returned as soon as the W beat lands. A separate
  // drain engine pushes the head of wbuf[] to memory in the background.

  // ---- Snoop hit/update (fires same cycle as W capture) ----
  always_comb begin
    w_hit_update = 1'b0;
    if (axi_s.wvalid && axi_s.wready && cacheable(w_snoop_addr) && w_hit_q) begin
      w_hit_update = 1'b1;
    end
  end

  // ---- Upstream (slave) handshakes ----
  // AW: accept when the target wbuf slot is empty AND not a same-line
  // race against an in-flight fill (AR/AW reordering hazard).
  logic l2_fill_in_progress;
  logic l2_aw_same_line;
  assign l2_fill_in_progress = (rs == R_MISS_AR) || (rs == R_MISS_R);
  assign l2_aw_same_line = (axi_s.awaddr[XLEN-1:OffsetBits] == r_addr[XLEN-1:OffsetBits]);
  assign axi_s.awready = !wbuf[aw_wptr].busy && !bq_full && !read_bypass_in_progress
                       && !(l2_fill_in_progress && l2_aw_same_line);

  // W: accept when the W-target slot has an AW captured but no W yet.
  // (For single-beat stores w_wptr always points at the right slot.)
  logic wbuf_w_pending;
  assign wbuf_w_pending = wbuf[w_wptr].busy && !wbuf[w_wptr].has_w;
  assign axi_s.wready = wbuf_w_pending && !cache_install;

  // B: cacheable main-memory writes are posted; non-cacheable writes wait for
  // the real downstream B so CSR/MMIO polling remains strictly ordered.
  assign axi_s.bvalid = (b_count != 0) && b_ready_q[b_rptr];
  assign axi_s.bid    = b_id_q[b_rptr];
  assign axi_s.bresp  = b_resp_q[b_rptr];

  // ---- Downstream (master) drives ----
  // AW/W issued combinationally from the drain head. axi_m.awvalid is
  // gated on ws==W_IDLE (no AW in flight) AND head ready.
  assign axi_m.awvalid = (ws == W_IDLE)
                         && wbuf[d_rptr].busy
                         && wbuf[d_rptr].has_w;
  assign axi_m.awaddr  = wbuf[d_rptr].addr;
  assign axi_m.awid    = wbuf[d_rptr].id;
  assign axi_m.awlen   = wbuf[d_rptr].len;
  assign axi_m.awsize  = wbuf[d_rptr].size;
  assign axi_m.awburst = wbuf[d_rptr].burst;

  assign axi_m.wvalid  = (ws == W_W);
  assign axi_m.wdata   = wbuf[d_rptr].wdata;
  assign axi_m.wstrb   = wbuf[d_rptr].wstrb;
  assign axi_m.wlast   = wbuf[d_rptr].wlast;

  assign axi_m.bready  = (ws == W_B);

  // ---- Combined capture + drain FSM ----
  always_ff @(posedge clock) begin
    if (reset) begin
      ws      <= W_IDLE;
      aw_wptr <= '0;
      w_wptr  <= '0;
      d_rptr  <= '0;
      b_wptr  <= '0;
      b_rptr  <= '0;
      b_count <= '0;
      for (int i = 0; i < WbufDepth; i++) begin
        wbuf[i].busy  <= 1'b0;
        wbuf[i].has_w <= 1'b0;
        wbuf[i].addr  <= '0;
        wbuf[i].id    <= '0;
        wbuf[i].size  <= '0;
        wbuf[i].len   <= '0;
        wbuf[i].burst <= '0;
        wbuf[i].wdata <= '0;
        wbuf[i].wstrb <= '0;
        wbuf[i].wlast <= 1'b0;
        wbuf[i].posted <= 1'b0;
        wbuf[i].rsp_slot <= '0;
        b_id_q[i]     <= '0;
        b_resp_q[i]   <= 2'b00;
        b_ready_q[i]  <= 1'b0;
      end
    end else begin
      // ---- Drain side (free a slot when downstream B returns) ----
      unique case (ws)
        W_IDLE: begin
          // axi_m.awvalid is combinational; transition when accepted.
          if (axi_m.awvalid && axi_m.awready) ws <= W_W;
        end
        W_W: begin
          if (axi_m.wready) ws <= W_B;
        end
        W_B: begin
          if (axi_m.bvalid) begin
            if (!wbuf[d_rptr].posted) begin
              b_ready_q[wbuf[d_rptr].rsp_slot] <= 1'b1;
              b_resp_q [wbuf[d_rptr].rsp_slot] <= axi_m.bresp;
            end
            wbuf[d_rptr].busy  <= 1'b0;
            wbuf[d_rptr].has_w <= 1'b0;
            d_rptr             <= (d_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (d_rptr + 1'b1);
            ws                 <= W_IDLE;
          end
        end
        default: ws <= W_IDLE;
      endcase

      // ---- AW capture (slave) ----
      // Order matters: AW capture is after drain-free so that on the
      // wraparound cycle (drain freeing slot S while a new AW also
      // targets slot S because aw_wptr == d_rptr), the AW capture wins
      // and the slot is immediately re-used. NBA semantics preserved.
      if (axi_s.awvalid && axi_s.awready) begin
        wbuf[aw_wptr].busy  <= 1'b1;
        wbuf[aw_wptr].has_w <= 1'b0;
        wbuf[aw_wptr].addr  <= axi_s.awaddr;
        wbuf[aw_wptr].id    <= axi_s.awid;
        wbuf[aw_wptr].size  <= axi_s.awsize;
        wbuf[aw_wptr].len   <= axi_s.awlen;
        wbuf[aw_wptr].burst <= axi_s.awburst;
        wbuf[aw_wptr].posted <= cacheable(axi_s.awaddr);
        // TODO(coalesce): if wbuf[*] has a busy entry to the same line
        // with !has_drained_yet, we could merge wstrb into it and skip
        // the enqueue. Saves a downstream beat for adjacent stores.
        aw_wptr             <= (aw_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (aw_wptr + 1'b1);
      end

      // ---- W capture (slave) ----
      if (axi_s.wvalid && axi_s.wready) begin
        wbuf[w_wptr].wdata <= axi_s.wdata;
        wbuf[w_wptr].wstrb <= axi_s.wstrb;
        wbuf[w_wptr].wlast <= axi_s.wlast;
        if (axi_s.wlast) begin
          wbuf[w_wptr].has_w <= 1'b1;
          wbuf[w_wptr].rsp_slot <= b_wptr;
          w_wptr             <= (w_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (w_wptr + 1'b1);
          // Enqueue upstream B in write order. Cacheable writes are ready
          // immediately; non-cacheable writes become ready on downstream B.
          b_id_q[b_wptr]     <= wbuf[w_wptr].id;
          b_resp_q[b_wptr]   <= 2'b00;
          b_ready_q[b_wptr]  <= wbuf[w_wptr].posted;
          b_wptr             <= (b_wptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (b_wptr + 1'b1);
        end
      end

      // ---- Upstream B consume ----
      if (axi_s.bvalid && axi_s.bready) begin
        b_ready_q[b_rptr] <= 1'b0;
        b_resp_q [b_rptr] <= 2'b00;
        b_rptr <= (b_rptr == WbufPtrW'(WbufDepth - 1)) ? '0 : (b_rptr + 1'b1);
      end

      // ---- B credit counter ----
      // Net delta: +1 on W-beat last capture, -1 on upstream B handshake.
      b_count <= b_count
                 + WbufCntW'((axi_s.wvalid && axi_s.wready && axi_s.wlast) ? 1 : 0)
                 - WbufCntW'((axi_s.bvalid && axi_s.bready) ? 1 : 0);
    end
  end

`endif  // RAPT_L2_ACTIVE

// Scope the helper define to this module so it does not leak into other
// translation-unit files in single-unit Verilator/Yosys compilation.
`ifdef RAPT_L2_ACTIVE
`undef RAPT_L2_ACTIVE
`endif

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
