// Original serial normalization, retained as the equivalence reference.
module norm_gold (
    input logic [51:0] frac,
    input logic [10:0] exp,
    input logic dbl,
    output logic [52:0] mant,
    output int adj
);
  function automatic logic [52:0] norm_mant(input logic [51:0] frac, input logic [10:0] exp,
                                            input logic dbl, output int adj);
    logic [52:0] m;
    int          i;
    begin
      // Unified 1.f format with the leading 1 at bit 52 for both precisions.
      // Single precision left-aligns its 23-bit fraction just below bit 52.
      if (dbl) m = {1'b1, frac};
      else m = {1'b1, frac[22:0], 29'b0};
      adj = 0;
      if (exp == '0) begin
        // subnormal: strip the implicit hidden bit, then normalise upward
        if (dbl) m = {1'b0, frac};
        else m = {1'b0, frac[22:0], 29'b0};
        for (i = 0; i < 52; i = i + 1) begin
          if (!m[52]) begin
            m   = m << 1;
            adj = adj - 1;
          end
        end
      end
      return m;
    end
  endfunction
  always_comb mant = norm_mant(frac, exp, dbl, adj);
endmodule
