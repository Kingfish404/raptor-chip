module tb_cache_replacement;
  logic clock = 0;
  logic [2:0] done = '0;
  always #5 clock = ~clock;
  for (genvar config_idx = 0; config_idx < 3; config_idx++) begin : g_case
    localparam int Ways = 2 << config_idx;
    localparam int WayBits = $clog2(Ways);
    logic reset = 1, invalidate = 0;
    logic [1:0] read_set[2], update_set[3];
    logic [WayBits-1:0] update_way[3];
    logic [2:0] update_valid = '0;
    wire [WayBits-1:0] victim[2];
    logic [Ways-1:0] match_way = '0, valid_way = '0;
    wire [WayBits-1:0] selected;
    bit model[4][Ways-1];
    logic [63:0] rng = 64'h1020304050607080 ^ 64'(Ways);
    rapt_cache_plru #(
        .Ways(Ways),
        .SetBits(2),
        .UpdatePorts(3)
    ) dut (
        .*
    );
    rapt_cache_fill_select #(
        .Ways(Ways)
    ) choose (
        .match_way,
        .valid_way,
        .victim(victim[0]),
        .selected
    );

    // Independent interval-based tree model; untouched subtrees retain history.
    task automatic model_step;
      int node, lo, hi, mid;
      if (reset || invalidate) foreach (model[s, n]) model[s][n] = 0;
      else
        for (int p = 0; p < 3; p++)
          if (update_valid[p]) begin
            node = 0;
            lo = 0;
            hi = Ways;
            while (hi - lo > 1) begin
              mid = (lo + hi) / 2;
              model[update_set[p]][node] = int'(update_way[p]) >= mid;
              if (int'(update_way[p]) >= mid) begin
                lo = mid;
                node = 2*node + 2;
              end else begin
                hi = mid;
                node = 2*node + 1;
              end
            end
          end
    endtask
    task automatic check_result;
      int node, lo, hi, mid, expected, fill_expected;
      for (int p = 0; p < 2; p++) begin
        node = 0;
        lo = 0;
        hi = Ways;
        while (hi - lo > 1) begin
          mid = (lo + hi) / 2;
          if (!model[read_set[p]][node]) begin
            lo = mid;
            node = 2*node + 2;
          end else begin
            hi = mid;
            node = 2*node + 1;
          end
        end
        expected = lo;
        if (int'(victim[p]) != expected)
          $fatal(1, "PLRU ways=%0d port=%0d got=%0d expected=%0d", Ways, p, victim[p], expected);
      end
      fill_expected = int'(victim[0]);
      for (int w = 0; w < Ways; w++)
        if (!valid_way[w]) begin
          fill_expected = w;
          break;
        end
      for (int w = 0; w < Ways; w++)
        if (match_way[w]) begin
          fill_expected = w;
          break;
        end
      if (int'(selected) != fill_expected) $fatal(1, "fill priority / way-zero sentinel");
    endtask
    initial begin
      read_set[0] = 0;
      read_set[1] = 1;
      foreach (update_set[p]) begin
        update_set[p] = '0;
        update_way[p] = '0;
      end
      @(posedge clock);
      model_step();
      #1;
      check_result();
      for (int cycle_idx = 0; cycle_idx < 5000; cycle_idx++) begin
        @(negedge clock);
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        reset = 0;
        invalidate = cycle_idx % 101 == 0;
        update_valid = rng[2:0];
        for (int p = 0; p < 3; p++) begin
          update_set[p] = 2'(rng >> (3 + p*6));
          update_way[p] = WayBits'(rng >> (5 + p*6));
        end
        read_set[0] = rng[22:21];
        read_set[1] = rng[24:23];
        match_way = Ways'(rng >> 25);
        valid_way = Ways'(rng >> 33);
        #1;
        check_result();
        @(posedge clock);
        model_step();
        #1;
        check_result();
      end
      // Invalid way zero must outrank a nonzero policy victim.
      match_way = '0;
      valid_way = '1;
      valid_way[0] = 0;
      #1;
      if (selected != 0) $fatal(1, "invalid way zero was overwritten");
      done[config_idx] = 1;
    end
  end
  initial begin
    wait (&done);
    $display("PASS: 2/4/8-way replacement, independent queries, ordered updates, fill priority");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "replacement timeout");
  end
endmodule
