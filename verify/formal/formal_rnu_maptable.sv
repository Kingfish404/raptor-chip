`include "rapt.svh"
`include "rapt_rnu_internal_if.svh"

// Tracks an arbitrary architectural register.  Because watch_addr is an
// anyconst, proving this single reference state proves every MAP/RAT entry.
module formal_rnu_maptable #(
    // Four entries retain every alias/WAW/flush behavior while making the
    // parameterized per-entry proof much smaller than the production array.
    parameter int RNUM = 4,
    parameter int PLEN = 3,
    parameter int RLEN = $clog2(RNUM)
) (
    input logic clock,
    input logic reset,
    input logic flush_pipe,
    input logic map_wen_a,
    input logic [RLEN-1:0] map_waddr_a,
    input logic [PLEN-1:0] map_wdata_a,
    input logic map_wen_b,
    input logic [RLEN-1:0] map_waddr_b,
    input logic [PLEN-1:0] map_wdata_b,
    input logic rat_wen_a,
    input logic [RLEN-1:0] rat_waddr_a,
    input logic [PLEN-1:0] rat_wdata_a,
    input logic rat_wen_b,
    input logic [RLEN-1:0] rat_waddr_b,
    input logic [PLEN-1:0] rat_wdata_b,
    input logic [RLEN-1:0] read_addr,
    input logic [RLEN-1:0] watch_addr
);

  rnu_mt_if #(.RLEN(RLEN), .PLEN(PLEN)) mt();
  logic [PLEN-1:0] formal_map_watch, formal_rat_watch;
  assign mt.flush_pipe = flush_pipe;
  assign mt.map_wen_a = map_wen_a;
  assign mt.map_waddr_a = map_waddr_a;
  assign mt.map_wdata_a = map_wdata_a;
  assign mt.map_wen_b = map_wen_b;
  assign mt.map_waddr_b = map_waddr_b;
  assign mt.map_wdata_b = map_wdata_b;
  assign mt.rat_wen_a = rat_wen_a;
  assign mt.rat_waddr_a = rat_waddr_a;
  assign mt.rat_wdata_a = rat_wdata_a;
  assign mt.rat_wen_b = rat_wen_b;
  assign mt.rat_waddr_b = rat_waddr_b;
  assign mt.rat_wdata_b = rat_wdata_b;
  assign mt.map_raddr_a = read_addr;
  assign mt.map_raddr_b = read_addr;
  assign mt.map_raddr_c = read_addr;
  assign mt.map_raddr_d = read_addr;
  assign mt.map_raddr_e = read_addr;
  assign mt.map_raddr_f = read_addr;

  rapt_rnu_maptable #(.RNUM(RNUM), .PLEN(PLEN)) dut (
      .clock, .reset, .mt,
      .map_snapshot(), .rat_snapshot(),
      .formal_watch_addr(watch_addr),
      .formal_map_watch, .formal_rat_watch
  );

  logic [PLEN-1:0] ref_map, ref_rat;
  logic [RLEN-1:0] watch_addr_q;
  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) begin
    f_past_valid <= 1'b1;
    watch_addr_q <= watch_addr;
    if (reset) begin
      ref_map <= PLEN'(watch_addr);
      ref_rat <= PLEN'(watch_addr);
    end else begin
      if (rat_wen_b && rat_waddr_b == watch_addr)
        ref_rat <= rat_wdata_b;
      else if (rat_wen_a && rat_waddr_a == watch_addr)
        ref_rat <= rat_wdata_a;

      if (flush_pipe) begin
        if (rat_wen_b && rat_waddr_b == watch_addr)
          ref_map <= rat_wdata_b;
        else if (rat_wen_a && rat_waddr_a == watch_addr)
          ref_map <= rat_wdata_a;
        else
          ref_map <= ref_rat;
      end else if (map_wen_b && map_waddr_b == watch_addr) begin
        ref_map <= map_wdata_b;
      end else if (map_wen_a && map_waddr_a == watch_addr) begin
        ref_map <= map_wdata_a;
      end
    end
  end

  always_comb begin
    assume(f_past_valid || reset);
    if (f_past_valid) assume(watch_addr == watch_addr_q);
    if (f_past_valid) begin
      assert(formal_map_watch == ref_map);
      assert(formal_rat_watch == ref_rat);
      if (read_addr == watch_addr) begin
        assert(mt.map_rdata_a == formal_map_watch);
        assert(mt.map_rdata_b == formal_map_watch);
        assert(mt.map_rdata_c == formal_map_watch);
        assert(mt.map_rdata_d == formal_map_watch);
        assert(mt.map_rdata_e == formal_map_watch);
        assert(mt.map_rdata_f == formal_map_watch);
      end
    end
  end

  always_ff @(posedge clock) begin
    if (f_past_valid && !reset) begin
      cover(map_wen_a && map_wen_b && map_waddr_a == map_waddr_b);
      cover(flush_pipe && rat_wen_a && rat_wen_b && rat_waddr_a == rat_waddr_b);
    end
  end
endmodule
