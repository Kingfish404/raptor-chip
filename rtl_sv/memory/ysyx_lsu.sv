`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_dpi_c.svh"

module ysyx_lsu #(
    parameter unsigned SQ_SIZE = `YSYX_SQ_SIZE,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_pipe_if.in cmu_bcast,

    lsu_l1d_if.master lsu_l1d,

    exu_lsu_if.slave  exu_lsu,
    exu_ioq_rou_if.in exu_ioq_rou,

    rou_lsu_if.in rou_lsu,

    l1d_bus_if.master l1d_bus,

    input reset
);
  typedef enum {
    LS_S_V = 0,
    LS_S_R = 1
  } state_store_t;

  state_store_t state_store;

  logic raddr_valid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] rdata_unalign;
  logic [XLEN-1:0] rdata;
  logic rready;

  // === Store Temporary Queue (STQ) ===
  logic [$clog2(SQ_SIZE)-1:0] stq_head;
  logic [$clog2(SQ_SIZE)-1:0] stq_tail;
  logic [SQ_SIZE-1:0] stq_valid;

  logic [4:0] stq_alu[SQ_SIZE];
  logic [XLEN-1:0] stq_waddr[SQ_SIZE];
  logic [XLEN-1:0] stq_wdata[SQ_SIZE];
  // === Store Temporary Queue (STQ) ===

  // === Store Queue (SQ) ===
  logic sq_ready;
  logic [$clog2(SQ_SIZE)-1:0] sq_head;
  logic [$clog2(SQ_SIZE)-1:0] sq_tail;
  logic [SQ_SIZE-1:0] sq_valid;
  logic [4:0] sq_alu[SQ_SIZE];
  logic [XLEN-1:0] sq_waddr[SQ_SIZE];
  logic [XLEN-1:0] sq_wdata[SQ_SIZE];
  logic [XLEN-1:0] sq_pc[SQ_SIZE];
  // === Store Queue (SQ) ===

  logic load_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] load_in_sq_idx;
  logic store_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] store_in_sq_idx;

  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [XLEN-1:0] waddr;
  logic [4:0] walu;

  assign raddr = exu_lsu.raddr;
  assign ralu = exu_lsu.ralu;
  assign sq_ready = sq_valid[sq_tail] == 0;
  assign rou_lsu.sq_ready = sq_ready;

  assign wvalid = sq_valid[sq_head];
  assign wdata = sq_wdata[sq_head];
  assign waddr = sq_waddr[sq_head];
  assign walu = sq_alu[sq_head];

  always @(posedge clock) begin
    if (reset) begin
      sq_head   <= 0;
      sq_tail   <= 0;
      sq_valid  <= 0;

      stq_head  <= 0;
      stq_tail  <= 0;
      stq_valid <= 0;
    end else begin
      if (cmu_bcast.flush_pipe || cmu_bcast.fence_time) begin
        stq_head  <= 0;
        stq_tail  <= 0;
        stq_valid <= 0;
      end else begin
        if (exu_ioq_rou.valid && exu_ioq_rou.wen) begin
          stq_valid[stq_tail] <= 1;

          stq_alu[stq_tail] <= exu_ioq_rou.alu;
          stq_waddr[stq_tail] <= exu_ioq_rou.sq_waddr;
          stq_wdata[stq_tail] <= exu_ioq_rou.sq_wdata;
          stq_tail <= stq_tail + 1;
        end
        if (rou_lsu.valid && rou_lsu.store && sq_ready) begin
          stq_valid[stq_head] <= 0;
          stq_head <= stq_head + 1;
        end
      end
      if (rou_lsu.valid && rou_lsu.store && sq_ready) begin
        // Store Commit
        sq_valid[sq_tail] <= 1;

        sq_alu[sq_tail] <= rou_lsu.alu;
        sq_waddr[sq_tail] <= rou_lsu.sq_waddr;
        sq_wdata[sq_tail] <= rou_lsu.sq_wdata;
        sq_pc[sq_tail] <= rou_lsu.pc;

        sq_tail <= sq_tail + 1;
        `YSYX_DPI_C_NPC_DIFFTEST_MEM_DIFF(rou_lsu.sq_waddr, rou_lsu.sq_wdata, {{3'b0}, rou_lsu.alu})
      end
      if (state_store == LS_S_R && sq_valid[sq_head]) begin
        // Store Finished
        sq_valid[sq_head] <= 0;

        sq_alu[sq_head] <= 0;
        sq_waddr[sq_head] <= 0;
        sq_wdata[sq_head] <= 0;

        sq_head <= sq_head + 1;
      end
    end
  end

  always_comb begin
    load_in_sq = 0;
    load_in_sq_idx = 0;
    for (int i = 0; i < SQ_SIZE; i++) begin
      if (sq_waddr[i] == (raddr) && sq_valid[i] && !load_in_sq) begin
        load_in_sq = 1;
        load_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
    store_in_sq = 0;
    store_in_sq_idx = 0;
    for (int i = 0; i < SQ_SIZE; i++) begin
      if (sq_waddr[i] == (rou_lsu.sq_waddr) && sq_valid[i] && !store_in_sq) begin
        store_in_sq = 1;
        store_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
  end

  assign raddr_valid = exu_lsu.rvalid && ((0)
      || (raddr >= 'h02000048 && raddr < 'h02000050)  // clint
      || (raddr >= 'h0f000000 && raddr < 'h0f002000)  // sram
      || (raddr >= 'h10000000 && raddr < 'h10001000)  // uart/ns16550
      || (raddr >= 'h10010000 && raddr < 'h10011900)  // liteuart0/csr
      || (raddr >= 'h20000000 && raddr < 'h20400000)  // mrom
      || (raddr >= 'h30000000 && raddr < 'h40000000)  // flash
      || (raddr >= 'h80000000 && raddr < 'h88000000)  // psram
      || (raddr >= 'ha0000000 && raddr < 'hc0000000)  // sdram
      );

  // logic [7:0] wstrb;
  // assign wstrb = (
  //          ({8{ralu == `YSYX_ALU_SB}} & 8'h1) |
  //          ({8{ralu == `YSYX_ALU_SH}} & 8'h3) |
  //          ({8{ralu == `YSYX_ALU_SW}} & 8'hf)
  //        );
  assign l1d_bus.awvalid = wvalid && state_store == LS_S_V;
  assign l1d_bus.awaddr = waddr;
  assign l1d_bus.wstrb[3:0] = walu[3:0];
  assign l1d_bus.wvalid = wvalid && state_store == LS_S_V;
  assign l1d_bus.wdata = wdata;

  assign rdata_unalign = lsu_l1d.rdata;
  assign rdata = (
      ({XLEN{raddr[1:0] == 2'b00}} & rdata_unalign)
    | ({XLEN{raddr[1:0] == 2'b01}} & {{8'b0}, {rdata_unalign[31:8]}})
    | ({XLEN{raddr[1:0] == 2'b10}} & {{16'b0}, {rdata_unalign[31:16]}})
    | ({XLEN{raddr[1:0] == 2'b11}} & {{24'b0}, {rdata_unalign[31:24]}})
    );
  assign exu_lsu.rdata = (
      ({XLEN{ralu == `YSYX_ALU_LB__}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff))
    | ({XLEN{ralu == `YSYX_ALU_LBU_}} & rdata & 'hff)
    | ({XLEN{ralu == `YSYX_ALU_LH__}} & (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff))
    | ({XLEN{ralu == `YSYX_ALU_LHU_}} & rdata & 'hffff)
    | ({XLEN{ralu == `YSYX_ALU_LW__}} & rdata)
    );
  assign exu_lsu.rready = lsu_l1d.rready;

  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_V;
    end else begin
      unique case (state_store)
        LS_S_V: begin
          if (wvalid) begin
            if (l1d_bus.wready) begin
              state_store <= LS_S_R;
            end
          end
        end
        LS_S_R: begin
          state_store <= LS_S_V;
        end
        default: begin
          state_store <= LS_S_V;
        end
      endcase
    end
  end

  assign lsu_l1d.raddr  = raddr;
  assign lsu_l1d.ralu   = ralu;
  assign lsu_l1d.rvalid = raddr_valid && !(|sq_valid) && !(|stq_valid);

  assign lsu_l1d.waddr  = waddr;
  assign lsu_l1d.walu   = walu;
  assign lsu_l1d.wvalid = wvalid;
  assign lsu_l1d.wdata  = wdata;
endmodule
