`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_l1d #(
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
  typedef enum logic [3:0] {
    IDLE = 'b0000,

    PTW0 = 'b1000,
    PTW1 = 'b1001,
    TRAP = 'b1010,

    LD_A = 'b0001,
    LD_D = 'b0010
  } l1d_state_t;

  l1d_state_t l1d_state;

  logic [XLEN-1:0] l1d_addr;
  logic [4:0] l1d_ralu;
  logic [XLEN-1:0] rec_addr;

  // Tag and valid arrays (kept as registers for multi-port read and fast bulk invalidation)
  logic [L1D_SIZE-1:0] l1d_valid;
  localparam OFFSET_BITS = $clog2(XLEN/8);  // 2 for RV32, 3 for RV64
  localparam L1D_TAG_W = XLEN - L1D_LEN - OFFSET_BITS;
  logic [L1D_TAG_W-1:0] l1d_tag[L1D_SIZE];
  logic [7:0] rstrb;

  logic [L1D_TAG_W-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic tag_hit;   // tag comparison result (combinational, from register arrays)
  logic data_hit;  // SRAM data ready after 1-cycle read latency
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [L1D_TAG_W-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic hit_w;

  logic mmu_en;
  logic [XLEN-1:10] tlb_ptag;
  logic [XLEN-1:12] tlb_vtag;
  logic [11:0] tlb_offset;
  logic tlb_valid;
  logic tlb_hit;

  logic stlb_mmu;
  logic [XLEN-1:10] stlb_ptag;
  logic [XLEN-1:12] stlb_vtag;
  logic [11:0] stlb_offset;
  logic stlb_valid;
  logic stlb_hit;


  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] store_paddr;

  // atomic support
  logic [XLEN-1:0] reservation;

  // page table walk
  logic [9:0] vpn[2];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1+2:0] ppn_a;
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef YSYX_RV64
  // For Sv32 PTW on RV64: PTEs are 4 bytes. pmem_read returns 8 bytes from
  // the 8-byte-aligned address. Select the correct 32-bit half using ppn_a[2].
  logic [31:0] l1d_ptw_data;
  assign l1d_ptw_data = ppn_a[2] ? l1d_bus.rdata[63:32] : l1d_bus.rdata[31:0];
`else
  wire [31:0] l1d_ptw_data = l1d_bus.rdata[31:0];
