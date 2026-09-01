// Proves replacement selection and state updates for every optimized PLRU
// geometry used by the cache hierarchy.
module formal_plru (
    input logic       clock,
    input logic       reset,
    input logic       cache_en,
    input logic [7:0] hit_way,
    input logic [7:0] valid_way,
    input logic       cache_set,
    input logic       lru_write_en,
    input logic       invalidate_cache,
    input logic       invalidate_flush
);
  logic [1:0] victim2;
  logic [3:0] victim4;
  logic [7:0] victim8;
  logic [0:0] state2[2];
  logic [2:0] state4[2];
  logic [6:0] state8[2];

  rapt_plru #(.NUMWAYS(2), .SETLEN(1), .NSETS(2)) dut2 (
      .clock, .reset, .cache_en, .hit_way(hit_way[1:0]),
      .valid_way(valid_way[1:0]), .victim_way(victim2), .cache_set,
      .lru_write_en, .paddr_set(1'b0), .invalidate_cache, .invalidate_flush,
      .formal_lru_state(state2)
  );
  rapt_plru #(.NUMWAYS(4), .SETLEN(1), .NSETS(2)) dut4 (
      .clock, .reset, .cache_en, .hit_way(hit_way[3:0]),
      .valid_way(valid_way[3:0]), .victim_way(victim4), .cache_set,
      .lru_write_en, .paddr_set(1'b0), .invalidate_cache, .invalidate_flush,
      .formal_lru_state(state4)
  );
  rapt_plru #(.NUMWAYS(8), .SETLEN(1), .NSETS(2)) dut8 (
      .clock, .reset, .cache_en, .hit_way,
      .valid_way, .victim_way(victim8), .cache_set,
      .lru_write_en, .paddr_set(1'b0), .invalidate_cache, .invalidate_flush,
      .formal_lru_state(state8)
  );

  logic       ref2[2];
  logic [2:0] ref4[2];
  logic [6:0] ref8[2];
  logic [1:0] exp2;
  logic [3:0] exp4;
  logic [7:0] exp8;
  logic [2:0] idx8;
  logic [1:0] idx4;

  always_comb begin
    exp2 = '0;
    if (!valid_way[0]) exp2[0] = 1'b1;
    else if (!valid_way[1]) exp2[1] = 1'b1;
    else exp2[ref2[cache_set] ? 0 : 1] = 1'b1;

    exp4 = '0;
    if (!valid_way[0]) exp4[0] = 1'b1;
    else if (!valid_way[1]) exp4[1] = 1'b1;
    else if (!valid_way[2]) exp4[2] = 1'b1;
    else if (!valid_way[3]) exp4[3] = 1'b1;
    else begin
      idx4[1] = ~ref4[cache_set][0];
      idx4[0] = idx4[1] ? ~ref4[cache_set][2] : ~ref4[cache_set][1];
      exp4[idx4] = 1'b1;
    end

    exp8 = '0;
    if (!valid_way[0]) exp8[0] = 1'b1;
    else if (!valid_way[1]) exp8[1] = 1'b1;
    else if (!valid_way[2]) exp8[2] = 1'b1;
    else if (!valid_way[3]) exp8[3] = 1'b1;
    else if (!valid_way[4]) exp8[4] = 1'b1;
    else if (!valid_way[5]) exp8[5] = 1'b1;
    else if (!valid_way[6]) exp8[6] = 1'b1;
    else if (!valid_way[7]) exp8[7] = 1'b1;
    else begin
      idx8[2] = ~ref8[cache_set][0];
      idx8[1] = idx8[2] ? ~ref8[cache_set][2] : ~ref8[cache_set][1];
      unique case (idx8[2:1])
        2'b00: idx8[0] = ~ref8[cache_set][3];
        2'b01: idx8[0] = ~ref8[cache_set][4];
        2'b10: idx8[0] = ~ref8[cache_set][5];
        default: idx8[0] = ~ref8[cache_set][6];
      endcase
      exp8[idx8] = 1'b1;
    end
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) begin
    f_past_valid <= 1'b1;
    if (reset) begin
      ref2[0] <= '0; ref2[1] <= '0;
      ref4[0] <= '0; ref4[1] <= '0;
      ref8[0] <= '0; ref8[1] <= '0;
    end else if (cache_en) begin
      if (invalidate_cache && !invalidate_flush) begin
        ref2[0] <= '0; ref2[1] <= '0;
        ref4[0] <= '0; ref4[1] <= '0;
        ref8[0] <= '0; ref8[1] <= '0;
      end else if (lru_write_en) begin
        ref2[cache_set] <= hit_way[1];
        ref4[cache_set][0] <= |hit_way[3:2];
        ref4[cache_set][1] <= hit_way[1];
        ref4[cache_set][2] <= hit_way[3];
        ref8[cache_set][0] <= |hit_way[7:4];
        ref8[cache_set][1] <= |hit_way[3:2];
        ref8[cache_set][2] <= |hit_way[7:6];
        ref8[cache_set][3] <= hit_way[1];
        ref8[cache_set][4] <= hit_way[3];
        ref8[cache_set][5] <= hit_way[5];
        ref8[cache_set][6] <= hit_way[7];
      end
    end
  end

  always_comb begin
    assume(f_past_valid || reset);
    if (lru_write_en)
      assume((hit_way != '0) && ((hit_way & (hit_way - 8'd1)) == '0));
    if (f_past_valid) begin
      assert(state2[0] == ref2[0]);
      assert(state2[1] == ref2[1]);
      assert(state4[0] == ref4[0]);
      assert(state4[1] == ref4[1]);
      assert(state8[0] == ref8[0]);
      assert(state8[1] == ref8[1]);
      assert(victim2 == exp2);
      assert(victim4 == exp4);
      assert(victim8 == exp8);
      assert((victim2 != '0) && ((victim2 & (victim2 - 2'd1)) == '0));
      assert((victim4 != '0) && ((victim4 & (victim4 - 4'd1)) == '0));
      assert((victim8 != '0) && ((victim8 & (victim8 - 8'd1)) == '0));
    end
  end

  always_ff @(posedge clock) begin
    if (f_past_valid && !reset) begin
      cover(lru_write_en && cache_set && (&valid_way));
      cover(invalidate_cache && !invalidate_flush);
    end
  end
endmodule
