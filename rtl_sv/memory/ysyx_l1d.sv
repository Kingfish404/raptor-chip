`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_l1d #(
    parameter bit [`YSYX_L1D_LEN:0] L1D_LINE_LEN = `YSYX_L1D_LINE_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_LINE_SIZE = 2 ** L1D_LINE_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** `YSYX_L1D_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.slave  lsu_l1d,
    l1d_bus_if.master l1d_bus,

    csr_bcast_if.in csr_bcast,
    exu_l1d_if.slave exu_l1d,
    rou_cmu_if.in rou_cmu,

    input reset
);
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP   = 3'b101,
    LD_A   = 3'b001,
    LD_D   = 3'b010
  } l1d_state_t;

  l1d_state_t l1d_state;

  logic [XLEN-1:0] l1d_addr;
  logic [4:0] l1d_ralu;
  logic [XLEN-1:0] rec_addr;

  // Tag and valid arrays (kept as registers for multi-port read and fast bulk invalidation)
  // Per-word valid: each word in a cache line has independent valid tracking
  localparam OFFSET_BITS = $clog2(XLEN/8);  // 2 for RV32, 3 for RV64
  localparam L1D_TAG_W = XLEN - L1D_LEN - L1D_LINE_LEN - OFFSET_BITS;
  logic [L1D_LINE_SIZE-1:0] l1d_valid[L1D_SIZE];
  logic [L1D_TAG_W-1:0] l1d_tag[L1D_SIZE][L1D_LINE_SIZE];
  logic [7:0] rstrb;

  logic [L1D_TAG_W-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic [L1D_LINE_LEN-1:0] addr_offset;
  logic tag_hit;   // tag comparison result (combinational, from register arrays)
  logic data_hit;  // SRAM data ready after 1-cycle read latency
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [L1D_TAG_W-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic [L1D_LINE_LEN-1:0] waddr_offset;
  logic hit_w;

  logic mmu_en;
  logic tlb_hit;
  logic [XLEN-1:10] dtlb_ptag;

  logic stlb_mmu;  // PTW was started for a store (vs load)
  logic stlb_hit;
  logic [XLEN-1:10] dstlb_ptag;

  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] store_paddr;

  // atomic support
  logic [XLEN-1:0] reservation;

  // PTW instance signals
  logic ptw_req;
  /* verilator lint_off UNUSEDSIGNAL */
  logic ptw_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic ptw_done, ptw_fault;
  logic ptw_arvalid;
  logic [XLEN-1:0] ptw_araddr;
  logic [XLEN-1:0] ptw_vaddr;
  logic [XLEN-1:10] ptw_result_ptag;
  logic [XLEN-1:12] ptw_result_vtag;

  // mis-alignment check
  logic mis_align_load;
  logic mis_align_store;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [L1D_TAG_W-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;
  logic [L1D_LINE_LEN-1:0] l1d_off;

  // Read-Modify-Write (RMW) for partial store cache updates.
  // When a partial store (SB/SH, or SW in RV64) hits in cache, instead of
  // invalidating, we read the old SRAM word, merge in the new bytes, and
  // write back the full merged word. This takes 2 cycles:
  //   Cycle N:   detect hit, steer sram_raddr to store's set, register store info
  //   Cycle N+1: SRAM data available, compute merge, set l1d_update for write
  logic l1d_rmw;
  logic [XLEN-1:0] l1d_rmw_wdata;
  logic [OFFSET_BITS-1:0] l1d_rmw_waddr_lo;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0] l1d_rmw_walu;
  /* verilator lint_on UNUSEDSIGNAL */

  // RMW trigger: partial store that hits in cache, SRAM read port is free.
  // Only allowed in IDLE (with no pending load) to avoid corrupting the
  // speculative SRAM read that feeds the LD_A hit path.  In PTWAIT/LD_D
  // the SRAM read port may be redirected, and if the FSM transitions to
  // LD_A on the same cycle, data_bank_rdata would contain the store's set
  // data instead of the load's — causing silent data corruption.
  logic partial_store_rmw;
  logic load_speculate;
  assign load_speculate = (l1d_state == IDLE && lsu_l1d.rvalid && !cmu_bcast.flush_pipe);
  assign partial_store_rmw = !l1d_rmw && !l1d_update
      && (l1d_state == IDLE)  // Only in IDLE; PTWAIT/LD_D would steal read port
      && !load_speculate      // load speculation uses SRAM read port
      && lsu_l1d.wvalid && l1d_bus.wready && cacheable_w && hit_w
`ifdef YSYX_RV64
      && (lsu_l1d.walu != `YSYX_SD_WSTRB);