`endif

  // mis-alignment check
  logic mis_align_load;
  logic mis_align_store;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [L1D_TAG_W-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;

  // Speculative SRAM read: when IDLE with a pending load, drive the *incoming*
  // virtual index directly instead of waiting for l1d_addr to be registered.
  // Safe because L1D_LEN+OFFSET_BITS < 12 (page offset), so virt_idx == phys_idx
  // (VIPT constraint satisfied). PTW paths are also safe: l1d_addr holds the
  // virtual address during PTW, whose index equals the final physical index.
  logic [L1D_LEN-1:0] sram_raddr;
  assign sram_raddr = (l1d_state == IDLE && lsu_l1d.rvalid && !cmu_bcast.flush_pipe)
      ? lsu_l1d.raddr[L1D_LEN+OFFSET_BITS-1:OFFSET_BITS]
      : addr_idx;

  // Data SRAM — read port serves cache hit path, write port serves fill/store update
  logic [XLEN-1:0] data_sram_rdata;
  ysyx_sram_1r1w #(
      .ADDR_WIDTH(L1D_LEN),
      .DATA_WIDTH(XLEN)
  ) u_data_sram (
      .clock(clock),
      .ren  (1'b1),
      .raddr(sram_raddr),
      .rdata(data_sram_rdata),
      .wen  (l1d_update),
      .waddr(l1d_idx),
      .wdata(l1d_data_u)
  );

  assign mmu_en = csr_bcast.dmmu_en;

  assign tlb_offset = l1d_addr[11:0];
  assign tlb_hit = (tlb_valid == 'b1) && (tlb_vtag == lsu_l1d.raddr[31:12]);
  assign stlb_offset = (exu_l1d.vaddr[11:0]);
  assign stlb_hit = (stlb_valid == 'b1) && (stlb_vtag == exu_l1d.vaddr[31:12]);

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

  assign addr_tag = l1d_addr[XLEN-1:L1D_LEN+OFFSET_BITS];
  assign addr_idx = l1d_addr[L1D_LEN+OFFSET_BITS-1:OFFSET_BITS];

  // tag_hit: combinational tag match in LD_A (tags in registers, no SRAM latency)
  assign tag_hit = (l1d_state == LD_A)
    && (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  // data_hit: SRAM data ready in LD_A — the speculative read in the preceding
  // IDLE (or PTW-wait) cycle guarantees data_sram_rdata is valid on LD_A entry.
  assign data_hit = (l1d_state == LD_A) && tag_hit;
  assign l1d_data = data_sram_rdata;

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+OFFSET_BITS];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+OFFSET_BITS-1:OFFSET_BITS];
  assign hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  assign cacheable_r = ((0)  //
      || (l1d_addr >= 'h20000000 && l1d_addr < 'h20400000)  // mrom
      || (l1d_addr >= 'h30000000 && l1d_addr < 'h40000000)  // flash
      || (l1d_addr >= 'h80000000 && l1d_addr < 'h88000000)  // psram
      || (l1d_addr >= 'ha0000000 && l1d_addr < 'ha2000000)  // sdram
      );
  assign cacheable_w = ((0)  //
      || (lsu_l1d.waddr >= 'h20000000 && lsu_l1d.waddr < 'h20400000)  // mrom
      || (lsu_l1d.waddr >= 'h30000000 && lsu_l1d.waddr < 'h40000000)  // flash
      || (lsu_l1d.waddr >= 'h80000000 && lsu_l1d.waddr < 'h88000000)  // psram
      || (lsu_l1d.waddr >= 'ha0000000 && lsu_l1d.waddr < 'ha2000000)  // sdram
      );

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

  // read channel
  assign l1d_bus.arvalid = (l1d_state == PTW1 || l1d_state == PTW0)
    ? 1'b1
    : (l1d_state == LD_A) && !tag_hit && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = (l1d_state == PTW1 || l1d_state == PTW0) ? ppn_a[XLEN-1:0] : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || (l1d_state == PTW1 || l1d_state == PTW0)) ? {{XLEN/8{1'b1}}} : rstrb;

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

  // store page table walk
  assign store_paddr = l1d_state == PTW0
    ? XLEN'({l1d_ptw_data[31:10], stlb_offset})
    : XLEN'({l1d_ptw_data[31:20], vpn[0], stlb_offset});
  assign exu_l1d.paddr = stlb_hit
    ? XLEN'({stlb_ptag, stlb_offset})
    : store_paddr;
  assign exu_l1d.trap = (l1d_state == TRAP) && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.ready = exu_l1d.valid && ((l1d_state == TRAP)
    || (stlb_hit && !mis_align_store)
    || (stlb_mmu
      && (l1d_bus.rvalid)
      && (l1d_state == PTW0
        || (l1d_state == PTW1 && (l1d_ptw_data[2] == 'b1 || l1d_ptw_data[1] == 'b1)))));

  always @(posedge clock) begin
    if (reset) begin
      l1d_state  <= IDLE;
      l1d_valid  <= 0;
      l1d_update <= 0;

      reservation <= 'h0;

      tlb_valid <= 'b0;
      stlb_valid <= 'b0;
    end else begin
      if ((lsu_l1d.wvalid && lsu_l1d.waddr[XLEN-1:2] == reservation[XLEN-1:2])
        || exu_l1d.valid && exu_l1d.vaddr[XLEN-1:2] == reservation[XLEN-1:2]
        || rou_cmu.valid && rou_cmu.atomic_sc) begin
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
              // tlb lookup
              if (exu_l1d.mmu_en && exu_l1d.valid) begin
                if (mis_align_store) begin
                  cause <= 'h6; // store address mis-aligned
                  rec_addr <= exu_l1d.vaddr;
                  l1d_state <= TRAP;
                end else if (stlb_hit) begin
                  // $display("[W] STLB hit addr: %h, paddr: %h",
                  //       exu_l1d.vaddr, exu_l1d.paddr);
                end else begin
                  // $display("[W] addr: %h, vpn[1,0]: [%h, %h]", exu_l1d.vaddr,
                  //          exu_l1d.vaddr[31:22], exu_l1d.vaddr[21:12]);
                  vpn[1] <= exu_l1d.vaddr[31:22];
                  vpn[0] <= exu_l1d.vaddr[21:12];
                  ppn_a <= {{csr_bcast.satp_ppn}, 12'b0} + (exu_l1d.vaddr[31:22] * 4);
                  l1d_addr <= exu_l1d.vaddr;
                  rec_addr <= exu_l1d.vaddr;
                  stlb_mmu <= 'b1;
                  l1d_state <= PTW1;
                end
              end else if (lsu_l1d.rvalid) begin
                if (mis_align_load) begin
                  cause <= 'h4; // load address mis-aligned
                  rec_addr <= lsu_l1d.raddr;
                  l1d_state <= TRAP;
                end else if (tlb_hit) begin
                  // $display("[W] MMU hit addr: %h, ptag: %h", lsu_l1d.raddr,
                  //          {tlb_ptag, 12'b0}[XLEN-1:0]);
                  l1d_addr <= {tlb_ptag, lsu_l1d.raddr[11:0]}[XLEN-1:0];
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_state <= LD_A;
                end else begin
                  // page table walk
                  // $display("[R] addr: %h, vpn[1,0]: [%h, %h]", lsu_l1d.raddr, lsu_l1d.raddr[31:22],
                  //         lsu_l1d.raddr[21:12]);
                  vpn[1] <= lsu_l1d.raddr[31:22];
                  vpn[0] <= lsu_l1d.raddr[21:12];
                  ppn_a <= {{csr_bcast.satp_ppn}, 12'b0} + (lsu_l1d.raddr[31:22] * 4);
                  l1d_addr <= lsu_l1d.raddr;
                  rec_addr <= lsu_l1d.raddr;
                  l1d_ralu  <= lsu_l1d.ralu;
                  l1d_state <= PTW1;
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
        PTW1: begin
          if (mmu_en) begin
            if (l1d_bus.rvalid) begin
              // $display("[PTW1] vpn1: %h, vpn0: %h, ppn_a: %h, pte1: %h",
              //   vpn[1], vpn[0], ppn_a, l1d_ptw_data);
              if (l1d_ptw_data == 0) begin
                l1d_state <= TRAP;
                cause <= 'hd; // load page fault
              end else if (l1d_ptw_data[2] == 'b1 || l1d_ptw_data[1] == 'b1) begin
                if (stlb_mmu) begin
                  // store page table walk finish
                  // $display("[PTW1] STLB miss addr: %h, paddr: %h, ptag: %h",
                  //       exu_l1d.vaddr, exu_l1d.paddr, {l1d_ptw_data[31:20], vpn[1]});
                  stlb_mmu <= 'b0;
                  stlb_valid <= 1'b1;
                  stlb_ptag <= {l1d_ptw_data[31:20], vpn[0]};
                  stlb_vtag <= {vpn[1], vpn[0]};
                  l1d_state <= IDLE;
                end else begin
                  // load page table walk finish
                  l1d_addr <= XLEN'({l1d_ptw_data[31:20], vpn[0], tlb_offset});
                  tlb_ptag <= {l1d_ptw_data[31:20], vpn[0]};
                  tlb_vtag <= {vpn[1], vpn[0]};
                  tlb_valid <= 'b1;
                  l1d_state <= LD_A;
                end
                // `YSYX_DPI_C_NPC_EXU_EBREAK
              end else begin
                ppn_a <= {l1d_ptw_data[31:10], 12'b0} + (vpn[0] * 4);
                l1d_state <= PTW0;
              end
            end
          end else begin
            l1d_state <= IDLE;
          end
        end
        PTW0: begin
          if (mmu_en) begin
            if (l1d_bus.rvalid) begin
              // $display("[PTW0] pte0: %h, paddr: %h",
              //  l1d_ptw_data, {l1d_ptw_data[31:10], tlb_offset});
              if (stlb_mmu) begin
                // store page table walk finish
                // $display("[PTW1] STLB miss addr: %h, paddr: %h, ptag: %h",
                //       exu_l1d.vaddr, exu_l1d.paddr, {l1d_ptw_data[31:10]});
                stlb_mmu <= 'b0;
                stlb_valid <= 1'b1;
                stlb_ptag <= {l1d_ptw_data[31:10]};
                stlb_vtag <= {vpn[1], vpn[0]};
                l1d_state <= IDLE;
              end else begin
                // load page table walk finish
                l1d_addr <= XLEN'({l1d_ptw_data[31:10], tlb_offset});
                tlb_ptag <= l1d_ptw_data[31:10];
                tlb_vtag <= {vpn[1], vpn[0]};
                tlb_valid <= 'b1;
                l1d_state <= LD_A;
                // `YSYX_DPI_C_NPC_EXU_EBREAK
              end
            end
          end else begin
            l1d_state <= IDLE;
          end
        end
        TRAP: begin
          // trap due to page table walk fail
          // $display("[D-TRAP] addr: %h, cause: %h", l1d_addr, cause);
          l1d_state <= IDLE;
        end
        LD_A: begin
          if (lsu_l1d.atomic_lock) begin
            reservation <= l1d_addr;
          end
          if (tag_hit) begin
            // SRAM data ready (pre-read in preceding cycle) — retire to IDLE immediately
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
        l1d_valid <= 0;
      end else if (l1d_update) begin
        // Data write handled by u_data_sram (wen=l1d_update)
        l1d_tag[l1d_idx] <= l1d_tag_u;
        l1d_valid[l1d_idx] <= l1d_valid_u;
        l1d_update <= 0;
      end

      // l1d_update SET: request a new SRAM + tag/valid write next cycle.
      // Textually last so its NBA to l1d_update wins over the CLEAR above.
      if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
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
        end else begin
          if (hit_w) begin
            // invalid cache
            l1d_update <= 1'b1;
            l1d_valid_u <= 0;
            l1d_idx <= waddr_idx;
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
          end
        end
      end
    end
  end
endmodule
