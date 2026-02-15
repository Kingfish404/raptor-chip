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

  logic [XLEN-1:0] l1d[L1D_SIZE];
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-{{3'b0}, L1D_LEN}-2-1:0] l1d_tag[L1D_SIZE];
  logic [7:0] rstrb;

  logic [32-{{3'b0}, L1D_LEN}-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic hit;
  logic [XLEN-1:0] l1d_data;
  logic cacheable_r;
  logic cacheable_w;

  logic [32-{{3'b0}, L1D_LEN}-2-1:0] waddr_tag;
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

  // mis-alignment check
  logic mis_align_load;
  logic mis_align_store;

  logic l1d_update;
  logic [XLEN-1:0] l1d_data_u;
  logic l1d_valid_u;
  logic [32-{{3'b0}, L1D_LEN}-2-1:0] l1d_tag_u;
  logic [L1D_LEN-1:0] l1d_idx;

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
    );

  assign addr_tag = l1d_addr[XLEN-1:L1D_LEN+2];
  assign addr_idx = l1d_addr[L1D_LEN+2-1:0+2];

  assign hit = (l1d_state == LD_A)
    && (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign l1d_data = l1d[addr_idx];

  assign waddr_tag = lsu_l1d.waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = lsu_l1d.waddr[L1D_LEN+2-1:0+2];
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
  );
  assign mis_align_store = (
       ((exu_l1d.walu == `YSYX_SH_WSTRB) && (exu_l1d.vaddr[0] != 1'b0))
    || ((exu_l1d.walu == `YSYX_SW_WSTRB) && (exu_l1d.vaddr[1:0] != 2'b00))
  );

  // read channel
  assign l1d_bus.arvalid = (l1d_state == PTW1 || l1d_state == PTW0)
    ? 1'b1
    : (l1d_state == LD_A) && !hit && !cmu_bcast.flush_pipe;
  assign l1d_bus.araddr = (l1d_state == PTW1 || l1d_state == PTW0) ? ppn_a[XLEN-1:0] : l1d_addr;
  assign l1d_bus.rstrb = (cacheable_r || (l1d_state == PTW1 || l1d_state == PTW0)) ? 8'hf : rstrb;

  assign lsu_l1d.rdata = hit ? l1d_data : l1d_bus.rdata;
  assign lsu_l1d.trap = (l1d_state == TRAP) && (rec_addr == lsu_l1d.raddr);
  assign lsu_l1d.cause = cause;
  assign lsu_l1d.rready = (l1d_state == TRAP)
      || ((l1d_state == LD_A || (l1d_state == LD_D))
          && (lsu_l1d.rvalid)
          && ((hit) || (l1d_bus.rvalid)))
      && (rec_addr == lsu_l1d.raddr);

  // write channel
  assign l1d_bus.awvalid = lsu_l1d.wvalid;
  assign l1d_bus.awaddr = lsu_l1d.waddr;
  assign l1d_bus.wstrb[3:0] = lsu_l1d.walu[3:0];
  assign l1d_bus.wvalid = lsu_l1d.wvalid;
  assign l1d_bus.wdata = lsu_l1d.wdata;

  assign lsu_l1d.wready = l1d_bus.wready;

  // store page table walk
  assign store_paddr = l1d_state == PTW0
    ? {l1d_bus.rdata[31:10], stlb_offset}[XLEN-1:0]
    : {l1d_bus.rdata[31:20], vpn[0], stlb_offset}[XLEN-1:0];
  assign exu_l1d.paddr = stlb_hit
    ? {stlb_ptag, stlb_offset}[XLEN-1:0]
    : store_paddr;
  assign exu_l1d.trap = (l1d_state == TRAP) && (rec_addr == exu_l1d.vaddr);
  assign exu_l1d.cause = cause;
  assign exu_l1d.reservation = reservation;
  assign exu_l1d.ready = exu_l1d.valid && ((l1d_state == TRAP)
    || (stlb_hit && !mis_align_store)
    || (stlb_mmu
      && (l1d_bus.rvalid)
      && (l1d_state == PTW0
        || (l1d_state == PTW1 && (l1d_bus.rdata[2] == 'b1 || l1d_bus.rdata[1] == 'b1)))));

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
              //   vpn[1], vpn[0], ppn_a, l1d_bus.rdata);
              if (l1d_bus.rdata == 0) begin
                l1d_state <= TRAP;
                cause <= 'hd; // load page fault
              end else if (l1d_bus.rdata[2] == 'b1 || l1d_bus.rdata[1] == 'b1) begin
                if (stlb_mmu) begin
                  // store page table walk finish
                  // $display("[PTW1] STLB miss addr: %h, paddr: %h, ptag: %h",
                  //       exu_l1d.vaddr, exu_l1d.paddr, {l1d_bus.rdata[31:20], vpn[1]});
                  stlb_mmu <= 'b0;
                  stlb_valid <= 1'b1;
                  stlb_ptag <= {l1d_bus.rdata[31:20], vpn[0]};
                  stlb_vtag <= {vpn[1], vpn[0]};
                  l1d_state <= IDLE;
                end else begin
                  // load page table walk finish
                  l1d_addr <= {l1d_bus.rdata[31:20], vpn[0], tlb_offset}[XLEN-1:0];
                  tlb_ptag <= {l1d_bus.rdata[31:20], vpn[0]};
                  tlb_vtag <= {vpn[1], vpn[0]};
                  tlb_valid <= 'b1;
                  l1d_state <= LD_A;
                end
                // `YSYX_DPI_C_NPC_EXU_EBREAK
              end else begin
                ppn_a <= {l1d_bus.rdata[31:10], 12'b0} + (vpn[0] * 4);
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
              //  l1d_bus.rdata, {l1d_bus.rdata[31:10], tlb_offset});
              if (stlb_mmu) begin
                // store page table walk finish
                // $display("[PTW1] STLB miss addr: %h, paddr: %h, ptag: %h",
                //       exu_l1d.vaddr, exu_l1d.paddr, {l1d_bus.rdata[31:10]});
                stlb_mmu <= 'b0;
                stlb_valid <= 1'b1;
                stlb_ptag <= {l1d_bus.rdata[31:10]};
                stlb_vtag <= {vpn[1], vpn[0]};
                l1d_state <= IDLE;
              end else begin
                // load page table walk finish
                l1d_addr <= {l1d_bus.rdata[31:10], tlb_offset}[XLEN-1:0];
                tlb_ptag <= l1d_bus.rdata[31:10];
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
          if (!hit) begin
            if (l1d_bus.rready) begin
              l1d_state <= LD_D;
            end
          end else begin
            l1d_addr <= '0;
            l1d_state <= IDLE;
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

      if (lsu_l1d.wvalid && l1d_bus.wready && cacheable_w) begin
        if (lsu_l1d.walu == `YSYX_SW_WSTRB) begin
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

      if (cmu_bcast.fence_time) begin
        l1d_valid <= 0;
      end else if (l1d_update) begin
        l1d[l1d_idx] <= l1d_data_u;
        l1d_tag[l1d_idx] <= l1d_tag_u;
        l1d_valid[l1d_idx] <= l1d_valid_u;
        l1d_update <= 0;
      end
    end
  end
endmodule
