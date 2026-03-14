`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_l1i #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter unsigned IFQ_SIZE = 2,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_LEN = `YSYX_L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LEN = `YSYX_L1I_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_SIZE = 2 ** L1I_LEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_l1i_if.slave  ifu_l1i,
    l1i_bus_if.master l1i_bus,

    csr_bcast_if.in csr_bcast,

    input reset
);
  typedef enum logic [3:0] {
    IDLE = 'b0000,

    PTW0 = 'b1000,
    PTW1 = 'b1001,
    TRAP = 'b1010,

    RD_A = 'b0001,  // re-check hit after PTW/MMU before issuing AXI fetch
    RD_0 = 'b0010,
    RD_1 = 'b0110,
    FINA = 'b0111
  } l1i_state_t;

  l1i_state_t l1i_state;

  /* verilator lint_off UNUSEDSIGNAL */
  logic raddr_valid;
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] vaddr;
  logic invalid_l1i;

  logic is_c;
  logic [15:0] inst_lo, inst_hi;
  logic [XLEN-1:0] pc_ifu_next;
  logic [XLEN-1:0] l1i_addr;
  logic [XLEN-1:0] rec_addr;
  logic [XLEN-1:0] fetch_addr;
  // Tag and valid arrays (kept as registers for multi-port read and fast bulk invalidation)
  logic [L1I_SIZE-1:0] l1i_valid;
  localparam L1I_TAG_W = XLEN - L1I_LEN - L1I_LINE_LEN - 2;  // 2 = $clog2(4), instruction word size
  logic [L1I_TAG_W-1:0] l1i_tag[L1I_SIZE][L1I_LINE_SIZE];

  // Data SRAM bank signals — one bank per word position in cache line
  logic [31:0] data_bank_rdata [L1I_LINE_SIZE];
  logic [L1I_LEN-1:0] data_bank_raddr [L1I_LINE_SIZE];
  logic data_bank_wen [L1I_LINE_SIZE];

  logic [L1I_TAG_W-1:0] addr_tag;
  logic [L1I_LEN-1:0] addr_idx;
  logic [L1I_LINE_LEN-1:0] addr_offset;

  logic [L1I_TAG_W-1:0] addr_tag_next;
  logic [L1I_LEN-1:0] addr_idx_next;
  logic [L1I_LINE_LEN-1:0] addr_offset_next;

  logic [L1I_TAG_W-1:0] tag_fetch;
  logic [L1I_LEN-1:0] idx_fetch;
  logic [L1I_LINE_LEN-1:0] offset_fetch;

  logic hit, hit_next;
  logic ifu_sdram_arburst;
  logic wait_invalid;

  logic mmu_en;
  logic [XLEN-1:10] tlb_ptag;
  logic [XLEN-1:12] tlb_vtag;
  logic tlb_valid;
  logic tlb_hit;
  logic [11:0] tlb_offset;

  logic [XLEN-1:0] cause;

  // page table walk
  logic [9:0] vpn[2];
  logic [XLEN-1+2:0] ppn_a;

  logic [$clog2(IFQ_SIZE)-1:0] ifq_head;
  logic [$clog2(IFQ_SIZE)-1:0] ifq_tail;
  logic [IFQ_SIZE-1:0] ifq_valid;
  logic [XLEN-1:0] ifq_raddr[IFQ_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

  assign mmu_en = csr_bcast.immu_en;
  assign pc_ifu = mmu_en ? {tlb_ptag, tlb_offset}[XLEN-1:0] : ifu_l1i.pc;
  assign invalid_l1i = ifu_l1i.invalid;
  assign pc_ifu_next = pc_ifu + 2;

  // page table walk
  assign tlb_offset = ifu_l1i.pc[11:0];
  assign tlb_hit = tlb_valid && (tlb_vtag == ifu_l1i.pc[XLEN-1:12]);

  assign addr_tag = pc_ifu[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx = pc_ifu[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset = pc_ifu[L1I_LINE_LEN+2-1:2];

  assign addr_tag_next = pc_ifu_next[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign addr_idx_next = pc_ifu_next[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];
  assign addr_offset_next = pc_ifu_next[L1I_LINE_LEN+2-1:2];

  assign fetch_addr = ifq_raddr[ifq_tail];
  assign tag_fetch = fetch_addr[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];
  assign offset_fetch = fetch_addr[L1I_LINE_LEN+2-1:2];
  assign idx_fetch = fetch_addr[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];

  assign raddr_valid = csr_bcast.immu_en || ((0)
    || (l1i_addr >= 'h02000048 && l1i_addr < 'h02000050)  // clint
    || (l1i_addr >= 'h0f000000 && l1i_addr < 'h0f002000)  // sram
    || (l1i_addr >= 'h10000000 && l1i_addr < 'h10001000)  // uart/ns16550
    || (l1i_addr >= 'h10010000 && l1i_addr < 'h10011900)  // liteuart0/csr
    || (l1i_addr >= 'h20000000 && l1i_addr < 'h20400000)  // mrom
    || (l1i_addr >= 'h30000000 && l1i_addr < 'h40000000)  // flash
    || (l1i_addr >= 'h80000000 && l1i_addr < 'h88000000)  // psram
    || (l1i_addr >= 'ha0000000 && l1i_addr < 'ha2000000)  // sdram
  );

  assign l1i_bus.araddr = (l1i_state == PTW1 || l1i_state == PTW0)
    ? ppn_a[XLEN-1:0]
    : (l1i_state == RD_0)
      ? (l1i_addr & ~'h4)
      : (l1i_addr | 'h4);
  assign l1i_bus.arvalid = (l1i_state == PTW1 || l1i_state == PTW0)
    ? 1'b1
    : raddr_valid && (ifu_sdram_arburst
      ? (l1i_state == RD_0)
      : (l1i_state == RD_0 || l1i_state == RD_1));

  assign hit = (!invalid_l1i && !wait_invalid)
    && (mmu_en ? tlb_hit : 1'b1)
    && (l1i_state == IDLE || rec_addr == ifu_l1i.pc)
    && (l1i_valid[addr_idx] == 1'b1)
    && (l1i_tag[addr_idx][addr_offset] == addr_tag);
  assign hit_next = (!invalid_l1i && !wait_invalid)
    && (mmu_en ? tlb_hit : 1'b1)
    && (l1i_valid[addr_idx_next] == 1'b1)
    && (l1i_tag[addr_idx_next][addr_offset_next] == addr_tag_next);
  assign ifu_sdram_arburst = (`YSYX_I_SDRAM_ARBURST)
    && (l1i_addr >= 'ha0000000)
    && (l1i_addr <= 'hc0000000);

  // Fill write condition — suppress during PTW states where the bus is used for
  // page table reads (IFQ is always empty during PTW, but be explicit)
  logic l1i_fill_en;
  assign l1i_fill_en = l1i_bus.rvalid && ifq_valid[ifq_tail]
    && (l1i_state != PTW0 && l1i_state != PTW1);

`ifdef YSYX_RV64
  // For RV64, pmem_read returns an 8-byte naturally-aligned word. L1I always
  // does 4-byte reads (arsize=010), so we must select the correct 32-bit half
  // based on bit[2] of the requested address.
  // - Fill path: fetch_addr[2] tracks which word was requested
  // - PTW path: ppn_a[2] is the PTE address bit[2]
  logic [31:0] l1i_fill_data;
  assign l1i_fill_data = fetch_addr[2] ? l1i_bus.rdata[63:32] : l1i_bus.rdata[31:0];
  logic [31:0] l1i_ptw_data;
  assign l1i_ptw_data = ppn_a[2] ? l1i_bus.rdata[63:32] : l1i_bus.rdata[31:0];
`else
  wire [31:0] l1i_fill_data = l1i_bus.rdata[31:0];
  wire [31:0] l1i_ptw_data = l1i_bus.rdata[31:0];
`endif

  // Data SRAM bank instantiation and address routing
  // Each bank stores one word position of every cache set.
  // When pc[1]=1 (halfword-misaligned), inst_lo and inst_hi read from different
  // banks, avoiding read port conflicts. Fill writes target one bank at a time.
  generate
    for (genvar gi = 0; gi < L1I_LINE_SIZE; gi++) begin : gen_data_bank
      assign data_bank_raddr[gi] =
          (addr_offset == gi[L1I_LINE_LEN-1:0]) ? addr_idx : addr_idx_next;
      assign data_bank_wen[gi] =
          l1i_fill_en && (offset_fetch == gi[L1I_LINE_LEN-1:0]);

      ysyx_sram_1r1w #(
          .ADDR_WIDTH(L1I_LEN),
          .DATA_WIDTH(32)
      ) u_data_sram (
          .clock(clock),
          .ren  (1'b1),
          .raddr(data_bank_raddr[gi]),
          .rdata(data_bank_rdata[gi]),
          .wen  (data_bank_wen[gi]),
          .waddr(idx_fetch),
          .wdata(l1i_fill_data)
      );
    end
  endgenerate

  // Word selection from SRAM banks for instruction output
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] l1i_word_current, l1i_word_next;
  /* verilator lint_on UNUSEDSIGNAL */
  assign l1i_word_current = data_bank_rdata[addr_offset];
  assign l1i_word_next = data_bank_rdata[addr_offset_next];

  assign inst_lo = pc_ifu[1] ? l1i_word_current[31:16] : l1i_word_current[15:0];
  assign inst_hi = pc_ifu[1] ? l1i_word_next[15:0] : l1i_word_current[31:16];
  assign is_c = !(inst_lo[1:0] == 2'b11);

  // SRAM data readiness — per-bank address tracking.
  //
  // Each bank gi drives raddr = addr_idx when addr_offset==gi, else addr_idx_next.
  // Non-current banks pre-read the next set every cycle, so for sequential fetch
  // the target bank has already loaded the right data in the previous cycle
  // (sram_data_ready = 1 with zero bubble).  Branches/redirects still incur the
  // one-cycle SRAM latency, as the banks were reading a different index.
  //
  // inst_lo comes from bank[addr_offset]  → check data_bank_raddr_d1[addr_offset] == addr_idx
  // inst_hi comes from bank[addr_offset_next] → check data_bank_raddr_d1[addr_offset_next] == addr_idx_next
  //   (skipped when is_c=1, since only inst_lo is needed for 16-bit instructions)
  logic [L1I_LEN-1:0] data_bank_raddr_d1[L1I_LINE_SIZE];
  logic sram_data_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < int'(L1I_LINE_SIZE); i++)
        data_bank_raddr_d1[i] <= '0;
    end else begin
      for (int i = 0; i < int'(L1I_LINE_SIZE); i++)
        data_bank_raddr_d1[i] <= data_bank_raddr[i];
    end
  end
  assign sram_data_ready = (data_bank_raddr_d1[addr_offset] == addr_idx)
    && (is_c || data_bank_raddr_d1[addr_offset_next] == addr_idx_next);

  assign ifu_l1i.inst = (l1i_state == TRAP) ? 'h00000013 : {{inst_hi}, {inst_lo}};
  assign ifu_l1i.trap = (l1i_state == TRAP && rec_addr == ifu_l1i.pc);
  assign ifu_l1i.cause = cause;
  assign ifu_l1i.valid = l1i_state == TRAP ? rec_addr == ifu_l1i.pc
    : (hit && sram_data_ready && (hit_next || is_c) && !wait_invalid);

  always @(posedge clock) begin
    if (reset) begin
      l1i_state <= IDLE;
      ifq_head  <= 0;
      ifq_valid <= 0;

      l1i_valid <= 0;
      ifq_tail  <= 0;

      tlb_valid <= 0;
    end else begin
      unique case (l1i_state)
        IDLE: begin
          if (!invalid_l1i && !wait_invalid && !cmu_bcast.flush_pipe) begin
            if (mmu_en) begin
              // tlb lookup
              if (tlb_hit) begin
                // $display("[I] MMU hit pc: %h", ifu_l1i.pc);
                rec_addr <= ifu_l1i.pc;
                if (!hit) begin
                  // Current line missing: enter RD_A to re-check after registering
                  // rec_addr (handles race where a concurrent fill completes)
                  l1i_addr <= pc_ifu;
                  l1i_state <= RD_A;
                end else if (!hit_next) begin
                  // Current line hits, next line missing: address is known, skip RD_A
                  l1i_addr <= pc_ifu_next;
                  l1i_state <= RD_0;
                end
              end else begin
                // $display("[I] MMU miss pc: %h", ifu_l1i.pc);
                if (ifu_l1i.pc == 0) begin
                  rec_addr <= 0;
                  cause <= 'h1; // instruction page fault
                  l1i_state <= TRAP;
                end else begin
                  // page table walk
                  vpn[1] <= ifu_l1i.pc[31:22];
                  vpn[0] <= ifu_l1i.pc[21:12];
                  ppn_a <= {{csr_bcast.satp_ppn}, 12'b0} + (ifu_l1i.pc[31:22] * 4);
                  l1i_addr <= ifu_l1i.pc;
                  rec_addr <= ifu_l1i.pc;
                  l1i_state <= PTW1;
                end
              end
            end else begin
              rec_addr <= ifu_l1i.pc;
              if (!hit) begin
                l1i_addr  <= pc_ifu;
                l1i_state <= RD_0;
              end else if (!hit_next) begin
                l1i_addr  <= pc_ifu_next;
                l1i_state <= RD_0;
              end
            end
          end
        end
        PTW1: begin
          if (mmu_en) begin
            if (l1i_bus.rvalid) begin
              // $display("[I-PTW1] vpn1: %h, vpn0: %h, ppn_a: %h, pte1: %h",
              //   vpn[1], vpn[0], ppn_a, l1i_ptw_data);
              if (l1i_ptw_data == 0) begin
                l1i_state <= TRAP;
                cause <= 'hc; // instruction page fault
              end else if (l1i_ptw_data[2] == 'b1 || l1i_ptw_data[1] == 'b1) begin
                // inst page table walk finish
                l1i_addr <= XLEN'({l1i_ptw_data[31:20], vpn[0], tlb_offset});
                tlb_ptag <= {l1i_ptw_data[31:20], vpn[0]};
                tlb_vtag <= {vpn[1], vpn[0]};
                tlb_valid <= 'b1;
                l1i_state <= RD_A;
              end else begin
                ppn_a <= {l1i_ptw_data[31:10], 12'b0} + (vpn[0] * 4);
                l1i_state <= PTW0;
              end
            end
          end else begin
            l1i_state <= IDLE;
          end
        end
        PTW0: begin
          if (mmu_en) begin
            if (l1i_bus.rvalid) begin
              // $display("[I-PTW0] pte0: %h, paddr: %h",
              //  l1i_ptw_data, {l1i_ptw_data[31:10], tlb_offset});
              if (l1i_ptw_data == 0) begin
                l1i_state <= TRAP;
                cause <= 'hc; // instruction page fault
              end else begin
                // inst page table walk finish
                l1i_addr <= XLEN'({l1i_ptw_data[31:10], tlb_offset});
                tlb_ptag <= l1i_ptw_data[31:10];
                tlb_vtag <= {vpn[1], vpn[0]};
                tlb_valid <= 'b1;
                l1i_state <= RD_A;
              end
            end
          end else begin
            l1i_state <= IDLE;
          end
        end
        TRAP: begin
          // trap due to page table walk fail
          // $display("[I-TRAP] pc: %h, cause: %d", ifu_l1i.pc, cause);
          l1i_state <= IDLE;
        end
        RD_A: begin
          if (!hit) begin
            l1i_addr  <= pc_ifu;
            l1i_state <= RD_0;
          end else if (!hit_next) begin
            l1i_addr  <= pc_ifu_next;
            l1i_state <= RD_0;
          end else begin
            l1i_state <= IDLE;
          end
        end
        RD_0: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else
          if (l1i_bus.rready) begin
            l1i_state <= RD_1;

            ifq_raddr[ifq_head] <= l1i_bus.araddr;
            ifq_valid[ifq_head] <= 1'b1;
            ifq_head <= ifq_head + 1;
          end
        end
        RD_1: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else
          if (ifu_sdram_arburst || l1i_bus.rready) begin
            l1i_state <= FINA;

            ifq_raddr[ifq_head] <= l1i_bus.araddr;
            ifq_valid[ifq_head] <= 1'b1;
            ifq_head <= ifq_head + 1;
          end
        end
        FINA: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
            ifq_valid <= 0;
          end else
          if (ifq_valid == 0) begin
            l1i_state <= IDLE;
          end
        end
        default begin
          l1i_state <= IDLE;
        end
      endcase
    end

    if (invalid_l1i || wait_invalid) begin
      if (l1i_state == IDLE) begin
        l1i_valid <= 0;
        wait_invalid <= 0;
      end else begin
        wait_invalid <= 1;
      end
    end
    if (l1i_fill_en) begin
      // Data write handled by SRAM banks (wen driven by l1i_fill_en)
      l1i_tag[idx_fetch][offset_fetch] <= tag_fetch;
      if (ifq_valid[0] == 0) begin
        l1i_valid[idx_fetch] <= 1'b1;
      end
      ifq_valid[ifq_tail] <= 0;
      ifq_tail <= ifq_tail + 1;
    end
  end

endmodule