`else
      && (lsu_l1d.walu != `YSYX_SW_WSTRB);
`endif

  // Speculative SRAM read: when IDLE with a pending load, drive the *incoming*
  // virtual index directly instead of waiting for l1d_addr to be registered.
  // Safe because L1D_LEN+L1D_LINE_LEN+OFFSET_BITS < 12 (page offset), so
  // virt_idx == phys_idx (VIPT constraint satisfied). PTW paths are also safe:
  // l1d_addr holds the virtual address during PTW, whose index equals the
  // final physical index.
  logic [L1D_LEN-1:0] sram_raddr;
  assign sram_raddr = partial_store_rmw ? waddr_idx
      : load_speculate
      ? lsu_l1d.raddr[L1D_LEN+L1D_LINE_LEN+OFFSET_BITS-1:L1D_LINE_LEN+OFFSET_BITS]
      : addr_idx;

  // Data SRAM banks — one bank per word position in cache line
  logic [XLEN-1:0] data_bank_rdata[L1D_LINE_SIZE];
  generate
    for (genvar gi = 0; gi < L1D_LINE_SIZE; gi++) begin : gen_data_bank
      ysyx_sram_1r1w #(
          .ADDR_WIDTH(L1D_LEN),
          .DATA_WIDTH(XLEN)
      ) u_data_sram (
          .clock(clock),
          .ren  (1'b1),
          .raddr(sram_raddr),
          .rdata(data_bank_rdata[gi]),
          .wen  (l1d_update && (l1d_off == gi[L1D_LINE_LEN-1:0])),
          .waddr(l1d_idx),
          .wdata(l1d_data_u)
      );
    end
  endgenerate

  // Partial store RMW merge logic: byte-lane merge of old SRAM data with new store data
  logic [XLEN/8-1:0] rmw_byte_mask;
  logic [XLEN-1:0] rmw_bit_mask;
  logic [XLEN-1:0] rmw_data_shifted;
  logic [XLEN-1:0] rmw_merged_data;

`ifdef YSYX_RV64
  assign rmw_byte_mask = {3'b0, l1d_rmw_walu[4:0]} << l1d_rmw_waddr_lo;
`else
  assign rmw_byte_mask = l1d_rmw_walu[3:0] << l1d_rmw_waddr_lo;
`endif
  always_comb begin
    for (int i = 0; i < XLEN/8; i++) begin
      rmw_bit_mask[i*8 +: 8] = {8{rmw_byte_mask[i]}};
    end
  end
  assign rmw_data_shifted = l1d_rmw_wdata << (l1d_rmw_waddr_lo * 8);
  assign rmw_merged_data = (data_bank_rdata[l1d_off] & ~rmw_bit_mask)
                         | (rmw_data_shifted & rmw_bit_mask);

  assign mmu_en = csr_bcast.dmmu_en;

  // Load/Store TLB fill — from shared PTW, only while PTWAIT is active
  logic dtlb_fill, dstlb_fill;
  assign dtlb_fill  = (l1d_state == PTWAIT) && ptw_done && !stlb_mmu;
  assign dstlb_fill = (l1d_state == PTWAIT) && ptw_done &&  stlb_mmu;

  ysyx_tlb #(.XLEN(XLEN)) u_dtlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(lsu_l1d.raddr[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(tlb_hit),
      .ptag(dtlb_ptag),
      .fill_valid(dtlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid)
  );

  ysyx_tlb #(.XLEN(XLEN)) u_dstlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(exu_l1d.vaddr[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(stlb_hit),
      .ptag(dstlb_ptag),
      .fill_valid(dstlb_fill),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid)
  );

  // Shared PTW — serves both load and store TLB misses
  wire store_tlb_miss = exu_l1d.mmu_en && exu_l1d.valid && !stlb_hit && !mis_align_store;
  assign ptw_vaddr = store_tlb_miss ? exu_l1d.vaddr : lsu_l1d.raddr;

  wire load_tlb_miss = lsu_l1d.rvalid && !tlb_hit && !mis_align_load
      && !(exu_l1d.mmu_en && exu_l1d.valid);
  assign ptw_req = (l1d_state == IDLE) && mmu_en && !cmu_bcast.flush_pipe
      && !ptw_busy
      && (store_tlb_miss || load_tlb_miss);

  ysyx_ptw #(.XLEN(XLEN)) u_dptw (
      .clock(clock),
      .reset(reset),
      .req_valid(ptw_req),
      .vaddr(ptw_vaddr),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(mmu_en),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_rvalid(l1d_bus.rvalid),
      .bus_rdata(l1d_bus.rdata),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .busy(ptw_busy)
  );

  assign rstrb = (
      ({8{l1d_ralu == `YSYX_ALU_LB__}} & 8'h1)
    | ({8{l1d_ralu == `YSYX_ALU_LBU_}} & 8'h1)
    | ({8{l1d_ralu == `YSYX_ALU_LH__}} & 8'h3)
    | ({8{l1d_ralu == `YSYX_ALU_LHU_}} & 8'h3)
    | ({8{l1d_ralu == `YSYX_ALU_LW__}} & 8'hf)
`ifdef YSYX_RV64
    | ({8{l1d_ralu == `YSYX_ALU_LWU_}} & 8'hf)
    | ({8{l1d_ralu == `YSYX_ALU_LD__}} & 8'hff)
`endif
    );

  assign addr_tag = l1d_addr[XLEN-1:L1D_LEN+L1D_LINE_LEN+OFFSET_BITS];
  assign addr_idx = l1d_addr[L1D_LEN+L1D_LINE_LEN+OFFSET_BITS-1:L1D_LINE_LEN+OFFSET_BITS];
  assign addr_offset = l1d_addr[L1D_LINE_LEN+OFFSET_BITS-1:OFFSET_BITS];

  // tag_hit: combinational tag match in LD_A (per-word tags in registers, no SRAM latency)
  //
  // Guard against SRAM write-first bypass corruption:
  // When l1d_update is processed at posedge K, the SRAM bank write and the
  // concurrent SRAM read (for a load entering LD_A) can hit the same
  // bank+index.  The write-first bypass in ysyx_sram_1r1w then returns the
  // store's merge/fill data instead of the load's cached data.  Because the
  // bypass fires at posedge K but l1d_update is cleared at the same posedge
  // (NBA), a combinational check at cycle K+1 (LD_A) would see l1d_update=0
  // and miss the conflict.  We therefore register the conflict condition and
  // check the delayed flag in the LD_A tag_hit calculation.
  //
  // When load_speculate is active, addr_offset still reflects the stale
  // l1d_addr from the previous operation.  Use the incoming load's word
  // offset (from the virtual address — safe due to VIPT: the offset bits
  // lie within the page offset, so virt == phys).
  logic [L1D_LINE_LEN-1:0] sram_rd_offset;
  assign sram_rd_offset = load_speculate
      ? lsu_l1d.raddr[L1D_LINE_LEN+OFFSET_BITS-1:OFFSET_BITS]
      : addr_offset;
  logic sram_bypass_r;
  always_ff @(posedge clock) begin
    if (reset) sram_bypass_r <= 1'b0;
    else sram_bypass_r <= l1d_update && (l1d_idx == sram_raddr)
                       && (l1d_off == sram_rd_offset);
  end
  assign tag_hit = (l1d_state == LD_A)
    && !sram_bypass_r
    && (l1d_valid[addr_idx][addr_offset] == 1'b1) && (l1d_tag[addr_idx][addr_offset] == addr_tag);
  // data_hit: SRAM data ready in LD_A — the speculative read in the preceding
  // IDLE (or PTW-wait) cycle guarantees data_bank_rdata is valid on LD_A entry.
  assign data_hit = (l1d_state == LD_A) && tag_hit;
  assign l1d_data = data_bank_rdata[addr_offset];

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+L1D_LINE_LEN+OFFSET_BITS];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+L1D_LINE_LEN+OFFSET_BITS-1:L1D_LINE_LEN+OFFSET_BITS];
  assign waddr_offset = lsu_l1d.waddr[L1D_LINE_LEN+OFFSET_BITS-1:OFFSET_BITS];
  assign hit_w = (l1d_valid[waddr_idx][waddr_offset] == 1'b1) && (l1d_tag[waddr_idx][waddr_offset] == waddr_tag);

  assign cacheable_r = ysyx_pkg::addr_cacheable(l1d_addr);
  assign cacheable_w = ysyx_pkg::addr_cacheable(lsu_l1d.waddr);

  assign mis_align_load = (
       ((lsu_l1d.ralu == `YSYX_ALU_LH__) && (lsu_l1d.raddr[0] != 1'b0))
    || ((lsu_l1d.ralu == `YSYX_ALU_LHU_) && (lsu_l1d.raddr[0] != 1'b0))
    || ((lsu_l1d.ralu == `YSYX_ALU_LW__) && (lsu_l1d.raddr[1:0] != 2'b00))
`ifdef YSYX_RV64
    || ((lsu_l1d.ralu == `YSYX_ALU_LWU_) && (lsu_l1d.raddr[1:0] != 2'b00))
    || ((lsu_l1d.ralu == `YSYX_ALU_LD__) && (lsu_l1d.raddr[2:0] != 3'b000))
`endif
  );
  assign mis_align_store = (
       ((exu_l1d.walu == `YSYX_SH_WSTRB) && (exu_l1d.vaddr[0] != 1'b0))
    || ((exu_l1d.walu == `YSYX_SW_WSTRB) && (exu_l1d.vaddr[1:0] != 2'b00))
`ifdef YSYX_RV64
    || ((exu_l1d.walu == `YSYX_SD_WSTRB) && (exu_l1d.vaddr[2:0] != 3'b000))
`endif
  );

  // read channel — PTW takes priority over cache miss reads
  assign l1d_bus.arvalid = ptw_arvalid
    ? 1'b1
    : (l1d_state == LD_A) && !tag_hit && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = ptw_arvalid ? ptw_araddr : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || ptw_arvalid) ? {{XLEN/8{1'b1}}} : rstrb;

  assign lsu_l1d.rdata = data_hit ? l1d_data : l1d_bus.rdata;
  assign lsu_l1d.trap = (l1d_state == TRAP) && (rec_addr == lsu_l1d.raddr);
  assign lsu_l1d.cause = cause;
  assign lsu_l1d.rready = (l1d_state == TRAP)
      || (data_hit && lsu_l1d.rvalid && rec_addr == lsu_l1d.raddr)
      || ((l1d_state == LD_D)
          && (lsu_l1d.rvalid)
          && (l1d_bus.rvalid)
          && (rec_addr == lsu_l1d.raddr));

  // write channel
  assign l1d_bus.awvalid = lsu_l1d.wvalid;
  assign l1d_bus.awaddr = lsu_l1d.waddr;
`ifdef YSYX_RV64
  // Decode walu (5-bit store mask) to full 8-bit wstrb for RV64
  // SB: 5'b00001→8'h01, SH: 5'b00011→8'h03, SW: 5'b01111→8'h0f, SD: 5'b11111→8'hff
  assign l1d_bus.wstrb = (lsu_l1d.walu == 5'b11111) ? 8'hff : {3'b0, lsu_l1d.walu[4:0]};
`else
  assign l1d_bus.wstrb = {4'b0, lsu_l1d.walu[3:0]};
`endif
  assign l1d_bus.wvalid = lsu_l1d.wvalid;
  assign l1d_bus.wdata = lsu_l1d.wdata;

  assign lsu_l1d.wready = l1d_bus.wready;

  // store address translation — stlb_hit uses TLB, otherwise wait for PTW
  assign store_paddr = XLEN'({ptw_result_ptag, exu_l1d.vaddr[11:0]});
  assign exu_l1d.paddr = stlb_hit
    ? XLEN'({dstlb_ptag, exu_l1d.vaddr[11:0]})
    : store_paddr;
  assign exu_l1d.trap = (l1d_state == TRAP) && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.ready = exu_l1d.valid && ((l1d_state == TRAP)
    || (stlb_hit && !mis_align_store)
    || (stlb_mmu && ptw_done));

  always @(posedge clock) begin
    if (reset) begin
      l1d_state  <= IDLE;
      for (int i = 0; i < int'(L1D_SIZE); i++) l1d_valid[i] <= '0;
      l1d_update <= 0;
      l1d_rmw    <= 0;

      reservation <= 'h0;
    end else begin
      if ((lsu_l1d.wvalid && lsu_l1d.waddr[XLEN-1:2] == reservation[XLEN-1:2])
        || exu_l1d.valid && exu_l1d.vaddr[XLEN-1:2] == reservation[XLEN-1:2]
        || rou_cmu.valid_a && rou_cmu.atomic_sc) begin
        reservation <= 'h0;
      end
      // if (l1d_bus.awvalid && csr_bcast.dmmu_en) begin
      //   $display("  [L1D WRITE] addr: %h, data: %h, wstrb: %h",
      //     l1d_bus.awaddr, l1d_bus.wdata, l1d_bus.wstrb);
      // end
      // if (l1d_bus.arvalid && (l1d_state == LD_A) && csr_bcast.dmmu_en) begin
      //   $display("  [L1D READ ] addr: %h", l1d_bus.araddr);
      // end
      unique case (l1d_state)
        IDLE: begin
          if (!cmu_bcast.flush_pipe) begin
            if (mmu_en) begin
              // Store TLB lookup (priority)
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                if (mis_align_store) begin
                  cause <= 'h6; // store address mis-aligned
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (!stlb_hit && !ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= exu_l1d.vaddr;
                  rec_addr <= exu_l1d.vaddr;
                  stlb_mmu <= 'b1;
                  l1d_state <= PTWAIT;
                end
              end else if (lsu_l1d.rvalid) begin
                // Load TLB lookup
                if (mis_align_load) begin
                  cause <= 'h4; // load address mis-aligned
                  rec_addr <= lsu_l1d.raddr;
                  l1d_state <= TRAP;
                end else if (tlb_hit) begin
                  l1d_addr <= {dtlb_ptag, lsu_l1d.raddr[11:0]}[XLEN-1:0];
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_state <= LD_A;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  stlb_mmu <= 'b0;
                  l1d_state <= PTWAIT;
                end
              end
            end else begin
              if (lsu_l1d.rvalid) begin
                l1d_addr <= lsu_l1d.raddr;
                rec_addr <= lsu_l1d.raddr;
                l1d_ralu  <= lsu_l1d.ralu;
                l1d_state <= LD_A;
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            stlb_mmu <= 'b0;
            l1d_state <= IDLE;
          end else if (ptw_done) begin
            if (stlb_mmu) begin
              // Store PTW done — TLB filled by u_dstlb
              stlb_mmu <= 'b0;
              l1d_state <= IDLE;
            end else begin
              // Load PTW done — TLB filled by u_dtlb, compute physical address
              l1d_addr <= XLEN'({ptw_result_ptag, l1d_addr[11:0]});
              l1d_state <= LD_A;
            end
          end else if (ptw_fault) begin
            if (stlb_mmu) begin
              cause <= 'hf; // store page fault
              stlb_mmu <= 'b0;
            end else begin
              cause <= 'hd; // load page fault
            end
            l1d_state <= TRAP;
          end
        end
        TRAP: begin
          l1d_state <= IDLE;
        end
        LD_A: begin
          if (lsu_l1d.atomic_lock) begin
            reservation <= l1d_addr;
          end
          if (tag_hit) begin
            l1d_addr  <= '0;
            l1d_state <= IDLE;
          end else begin
            if (l1d_bus.rready) begin
              l1d_state <= LD_D;
            end
          end
        end
        LD_D: begin
          if (l1d_bus.rvalid) begin
            l1d_state <= IDLE;
            if (lsu_l1d.atomic_lock) begin
              reservation <= l1d_addr;
            end
          end
        end
        default: begin
          l1d_addr <= '0;
          l1d_state <= IDLE;
        end
      endcase

      // l1d_update CLEAR: consume pending update (write tag/valid registers).
      // Must be textually BEFORE the SET block so that when both fire on the
      // same cycle (e.g. load-fill completes, then store write-through arrives
      // next cycle while l1d_update is still high), the SET's NBA wins and the
      // new update is not lost.
      if (cmu_bcast.fence_time) begin
        for (int i = 0; i < int'(L1D_SIZE); i++) l1d_valid[i] <= '0;
        l1d_rmw <= 0;
      end else if (l1d_update) begin
        // Data write handled by SRAM banks (wen gated by l1d_off)
        l1d_tag[l1d_idx][l1d_off] <= l1d_tag_u;
        l1d_valid[l1d_idx][l1d_off] <= l1d_valid_u;
        l1d_update <= 0;
      end

      // l1d_update SET: request a new SRAM + tag/valid write next cycle.
      // Textually last so its NBA to l1d_update wins over the CLEAR above.
      if (l1d_rmw) begin
        // RMW phase 2: SRAM data available from previous cycle read,
        // compute byte-lane merge and schedule the write-back.
        l1d_rmw <= 0;
        l1d_update <= 1'b1;
        l1d_data_u <= rmw_merged_data;
        l1d_valid_u <= 1'b1;
        // l1d_idx, l1d_off, l1d_tag_u already set at RMW trigger
      end else if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
`ifdef YSYX_RV64
        if (lsu_l1d.walu == `YSYX_SD_WSTRB) begin
`else
        if (lsu_l1d.walu == `YSYX_SW_WSTRB) begin
`endif
          l1d_update <= 1'b1;
          l1d_data_u <= lsu_l1d.wdata;
          l1d_valid_u <= 1'b1;
          l1d_tag_u <= waddr_tag;
          l1d_idx <= waddr_idx;
          l1d_off <= waddr_offset;
        end else begin
          if (hit_w) begin
            if (partial_store_rmw) begin
              // Partial store hit, SRAM read port free: initiate RMW
              l1d_rmw <= 1'b1;
              l1d_rmw_wdata <= lsu_l1d.wdata;
              l1d_rmw_waddr_lo <= lsu_l1d.waddr[OFFSET_BITS-1:0];
              l1d_rmw_walu <= lsu_l1d.walu;
              l1d_tag_u <= waddr_tag;
              l1d_idx <= waddr_idx;
              l1d_off <= waddr_offset;
            end else begin
              // Fallback: invalidate (SRAM read port busy)
              l1d_update <= 1'b1;
              l1d_valid_u <= 0;
              l1d_idx <= waddr_idx;
              l1d_off <= waddr_offset;
            end
          end
        end
      end else if (l1d_state == LD_D) begin
        if (lsu_l1d.rvalid && l1d_bus.rvalid) begin
          if (cacheable_r) begin
            l1d_update <= 1'b1;
            l1d_data_u <= l1d_bus.rdata;
            l1d_valid_u <= 1'b1;
            l1d_tag_u <= addr_tag;
            l1d_idx <= addr_idx;
            l1d_off <= addr_offset;
          end
        end
      end
    end
  end
endmodule
