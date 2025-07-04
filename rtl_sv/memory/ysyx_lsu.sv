`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_lsu #(
    parameter unsigned SQ_SIZE = `YSYX_SQ_SIZE,
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** `YSYX_L1D_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input flush_pipeline,
    input fence_time,

    // from exu
    input ren,
    input [XLEN-1:0] raddr,
    input [4:0] ralu,
    // to exu
    output [XLEN-1:0] out_rdata,
    output out_rready,

    // from rou
    rou_lsu_if.in rou_lsu,
    output logic out_sq_ready,

    // to bus
    lsu_bus_if.master lsu_bus,

    input reset
);
  typedef enum logic [1:0] {
    LS_S_V = 0,
    LS_S_R = 1
  } state_store_t;

  state_store_t state_store;

  logic raddr_valid;
  logic [XLEN-1:0] rdata_unalign;
  logic [XLEN-1:0] rdata;

  // === Store Queue (SQ) ===
  logic sq_ready;
  logic [$clog2(SQ_SIZE)-1:0] sq_head;
  logic [$clog2(SQ_SIZE)-1:0] sq_tail;
  logic [SQ_SIZE-1:0] sq_valid;
  logic [4:0] sq_alu[SQ_SIZE];
  logic [XLEN-1:0] sq_waddr[SQ_SIZE];
  logic [XLEN-1:0] sq_wdata[SQ_SIZE];
  // === Store Queue (SQ) ===

  logic [XLEN-1:0] lsu_wdata;
  logic load_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] load_in_sq_idx;
  logic store_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] store_in_sq_idx;

  logic wvalid;
  logic [XLEN-1:0] waddr;
  logic [XLEN-1:0] wdata;
  logic [4:0] walu;
  logic wready;

  assign sq_ready = sq_valid[sq_tail] == 0 && (!store_in_sq || sq_valid[store_in_sq_idx] == 0);
  assign out_sq_ready = sq_ready;

  assign wvalid = sq_valid[sq_head];
  assign wdata = sq_wdata[sq_head];
  assign waddr = sq_waddr[sq_head];
  assign walu = sq_alu[sq_head];

  always @(posedge clock) begin
    if (reset) begin
      sq_head  <= 0;
      sq_tail  <= 0;
      sq_valid <= 0;
    end else begin
      if (rou_lsu.valid && rou_lsu.store && sq_ready) begin
        // Store Commit
        sq_valid[sq_tail] <= 1;
        sq_alu[sq_tail] <= rou_lsu.alu;
        sq_waddr[sq_tail] <= rou_lsu.sq_waddr;
        sq_wdata[sq_tail] <= rou_lsu.sq_wdata;
        sq_tail <= sq_tail + 1;
        if (store_in_sq && store_in_sq_idx != sq_tail) begin
          sq_waddr[store_in_sq_idx] <= 0;
        end
      end
      if (wready && sq_valid[sq_head]) begin
        // Store Finished
        sq_valid[sq_head] <= 0;
        sq_head <= sq_head + 1;
      end
    end
  end

  always_comb begin
    load_in_sq = 0;
    load_in_sq_idx = 0;
    for (int i = 0; i < SQ_SIZE; i++) begin
      if (sq_waddr[i] == (raddr) && !load_in_sq) begin
        load_in_sq = 1;
        load_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
    store_in_sq = 0;
    store_in_sq_idx = 0;
    for (int i = 0; i < SQ_SIZE; i++) begin
      if (sq_waddr[i] == (rou_lsu.sq_waddr) && !store_in_sq) begin
        store_in_sq = 1;
        store_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
  end

  assign raddr_valid = ((0)  //
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
  assign lsu_bus.awvalid = wvalid && state_store == LS_S_V;
  assign lsu_bus.awaddr = waddr;
  assign lsu_bus.wstrb[3:0] = walu[3:0];
  assign lsu_bus.wvalid = wvalid && state_store == LS_S_V;
  assign lsu_bus.wdata = wdata;

  assign wready = state_store == LS_S_R;

  assign rdata = (
           ({XLEN{raddr[1:0] == 2'b00}} & rdata_unalign) |
           ({XLEN{raddr[1:0] == 2'b01}} & {{8'b0}, {rdata_unalign[31:8]}}) |
           ({XLEN{raddr[1:0] == 2'b10}} & {{16'b0}, {rdata_unalign[31:16]}}) |
           ({XLEN{raddr[1:0] == 2'b11}} & {{24'b0}, {rdata_unalign[31:24]}}) |
           (0)
         );
  assign out_rdata = (
           ({XLEN{ralu == `YSYX_ALU_LB__}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) |
           ({XLEN{ralu == `YSYX_ALU_LBU_}} & rdata & 'hff) |
           ({XLEN{ralu == `YSYX_ALU_LH__}} &
              (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) |
           ({XLEN{ralu == `YSYX_ALU_LHU_}} & rdata & 'hffff) |
           ({XLEN{ralu == `YSYX_ALU_LW__}} & rdata)
         );

  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_V;
    end else begin
      unique case (state_store)
        LS_S_V: begin
          if (wvalid) begin
            if (lsu_bus.wready) begin
              lsu_wdata   <= wdata;
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

  ysyx_lsu_l1d #(
      .XLEN(XLEN),
      .L1D_LEN(L1D_LEN),
      .L1D_SIZE(L1D_SIZE)
  ) l1d_cache (
      .clock(clock),

      .flush_pipeline(flush_pipeline),
      .fence_time(fence_time),

      // load
      .raddr(raddr),
      .ralu(ralu),
      .rvalid(ren && raddr_valid && !(|sq_valid)),
      .lsu_rdata(rdata_unalign),
      .lsu_rready(out_rready),

      .load_in_sq(load_in_sq),
      .sq_wdata  (sq_wdata[load_in_sq_idx]),

      // write
      .waddr (waddr),
      .wvalid(wvalid && lsu_bus.wready),
      .wdata (wdata),
      .walu  (walu),

      // <=> bus
      .lsu_bus(lsu_bus),

      .reset(reset)
  );
endmodule
