`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

module rapt_bus #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    // AXI4 Master bus
    axi4_if.master axi,

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    csr_bcast_if.in csr_bcast,
    cmu_bcast_if.in cmu_bcast,

    input reset
);
  typedef enum logic [1:0] {
    LS_S_A = 0,
    LS_S_W = 1,
    LS_S_B = 2
  } state_store_t;
  typedef enum logic [3:0] {
    L1I  = 1,
    L1D  = 2,
    TLBI = 3,
    TLBD = 4
  } state_lds_t;  // load source

  logic write_done;

  logic [3:0] awid;

  state_store_t state_store;
  state_lds_t store_bridge;
  state_lds_t store_source;
  state_lds_t store_current;

  assign axi.awburst = 0;
  assign axi.awlen = 0;
  assign axi.awid = (state_store == LS_S_A) ? store_bridge : awid;

  assign store_bridge = l1i_bus.awvalid ? L1I : L1D;
  assign store_current = (state_store == LS_S_A) ? store_bridge : store_source;

`ifndef RAPT_SOC
  // =========================================================================
  // Multi-outstanding read AR pipeline.
  //
  // The bus exposes two independent AR slots so L1I and L1D can have ARs in
  // flight simultaneously. The downstream router/SoC handle multi-outstanding
  // responses via `axi.rid`; per-master rvalid de-mux is already by rid below.
  //
  //   - L1I slot: 2-deep FIFO. The L1I miss FSM (rapt_l1i.sv RD_0->RD_1)
  //     issues two sequential ARs gated only on `l1i_bus.rready` pulses, so
  //     the bus must accept both back-to-back without waiting for the first
  //     response. (A 1-deep slot drops the second AR -- see
  //     /memories/repo/rapt-router-multi-outstanding-2026-05-04.md.)
  //   - L1D slot: 1-deep, held until the response's `rlast` so the captured
  //     `l1d_load_is_mmio` flag stays valid across the round trip.
  //
  //   - `*_bus.rready` pulses for one cycle on FIFO push: this preserves the
  //     master-side "AR accepted, advance" semantic that the L1I FSM relies on.
  //
  //   - Arbiter: L1D priority over L1I (matches the original FSM order).
  //     Downstream AR is registered/stable until `axi.arready`.
  // =========================================================================
  localparam int L1iARDepth = 2;

  // L1I AR FIFO (depth 2)
  logic [XLEN-1:0] l1i_q_addr                                     [L1iARDepth];
  logic            l1i_q_burst                                    [L1iARDepth];
  logic            l1i_q_rdptr;  // 1-bit index into depth-2 array
  logic            l1i_q_wrptr;
  logic [     1:0] l1i_q_cnt;
  logic l1i_q_full, l1i_q_empty;
  assign l1i_q_full  = (l1i_q_cnt == 2'(L1iARDepth));
  assign l1i_q_empty = (l1i_q_cnt == 2'd0);

  // L1D AR slot. Lifetime: capture .. R-rlast (so difftest_skip stays valid).
  logic            l1d_slot_busy;  // pending: AR accepted or in flight or awaiting R
  logic            l1d_slot_issued;  // AR has been handed to downstream
  logic [XLEN-1:0] l1d_slot_addr;
  logic [     2:0] l1d_slot_size;
  logic            l1d_slot_mmio;

  // Master-side capture handshakes (each pulses *_bus.rready for one cycle).
  //
  // The L1I bus does not expose an arready back to the masters (L1I refill FSM
  // and PTW share `l1i_bus.arvalid`). Both masters hold arvalid high until they
  // observe a response, so a naive `arvalid && !full` push will FIFO the same
  // address multiple times -- causing the slave to deliver duplicate rvalid
  // beats that downstream consumers (PTW) interpret as later-level PTE results
  // (see /memories/session/ptw-multi-outstanding-stale-rvalid.md). Gate the
  // push to one capture per (arvalid window, araddr) pair using a "captured"
  // flag + last-pushed-address register.
  logic l1i_push, l1d_push;
  logic l1i_captured;
  logic [XLEN-1:0] l1i_last_push_addr;
  wire l1i_new_request = !l1i_captured || (l1i_bus.araddr != l1i_last_push_addr);
  assign l1i_push       = l1i_bus.arvalid && !l1i_q_full && l1i_new_request;
  assign l1d_push       = l1d_bus.arvalid && !l1d_slot_busy;
  assign l1i_bus.rready = l1i_push;
  assign l1d_bus.rready = l1d_push;

  // Downstream issue arbiter (L1D priority).
  // (The RAPT_SOC variant uses the legacy single-outstanding FSM further down
  // and does not reach this point -- see the `\`else` branch.)
  logic issue_l1d, issue_l1i;
  assign issue_l1d = l1d_slot_busy && !l1d_slot_issued;
  assign issue_l1i = !issue_l1d && !l1i_q_empty;

  logic [XLEN-1:0] l1i_q_head_addr;
  logic            l1i_q_head_burst;
  assign l1i_q_head_addr = l1i_q_addr[l1i_q_rdptr];
  assign l1i_q_head_burst = l1i_q_burst[l1i_q_rdptr];

  // ifu read demux
  assign l1i_bus.rdata = axi.rdata;
  assign l1i_bus.rvalid = (axi.rid == L1I) && axi.rvalid;
  assign l1i_bus.rlast = (axi.rid == L1I) && axi.rlast;
  assign l1i_bus.rerr = (axi.rid == L1I) && axi.rvalid && (axi.rresp != 2'b00);
  assign l1i_bus.wready = (store_source == L1I) && axi.bvalid;
  assign l1i_bus.werr = (store_source == L1I) && axi.bvalid && (axi.bresp != 2'b00);

  // lsu read demux
  // Gate L1D response by slot_issued: do NOT forward axi.rvalid to L1D until
  // our AR has been handed to the slave. This prevents accepting stale
  // responses (e.g. ysyxSoC `sdram_axi` response-FIFO mis-sync) that arrive
  // before our request has been issued.
  assign l1d_bus.rdata = axi.rdata;
  assign l1d_bus.rvalid = l1d_slot_issued && (axi.rid == L1D) && axi.rvalid;
  assign l1d_bus.difftest_skip = l1d_slot_busy && l1d_slot_mmio;
  assign l1d_bus.rerr = l1d_slot_issued && (axi.rid == L1D) && axi.rvalid && (axi.rresp != 2'b00);

  // Downstream AR drive (combinational; backed by registered slot/queue).
  assign axi.arvalid = issue_l1d || issue_l1i;
  assign axi.arid = issue_l1d ? 4'(L1D) : 4'(L1I);
  assign axi.araddr = issue_l1d ? l1d_slot_addr : l1i_q_head_addr;
  assign axi.arsize = issue_l1d ? l1d_slot_size : 3'b010;  // L1I: 4-byte
  assign axi.arburst = (issue_l1i && l1i_q_head_burst) ? 2'b01 : 2'b00;
  assign axi.arlen = (issue_l1i && l1i_q_head_burst) ? 8'h1 : 8'h0;
  assign axi.rready = 1'b1;

  // L1D arsize from rstrb (matches original encoding).
  logic [2:0] l1d_arsize_enc;
  assign l1d_arsize_enc =
      ({3{l1d_bus.rstrb == 8'h01}} & 3'b000) |
      ({3{l1d_bus.rstrb == 8'h03}} & 3'b001) |
      ({3{l1d_bus.rstrb == 8'h0f}} & 3'b010) |
      ({3{l1d_bus.rstrb == 8'hff}} & 3'b011);

  always_ff @(posedge clock) begin
    if (reset) begin
      l1i_q_rdptr <= 1'b0;
      l1i_q_wrptr <= 1'b0;
      l1i_q_cnt   <= '0;
      for (int i = 0; i < L1iARDepth; i++) begin
        l1i_q_addr[i]  <= '0;
        l1i_q_burst[i] <= 1'b0;
      end
      l1i_captured       <= 1'b0;
      l1i_last_push_addr <= '0;
      l1d_slot_busy      <= 1'b0;
      l1d_slot_issued    <= 1'b0;
      l1d_slot_addr      <= '0;
      l1d_slot_size      <= 3'b000;
      l1d_slot_mmio      <= 1'b0;
    end else begin
      // L1I FIFO: push on capture, pop on downstream AR handshake.
      automatic logic l1i_pop;
      l1i_pop = issue_l1i && axi.arready;
      if (l1i_push) begin
        l1i_q_addr[l1i_q_wrptr]  <= l1i_bus.araddr;
        l1i_q_burst[l1i_q_wrptr] <= l1i_bus.arburst;
        l1i_q_wrptr              <= ~l1i_q_wrptr;
        l1i_captured             <= 1'b1;
        l1i_last_push_addr       <= l1i_bus.araddr;
      end else if (!l1i_bus.arvalid) begin
        // arvalid dropped -> window closed; reopen capture window.
        l1i_captured <= 1'b0;
      end
      if (l1i_pop) begin
        l1i_q_rdptr <= ~l1i_q_rdptr;
      end
      // Combined count update: handles same-cycle push+pop.
      unique case ({
        l1i_push, l1i_pop
      })
        2'b10:   l1i_q_cnt <= l1i_q_cnt + 2'd1;
        2'b01:   l1i_q_cnt <= l1i_q_cnt - 2'd1;
        default: l1i_q_cnt <= l1i_q_cnt;
      endcase

      // L1D slot: capture, mark issued on AR handshake, free on rlast.
      if (l1d_push) begin
        l1d_slot_busy   <= 1'b1;
        l1d_slot_issued <= 1'b0;
        l1d_slot_addr   <= l1d_bus.araddr;
        l1d_slot_size   <= l1d_arsize_enc;
        l1d_slot_mmio   <= rapt_pkg::addr_mmio(l1d_bus.araddr);
      end
      if (issue_l1d && axi.arready) begin
        l1d_slot_issued <= 1'b1;
      end
      if (l1d_slot_busy && l1d_slot_issued && axi.rvalid && axi.rlast && (axi.rid == 4'(L1D))) begin
        l1d_slot_busy   <= 1'b0;
        l1d_slot_issued <= 1'b0;
        l1d_slot_mmio   <= 1'b0;
      end
    end
  end

`else  // RAPT_SOC: legacy single-outstanding FSM (third-party ysyxSoC
       // sdram_axi controller does not tolerate multi-outstanding ARs).
  typedef enum logic [2:0] {
    LD_A,
    LD_AS,
    LD_D
  } state_load_t;

  logic [3:0] arid;
  logic [XLEN-1:0] bus_araddr;
  logic arburst;
  logic [2:0] arsize;
  logic l1d_load_is_mmio;

  state_load_t state_load;
  state_lds_t state_load_source;
  state_lds_t load_bridge;

  assign axi.arid = arid;
  assign load_bridge = l1d_bus.arvalid ? L1D : L1I;

  assign l1i_bus.rready = (state_load == LD_A && load_bridge == L1I);
  assign l1i_bus.rdata = axi.rdata;
  assign l1i_bus.rvalid = (axi.rid == L1I) && axi.rvalid;
  assign l1i_bus.rlast = (axi.rid == L1I) && axi.rlast;
  assign l1i_bus.rerr = (axi.rid == L1I) && axi.rvalid && (axi.rresp != 2'b00);
  assign l1i_bus.wready = (store_source == L1I) && axi.bvalid;
  assign l1i_bus.werr = (store_source == L1I) && axi.bvalid && (axi.bresp != 2'b00);

  assign l1d_bus.rready = (state_load == LD_A && load_bridge == L1D);
  assign l1d_bus.rdata = axi.rdata;
  assign l1d_bus.rvalid = (axi.rid == L1D) && axi.rvalid;
  assign l1d_bus.difftest_skip = l1d_load_is_mmio;
  assign l1d_bus.rerr = (axi.rid == L1D) && axi.rvalid && (axi.rresp != 2'b00);

  assign axi.arburst = arburst ? 2'b01 : 2'b00;
  assign axi.arsize = arsize;
  assign axi.arlen = arburst ? 8'h1 : 8'h0;
  assign axi.araddr = bus_araddr;
  assign axi.arvalid = (state_load == LD_AS);
  assign axi.rready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_load <= LD_A;
      l1d_load_is_mmio <= 1'b0;
      arsize <= 3'b000;
      arburst <= 1'b0;
      bus_araddr <= '0;
      arid <= '0;
      state_load_source <= L1I;
    end else begin
      unique case (state_load)
        LD_A: begin
          if (l1d_bus.arvalid) begin
            state_load <= LD_AS;
            bus_araddr <= l1d_bus.araddr;
            arid <= L1D;
            state_load_source <= L1D;
            l1d_load_is_mmio <= rapt_pkg::addr_mmio(l1d_bus.araddr);
            arsize <= (
              ({3{l1d_bus.rstrb == 8'h1}} & 3'b000) |
              ({3{l1d_bus.rstrb == 8'h3}} & 3'b001) |
              ({3{l1d_bus.rstrb == 8'hf}} & 3'b010) |
              ({3{l1d_bus.rstrb == 8'hff}} & 3'b011) |
              (3'b000)
            );
          end else if (l1i_bus.arvalid) begin
            bus_araddr <= l1i_bus.araddr;
            state_load <= LD_AS;
            arburst <= l1i_bus.arburst;
            arid <= L1I;
            arsize <= 3'b010;
            state_load_source <= L1I;
          end
        end
        LD_AS: begin
          if (axi.arready) begin
            state_load <= LD_D;
            arburst <= 1'b0;
            bus_araddr <= '0;
          end
        end
        LD_D: begin
          if (axi.rvalid && axi.rlast) begin
            state_load <= LD_A;
            arburst <= 1'b0;
            bus_araddr <= '0;
            l1d_load_is_mmio <= 1'b0;
          end
        end
        default: state_load <= LD_A;
      endcase
    end
  end
`endif  // RAPT_SOC

  logic [XLEN-1:0] store_awaddr;
  logic [XLEN-1:0] store_wdata;
  logic [7:0] store_wstrb_aw;
  logic [XLEN/8-1:0] store_wstrb;
  logic store_awvalid;
  logic store_wvalid;

  assign store_awaddr = (store_bridge == L1I) ? l1i_bus.awaddr : l1d_bus.awaddr;
  assign store_wdata = (store_current == L1I) ? l1i_bus.wdata : l1d_bus.wdata;
  assign store_wstrb_aw = (store_bridge == L1I) ? l1i_bus.wstrb : l1d_bus.wstrb;
  assign store_wstrb = (store_current == L1I) ? l1i_bus.wstrb[XLEN/8-1:0]
                                               : l1d_bus.wstrb[XLEN/8-1:0];
  assign store_awvalid = (store_bridge == L1I) ? l1i_bus.awvalid : l1d_bus.awvalid;
  assign store_wvalid = (store_current == L1I) ? l1i_bus.wvalid : l1d_bus.wvalid;

  // lsu/IPTW write
  assign l1d_bus.wready = (store_source == L1D) && axi.bvalid;

  assign axi.awsize = store_awvalid
    ? (({3{store_wstrb_aw == 8'h1}} & 3'b000)
      |({3{store_wstrb_aw == 8'h3}} & 3'b001)
      |({3{store_wstrb_aw == 8'hf}} & 3'b010)
      |({3{store_wstrb_aw == 8'hff}} & 3'b011))
    : 3'b000;
  assign axi.awaddr = store_awvalid ? store_awaddr : 'h0;
  assign axi.awvalid = (state_store == LS_S_A) && store_awvalid;

  localparam logic [31:0] ADDR2BITS = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  logic [ADDR2BITS-1:0] awaddr_lo;
  assign awaddr_lo = axi.awaddr[ADDR2BITS-1:0];
  assign axi.wdata = store_wdata << (awaddr_lo * 8);
  assign axi.wvalid = store_wvalid && !write_done;
  assign axi.wlast = axi.wvalid && axi.wready;
  assign axi.wstrb = store_wstrb << awaddr_lo;

  assign axi.bready = (state_store == LS_S_W);
  // Bus error on write response. Stores reaching the bus have already
  // passed bare-mode PMA / MMU PMP checks, so a runtime werr is a configuration
  // hazard -- surface it for waves but do not break the existing handshake
  // contract back to LSU (no per-store trap path on the write side today).
  assign l1d_bus.werr = (store_source == L1D) && axi.bvalid && (axi.bresp != 2'b00);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
      write_done <= 0;
      awid <= 'h1;
      store_source <= L1D;
    end else begin
      unique case (state_store)
        LS_S_A: begin
          if (store_awvalid && axi.awready) begin
            store_source <= store_bridge;
            awid <= store_bridge;
            state_store <= LS_S_W;
            if (axi.wready) begin
              write_done <= 1;
            end else begin
              write_done <= 0;
            end
          end
        end
        LS_S_W: begin
          if (axi.bvalid) begin
            state_store <= LS_S_A;
            write_done  <= 0;
          end else if (axi.wready) begin
            write_done <= 1;
          end
        end
        default: state_store <= LS_S_A;
      endcase
    end
  end

  // SVA: stores leaving the core must already have been screened by PMA / PMP
  // checks. A non-OKAY bresp on a committed store flags either a SoC decoder
  // misconfiguration or a PMA / SoC memory-map drift. Use the central SVA macro
  // so this check is completely absent from FPGA/ASIC synthesis.
  `RAPT_SVA_IMPLY(clock, reset, BUS_STORE_BRESP_OK, axi.bvalid, axi.bresp == 2'b00)

endmodule
