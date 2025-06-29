`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_lsu #(
    parameter unsigned SQ_SIZE = `YSYX_SQ_SIZE,
    parameter bit [`YSYX_L1D_LEN:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [`YSYX_L1D_LEN:0] L1D_SIZE = 2 ** L1D_LEN,
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
    output out_rvalid,

    // from iqu
    iqu_lsu_if.in iqu_lsu_i,
    output logic out_sq_ready,

    lsu_bus_if.master lsu_bus,

    input reset
);
  typedef enum logic [1:0] {
    IF_A = 0,
    IF_L = 1,
    IF_V = 2
  } state_load_t;

  typedef enum logic [1:0] {
    LS_S_V = 0,
    LS_S_R = 1
  } state_store_t;

  state_load_t  state_load;
  state_store_t state_store;

  logic [XLEN-1:0] rdata, rdata_unalign;
  logic [7:0] wstrb, rstrb;
  logic arvalid;

  logic [32-1:0] l1d[L1D_SIZE], lsu_rdata;
  logic [L1D_SIZE-1:0] l1d_valid;
  logic [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];

  logic [32-L1D_LEN-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic l1d_cache_hit;
  logic uncacheable;

  logic [32-L1D_LEN-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic l1d_cache_hit_w;
  logic raddr_valid;

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

  logic wen;
  logic [XLEN-1:0] waddr;
  logic [XLEN-1:0] wdata;
  logic [4:0] walu;
  logic wready;

  assign sq_ready = sq_valid[sq_tail] == 0 && (!store_in_sq || sq_valid[store_in_sq_idx] == 0);
  assign out_sq_ready = sq_ready;

  assign wen = sq_valid[sq_head];
  assign wdata = sq_wdata[sq_head];
  assign waddr = sq_waddr[sq_head];
  assign walu = sq_alu[sq_head];

  always @(posedge clock) begin
    if (reset) begin
      sq_head  <= 0;
      sq_tail  <= 0;
      sq_valid <= 0;
    end else begin
      if (iqu_lsu_i.valid && iqu_lsu_i.store && sq_ready) begin
        // Store Commit
        sq_valid[sq_tail] <= 1;
        sq_alu[sq_tail] <= iqu_lsu_i.alu;
        sq_waddr[sq_tail] <= iqu_lsu_i.sq_waddr;
        sq_wdata[sq_tail] <= iqu_lsu_i.sq_wdata;
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
      if (sq_waddr[i] == (iqu_lsu_i.sq_waddr) && !store_in_sq) begin
        store_in_sq = 1;
        store_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
  end

  assign raddr_valid = (  //
      (raddr >= 'h02000048 && raddr < 'h02000050)  // clint
      || (raddr >= 'h0f000000 && raddr < 'h0f002000)  // sram
      || (raddr >= 'h10000000 && raddr < 'h10001000)  // uart/ns16550
      || (raddr >= 'h10010000 && raddr < 'h10011900)  // liteuart0/csr
      || (raddr >= 'h20000000 && raddr < 'h20400000)  // mrom
      || (raddr >= 'h30000000 && raddr < 'h40000000)  // flash
      || (raddr >= 'h80000000 && raddr < 'h88000000)  // psram
      || (raddr >= 'ha0000000 && raddr < 'hc0000000)  // sdram
      || (0));

  assign out_rvalid = state_load == IF_V;

  assign lsu_bus.arvalid = ren && raddr_valid && state_load == IF_L;
  assign lsu_bus.araddr = raddr;
  assign lsu_bus.rstrb = rstrb;

  assign lsu_bus.awvalid = wen && state_store == LS_S_V;
  assign lsu_bus.awaddr = waddr;
  assign lsu_bus.wstrb = wstrb;
  assign lsu_bus.wvalid = wen && state_store == LS_S_V;
  assign lsu_bus.wdata = wdata;

  assign wready = state_store == LS_S_R;

  assign l1d_cache_hit = (l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign addr_tag = raddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = raddr[L1D_LEN+2-1:0+2];
  assign uncacheable = (
         (raddr >= 'h02000048 && raddr < 'h02000050) ||
         (raddr >= 'h0c000000 && raddr < 'h0d000000) ||
         (raddr >= 'h10000000 && raddr < 'h10020000) ||
         (raddr >= 'ha0000000 && raddr < 'hb0000000) ||
         (0)
       );

  assign waddr_tag = waddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = waddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_hit_w = (l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  // load/store unit
  // assign wstrb = (
  //          ({8{ralu == `YSYX_ALU_SB}} & 8'h1) |
  //          ({8{ralu == `YSYX_ALU_SH}} & 8'h3) |
  //          ({8{ralu == `YSYX_ALU_SW}} & 8'hf)
  //        );
  assign wstrb = {{4{1'b0}}, {walu[3:0]}};
  assign rstrb = (
           ({8{ralu == `YSYX_ALU_LB__}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LBU_}} & 8'h1) |
           ({8{ralu == `YSYX_ALU_LH__}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LHU_}} & 8'h3) |
           ({8{ralu == `YSYX_ALU_LW__}} & 8'hf)
         );

  assign rdata_unalign = lsu_rdata;
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
      l1d_valid   <= 0;
      state_load  <= IF_A;
      state_store <= LS_S_V;
    end else begin
      unique case (state_load)
        IF_A: begin
          if (fence_time) begin
            l1d_valid <= 0;
          end
          if (flush_pipeline) begin
          end else if (ren && (!(|sq_valid) || load_in_sq)) begin  // TODO: fix `!(|sq_valid)` requirement
            if (load_in_sq) begin
              state_load <= IF_V;
              lsu_rdata  <= sq_wdata[load_in_sq_idx] << ({{3'b0}, raddr[1:0]} << 3);
            end else if (l1d_cache_hit) begin
              state_load <= IF_V;
              lsu_rdata  <= l1d[addr_idx];
            end else begin
              state_load <= IF_L;
            end
          end
        end
        IF_L: begin
          if (flush_pipeline) begin
            state_load <= IF_A;
          end else if (ren && lsu_bus.rvalid) begin
            state_load <= IF_V;
            if (load_in_sq) begin
              lsu_rdata <= sq_wdata[load_in_sq_idx] << ({{3'b0}, raddr[1:0]} << 3);
            end else begin
              lsu_rdata <= lsu_bus.rdata;
              if (!uncacheable) begin
                l1d[addr_idx] <= lsu_bus.rdata;
                l1d_tag[addr_idx] <= addr_tag;
                l1d_valid[addr_idx] <= 1'b1;
              end
            end
          end
        end
        IF_V: begin
          state_load <= IF_A;
        end
        default: begin
          state_load <= IF_A;
        end
      endcase

      unique case (state_store)
        LS_S_V: begin
          if (wen) begin
            if (lsu_bus.wready) begin
              lsu_wdata   <= wdata;
              state_store <= LS_S_R;
            end
          end
        end
        LS_S_R: begin
          if (walu == `YSYX_SW_WSTRB) begin
            l1d[waddr_idx] <= lsu_wdata;
            l1d_tag[waddr_idx] <= waddr_tag;
            l1d_valid[waddr_idx] <= 1'b1;
          end else if (l1d_cache_hit_w) begin
            if (walu == `YSYX_SB_WSTRB) begin
              l1d[waddr_idx][waddr[1:0]*8+:8] <= lsu_wdata[7:0];
            end else if (walu == `YSYX_SH_WSTRB) begin
              l1d[waddr_idx][waddr[1:0]*8+:16] <= lsu_wdata[15:0];
            end
          end
          state_store <= LS_S_V;
        end
        default: begin
          state_store <= LS_S_V;
        end
      endcase
    end
  end
endmodule
