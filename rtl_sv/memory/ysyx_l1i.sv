`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"

module ysyx_l1i #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter unsigned IFQ_SIZE = 2,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_LEN = `YSYX_L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LINE_SIZE = 2 ** L1I_LINE_LEN,
    parameter bit [`YSYX_L1I_LEN:0] L1I_LEN = `YSYX_L1I_LEN,
    parameter unsigned L1I_N_WAYS = `YSYX_L1I_N_WAYS
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_l1i_if.slave  ifu_l1i,
    l1i_bus_if.master l1i_bus,

    csr_bcast_if.in csr_bcast,

    input reset
);
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    PTWAIT = 3'b100,  // waiting for PTW to complete
    TRAP   = 3'b101,
    RD_A   = 3'b001,  // re-check hit after PTW/MMU
    RD_0   = 3'b010,
    RD_1   = 3'b110,
    FINA   = 3'b111
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
  // Cache size/tag parameters and per-way valid arrays (registers for bulk clear on fence_i)
  localparam unsigned L1iSize = 2 ** L1I_LEN;
  localparam unsigned L1iTagW = XLEN - L1I_LEN - L1I_LINE_LEN - 2;  // 2 = $clog2(4), word size
  localparam unsigned L1iWayW = L1I_N_WAYS > 1 ? $clog2(L1I_N_WAYS) : 1;
  logic [L1iSize-1:0] l1i_valid[L1I_N_WAYS];

  // Per-way Data/Tag SRAM bank signals
  logic [31:0] data_bank_rdata[L1I_N_WAYS][L1I_LINE_SIZE];
  logic [L1I_LEN-1:0] data_bank_raddr[L1I_LINE_SIZE];  // shared across ways
  logic [L1iTagW-1:0] tag_bank_rdata[L1I_N_WAYS][L1I_LINE_SIZE];

  // Way hit logic
  logic [L1I_N_WAYS-1:0] way_hit, way_hit_next;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [L1iWayW-1:0] hit_way_sel, hit_next_way_sel;
  /* verilator lint_on UNUSEDSIGNAL */

  // Replacement: 1-bit per set (toggle on fill); fill picks invalid way first
  logic [L1iSize-1:0] replace_bit;
  logic [L1iWayW-1:0] fill_way_r;
  logic [L1iWayW-1:0] fill_way_calc, fill_way_next_calc;

  logic [L1iTagW-1:0] addr_tag;
  logic [L1I_LEN-1:0] addr_idx;
  logic [L1I_LINE_LEN-1:0] addr_offset;

  logic [L1iTagW-1:0] addr_tag_next;
  logic [L1I_LEN-1:0] addr_idx_next;
  logic [L1I_LINE_LEN-1:0] addr_offset_next;

  logic [L1iTagW-1:0] tag_fetch;
  logic [L1I_LEN-1:0] idx_fetch;
  logic [L1I_LINE_LEN-1:0] offset_fetch;

  logic hit, hit_next;
  logic ifu_sdram_arburst;
  logic wait_invalid;

  logic mmu_en;
  logic tlb_hit;
  logic [XLEN-1:10] itlb_ptag;
  logic [11:0] tlb_offset;

  logic [XLEN-1:0] cause;

  logic [$clog2(IFQ_SIZE)-1:0] ifq_head;
  logic [$clog2(IFQ_SIZE)-1:0] ifq_tail;
  logic [IFQ_SIZE-1:0] ifq_valid;
  logic [XLEN-1:0] ifq_raddr[IFQ_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

  // PTW instance signals
  logic ptw_req;
  /* verilator lint_off UNUSEDSIGNAL */
  logic ptw_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic ptw_done, ptw_fault;
  logic ptw_arvalid;
  logic [XLEN-1:0] ptw_araddr;
  logic [XLEN-1:10] ptw_result_ptag;
  logic [XLEN-1:12] ptw_result_vtag;

  logic l1i_fill_en;

  assign mmu_en = csr_bcast.immu_en;
  assign pc_ifu = mmu_en ? XLEN'({itlb_ptag, tlb_offset}) : ifu_l1i.pc;
  assign invalid_l1i = ifu_l1i.invalid;
  assign pc_ifu_next = pc_ifu + 2;

  // +4 lookahead: when the fetch stride is +4 (32-bit insn or dual C-pair),
  // the SRAM bank that will be needed next cycle is the one for pc+4, not
  // pc+2.  Pre-reading this address in idle banks eliminates the 1-cycle
  // SRAM-ready bubble that otherwise occurs at every cache-line crossing.
  logic [XLEN-1:0] pc_ifu_next4;
  logic [L1I_LEN-1:0] addr_idx_next4;
  assign pc_ifu_next4 = pc_ifu + 4;
  assign addr_idx_next4 = pc_ifu_next4[L1I_LEN+L1I_LINE_LEN+2-1:L1I_LINE_LEN+2];

  assign tlb_offset = ifu_l1i.pc[11:0];

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

  assign raddr_valid = csr_bcast.immu_en || ysyx_pkg::addr_valid(l1i_addr);

  // --- L1I Tag Comparison (N-way set-associative, SRAM tags) ---
  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way_hit
      assign way_hit[w] = l1i_valid[w][addr_idx] && (tag_bank_rdata[w][addr_offset] == addr_tag);
      assign way_hit_next[w] = l1i_valid[w][addr_idx_next]
        && (tag_bank_rdata[w][addr_offset_next] == addr_tag_next);
    end
  endgenerate
  always_comb begin
    hit_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--) if (way_hit[w]) hit_way_sel = L1iWayW'(w);
    hit_next_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--)
    if (way_hit_next[w]) hit_next_way_sel = L1iWayW'(w);
  end
  // Fill way: prefer invalid way, then random toggle
  generate
    if (L1I_N_WAYS > 1) begin : gen_fill_multi
      assign fill_way_calc = !l1i_valid[0][addr_idx] ? 1'b0
        : !l1i_valid[1][addr_idx] ? 1'b1
        : replace_bit[addr_idx];
      assign fill_way_next_calc = !l1i_valid[0][addr_idx_next] ? 1'b0
        : !l1i_valid[1][addr_idx_next] ? 1'b1
        : replace_bit[addr_idx_next];
    end else begin : gen_fill_dm
      assign fill_way_calc = '0;
      assign fill_way_next_calc = '0;
    end
  endgenerate

  assign hit = (!invalid_l1i && !wait_invalid)
    && (mmu_en ? tlb_hit : 1'b1)
    && (l1i_state == IDLE || rec_addr == ifu_l1i.pc)
    && |way_hit;
  assign hit_next = (!invalid_l1i && !wait_invalid) && (mmu_en ? tlb_hit : 1'b1) && |way_hit_next;

  // Bus mux: PTW takes priority over cache fill
  assign l1i_bus.araddr = ptw_arvalid
    ? ptw_araddr
    : (l1i_state == RD_0)
      ? (l1i_addr & ~'h4)
      : (l1i_addr | 'h4);
  assign l1i_bus.arvalid = ptw_arvalid
    ? 1'b1
    : raddr_valid && (ifu_sdram_arburst
      ? (l1i_state == RD_0)
      : (l1i_state == RD_0 || l1i_state == RD_1));

  assign ifu_sdram_arburst = (`YSYX_I_SDRAM_ARBURST)
    && (l1i_addr >= 'ha0000000)
    && (l1i_addr <= 'hc0000000);
  assign l1i_bus.arburst = ifu_sdram_arburst;

  // Fill write condition: suppress during PTW states where the bus is used for
  // page table reads (IFQ is always empty during PTW, but be explicit)
  assign l1i_fill_en = l1i_bus.rvalid && ifq_valid[ifq_tail] && (l1i_state != PTWAIT);

`ifdef YSYX_RV64
  logic [31:0] l1i_fill_data;
  assign l1i_fill_data = fetch_addr[2] ? l1i_bus.rdata[63:32] : l1i_bus.rdata[31:0];
`else
  wire [31:0] l1i_fill_data = l1i_bus.rdata[31:0];
`endif

  // --- ITLB ---
  ysyx_tlb #(
      .XLEN(XLEN)
  ) u_itlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .lookup_vtag(ifu_l1i.pc[XLEN-1:12]),
      .lookup_asid(csr_bcast.satp_asid),
      .hit(tlb_hit),
      .ptag(itlb_ptag),
      .fill_valid((l1i_state == PTWAIT) && ptw_done),
      .fill_ptag(ptw_result_ptag),
      .fill_vtag(ptw_result_vtag),
      .fill_asid(csr_bcast.satp_asid)
  );

  // --- PTW ---
  ysyx_ptw #(
      .XLEN(XLEN)
  ) u_iptw (
      .clock(clock),
      .reset(reset),
      .req_valid(ptw_req),
      .vaddr(ifu_l1i.pc),
      .satp_ppn(csr_bcast.satp_ppn),
      .mmu_en(mmu_en),
      .bus_arvalid(ptw_arvalid),
      .bus_araddr(ptw_araddr),
      .bus_rvalid(l1i_bus.rvalid),
      .bus_rdata(l1i_bus.rdata),
      .done(ptw_done),
      .fault(ptw_fault),
      .result_ptag(ptw_result_ptag),
      .result_vtag(ptw_result_vtag),
      .busy(ptw_busy)
  );

  // SRAM address routing (shared across all ways)
  //
  // Three-tier pre-read strategy for zero-bubble sequential fetch at both
  // +2 and +4 byte strides:
  //   - Bank matching addr_offset      -> reads addr_idx      (current fetch)
  //   - Bank matching addr_offset_next -> reads addr_idx_next (+2 lookahead,
  //                                       needed for 32-bit insn spanning)
  //   - All remaining banks            -> read addr_idx_next4 (+4 lookahead,
  //                                       covers 32-bit insn stride and
  //                                       dual C-pair stride)
  //
  // When pc is word-aligned the +2 bank falls on the same offset as the
  // current bank, so the second tier collapses and three banks pre-read +4.
  generate
    for (genvar gi = 0; gi < L1I_LINE_SIZE; gi++) begin : gen_addr
      assign data_bank_raddr[gi] =
          (addr_offset == L1I_LINE_LEN'(gi))
          ? addr_idx
          : (addr_offset_next == L1I_LINE_LEN'(gi))
            ? addr_idx_next
            : addr_idx_next4;
    end
  endgenerate

  // Per-way Data + Tag SRAM banks
  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way
      for (genvar gi = 0; gi < L1I_LINE_SIZE; gi++) begin : gen_bank
        ysyx_sram_1r1w #(
            .ADDR_WIDTH(L1I_LEN),
            .DATA_WIDTH(32)
        ) u_data_sram (
            .clock(clock),
            .ren(1'b1),
            .raddr(data_bank_raddr[gi]),
            .rdata(data_bank_rdata[w][gi]),
            .wen(l1i_fill_en && (offset_fetch == L1I_LINE_LEN'(gi)) && (fill_way_r == L1iWayW'(w))),
            .waddr(idx_fetch),
            .wdata(l1i_fill_data)
        );
        ysyx_sram_1r1w #(
            .ADDR_WIDTH(L1I_LEN),
            .DATA_WIDTH(L1iTagW)
        ) u_tag_sram (
            .clock(clock),
            .ren(1'b1),
            .raddr(data_bank_raddr[gi]),
            .rdata(tag_bank_rdata[w][gi]),
            .wen(l1i_fill_en && (offset_fetch == L1I_LINE_LEN'(gi)) && (fill_way_r == L1iWayW'(w))),
            .waddr(idx_fetch),
            .wdata(tag_fetch)
        );
      end
    end
  endgenerate

  // Word selection from SRAM banks for instruction output
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] l1i_word_current, l1i_word_next;
  /* verilator lint_on UNUSEDSIGNAL */
  assign l1i_word_current = data_bank_rdata[hit_way_sel][addr_offset];
  assign l1i_word_next = data_bank_rdata[hit_next_way_sel][addr_offset_next];

  assign inst_lo = pc_ifu[1] ? l1i_word_current[31:16] : l1i_word_current[15:0];
  assign inst_hi = pc_ifu[1] ? l1i_word_next[15:0] : l1i_word_current[31:16];
  assign is_c = !(inst_lo[1:0] == 2'b11);

  // SRAM data readiness: per-bank address tracking.
  //
  // Each bank gi drives raddr = addr_idx when addr_offset==gi, else addr_idx_next.
  // Non-current banks pre-read the next set every cycle, so for sequential fetch
  // the target bank has already loaded the right data in the previous cycle
  // (sram_data_ready = 1 with zero bubble).  Branches/redirects still incur the
  // one-cycle SRAM latency, as the banks were reading a different index.
  //
  // inst_lo comes from bank[addr_offset]  -> check data_bank_raddr_d1[addr_offset] == addr_idx
  // inst_hi comes from bank[addr_offset_next] -> check data_bank_raddr_d1[addr_offset_next] == addr_idx_next
  //   (skipped when is_c=1, since only inst_lo is needed for 16-bit instructions)
  logic [L1I_LEN-1:0] data_bank_raddr_d1[L1I_LINE_SIZE];
  logic sram_data_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < int'(L1I_LINE_SIZE); i++) data_bank_raddr_d1[i] <= '0;
    end else begin
      for (int i = 0; i < int'(L1I_LINE_SIZE); i++) data_bank_raddr_d1[i] <= data_bank_raddr[i];
    end
  end
  assign sram_data_ready = (data_bank_raddr_d1[addr_offset] == addr_idx)
    && (is_c || data_bank_raddr_d1[addr_offset_next] == addr_idx_next);

  assign ifu_l1i.inst_n0 = (l1i_state == TRAP) ? 'h00000013 : {{inst_hi}, {inst_lo}};
  assign ifu_l1i.trap = (l1i_state == TRAP && rec_addr == ifu_l1i.pc);
  assign ifu_l1i.cause = cause;
  assign ifu_l1i.valid = l1i_state == TRAP ? rec_addr == ifu_l1i.pc
    : (hit && sram_data_ready && (hit_next || is_c) && !wait_invalid);

`ifdef YSYX_DUAL_ISSUE
  // --- Dual-issue: next-word output for generalized dual-fetch ---
  // When pc[1]=0: bank[addr_offset+1] holds the word at pc+4.
  // When pc[1]=1: bank[addr_offset_next] already has pc+2..pc+5; reuse l1i_word_next.
  logic [L1I_LINE_LEN-1:0] addr_offset_n1;
  logic [L1iTagW-1:0] addr_tag_next4;
  logic [L1I_N_WAYS-1:0] way_hit_n1;
  logic [L1iWayW-1:0] hit_n1_way_sel;
  logic hit_n1;
  logic [31:0] l1i_word_n1;
  logic sram_n1_ready;

  assign addr_offset_n1 = addr_offset + L1I_LINE_LEN'(1);
  assign addr_tag_next4 = pc_ifu_next4[XLEN-1:L1I_LEN+L1I_LINE_LEN+2];

  generate
    for (genvar w = 0; w < L1I_N_WAYS; w++) begin : gen_way_hit_n1
      assign way_hit_n1[w] = l1i_valid[w][addr_idx_next4]
        && (tag_bank_rdata[w][addr_offset_n1] == addr_tag_next4);
    end
  endgenerate

  always_comb begin
    hit_n1_way_sel = '0;
    for (int w = int'(L1I_N_WAYS) - 1; w >= 0; w--) if (way_hit_n1[w]) hit_n1_way_sel = L1iWayW'(w);
  end

  assign hit_n1 = |way_hit_n1;
  assign l1i_word_n1 = data_bank_rdata[hit_n1_way_sel][addr_offset_n1];
  assign sram_n1_ready = (data_bank_raddr_d1[addr_offset_n1] == addr_idx_next4);

  assign ifu_l1i.inst_n1 = pc_ifu[1] ? l1i_word_next : l1i_word_n1;
  assign ifu_l1i.inst_n1_valid = pc_ifu[1]
    ? (hit_next && (data_bank_raddr_d1[addr_offset_next] == addr_idx_next))
    : (hit_n1 && sram_n1_ready);
`endif

  // PTW request: TLB miss in IDLE when MMU enabled and address is nonzero
  assign ptw_req = (l1i_state == IDLE) && mmu_en && !tlb_hit
      && !invalid_l1i && !wait_invalid && !cmu_bcast.flush_pipe
      && !ptw_busy
      && (ifu_l1i.pc != 0);

  always @(posedge clock) begin
    if (reset) begin
      l1i_state <= IDLE;
      ifq_head <= 0;
      ifq_valid <= 0;
      l1i_valid <= '{default: '0};
      replace_bit <= 0;
      fill_way_r <= 0;
      ifq_tail <= 0;
    end else begin
      unique case (l1i_state)
        IDLE: begin
          if (!invalid_l1i && !wait_invalid && !cmu_bcast.flush_pipe) begin
            if (mmu_en) begin
              if (tlb_hit) begin
                rec_addr <= ifu_l1i.pc;
                if (sram_data_ready) begin
                  if (!hit) begin
                    l1i_addr  <= pc_ifu;
                    l1i_state <= RD_A;
                  end else if (!hit_next) begin
                    l1i_addr   <= pc_ifu_next;
                    l1i_state  <= RD_0;
                    fill_way_r <= fill_way_next_calc;
                  end
                end
              end else begin
                if (ifu_l1i.pc == 0) begin
                  rec_addr <= 0;
                  cause <= 'h1;  // instruction access fault
                  l1i_state <= TRAP;
                end else if (!ptw_busy) begin
                  // PTW request issued via ptw_req
                  l1i_addr  <= ifu_l1i.pc;
                  rec_addr  <= ifu_l1i.pc;
                  l1i_state <= PTWAIT;
                end
              end
            end else begin
              rec_addr <= ifu_l1i.pc;
              if (sram_data_ready) begin
                if (!hit) begin
                  l1i_addr   <= pc_ifu;
                  l1i_state  <= RD_0;
                  fill_way_r <= fill_way_calc;
                end else if (!hit_next) begin
                  l1i_addr   <= pc_ifu_next;
                  l1i_state  <= RD_0;
                  fill_way_r <= fill_way_next_calc;
                end
              end
            end
          end
        end
        PTWAIT: begin
          if (cmu_bcast.flush_pipe) begin
            l1i_state <= IDLE;
          end else if (ptw_done) begin
            // PTW completed: TLB filled by u_itlb, compute physical address
            l1i_addr  <= XLEN'({ptw_result_ptag, tlb_offset});
            l1i_state <= RD_A;
          end else if (ptw_fault) begin
            cause <= 'hc;  // instruction page fault
            l1i_state <= TRAP;
          end
        end
        TRAP: begin
          l1i_state <= IDLE;
        end
        RD_A: begin
          // Guard: abort if pipeline flush or TLB invalidated (sfence.vma /
          // satp switch): pc_ifu depends on itlb_ptag which is 0 on TLB miss,
          // producing a garbage physical address (e.g. 0x68a).
          if (cmu_bcast.flush_pipe || (mmu_en && !tlb_hit)) begin
            l1i_state <= IDLE;
          end else if (sram_data_ready) begin
            if (!hit) begin
              l1i_addr   <= pc_ifu;
              l1i_state  <= RD_0;
              fill_way_r <= fill_way_calc;
            end else if (!hit_next) begin
              l1i_addr   <= pc_ifu_next;
              l1i_state  <= RD_0;
              fill_way_r <= fill_way_next_calc;
            end else begin
              l1i_state <= IDLE;
            end
          end
        end
        RD_0: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else if (l1i_bus.rready) begin
            l1i_state <= RD_1;

            ifq_raddr[ifq_head] <= l1i_bus.araddr;
            ifq_valid[ifq_head] <= 1'b1;
            ifq_head <= ifq_head + 1;
          end
        end
        RD_1: begin
          if (!raddr_valid) begin
            l1i_state <= IDLE;
          end else if (ifu_sdram_arburst || l1i_bus.rready) begin
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
          end else if (ifq_valid == 0) begin
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
        l1i_valid <= '{default: '0};
        wait_invalid <= 0;
      end else begin
        wait_invalid <= 1;
      end
    end
    // Valid + IFQ update on cache line arrival (tag fill handled by SRAM wen)
    // Valid + IFQ update on cache line arrival (tag fill handled by SRAM wen)
    if (l1i_fill_en) begin
      if (ifq_valid[0] == 0) begin
        l1i_valid[fill_way_r][idx_fetch] <= 1'b1;
        replace_bit[idx_fetch] <= ~replace_bit[idx_fetch];
      end
      ifq_valid[ifq_tail] <= 0;
      ifq_tail <= ifq_tail + 1;
    end
  end

endmodule
