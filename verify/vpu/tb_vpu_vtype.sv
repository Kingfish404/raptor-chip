module tb_vpu_vtype #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64
);
  logic [XLEN-1:0] requested_vtype, avl, current_vtype, current_vl;
  logic avl_max, keep_vl;
  logic [XLEN-1:0] next_vtype, next_vl, vlmax;
  logic vill;
  int checks = 0;
  rapt_vpu_vtype #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) dut (
      .*
  );

  // Reference uses rational LMUL arithmetic, independent of the RTL's
  // constant decode table. Return 0 for configurations this ELEN rejects.
  function automatic longint unsigned reference_max(input logic [XLEN-1:0] vt);
    longint unsigned numerator, denominator, sew;
    numerator = 1;
    denominator = 1;
    case (vt[2:0])
      0: numerator = 1;
      1: numerator = 2;
      2: numerator = 4;
      3: numerator = 8;
      5: denominator = 8;
      6: denominator = 4;
      7: denominator = 2;
      default: return 0;
    endcase
    sew = 64'd8 << vt[5:3];
    if ((vt >> 8) != 0 || sew > 64'(ELEN) || sew * denominator > ELEN * numerator) return 0;
    return VLEN * numerator / (sew * denominator);
  endfunction

  task automatic check;
    longint unsigned m, old_m, expected_vl;
    logic bad;
    logic [XLEN-1:0] expected_type;
    m = reference_max(requested_vtype);
    old_m = reference_max(current_vtype);
    bad = m == 0 || (keep_vl && (m != old_m || old_m == 0 || 64'(current_vl) > m));
    expected_vl = 64'(avl) < m ? 64'(avl) : m;
    if (avl_max) expected_vl = m;
    if (keep_vl) expected_vl = 64'(current_vl);
    expected_type = requested_vtype;
    if (bad) begin
      expected_vl = 0;
      expected_type = XLEN'(1) << (XLEN-1);
      m = 0;
    end
    #1;
    if (vill != bad || 64'(vlmax) != m || 64'(next_vl) != expected_vl || next_vtype != expected_type)
      $fatal(
          1,
          "vtype=%h old=%h old_vl=%0d avl=%0d max=%b keep=%b: got %h/%0d/%0d vill=%b expected %h/%0d/%0d vill=%b",
          requested_vtype,
          current_vtype,
          current_vl,
          avl,
          avl_max,
          keep_vl,
          next_vtype,
          next_vl,
          vlmax,
          vill,
          expected_type,
          expected_vl,
          m,
          bad
      );
    checks++;
  endtask

  initial begin
    current_vtype = 0;
    current_vl = 0;
    avl = 0;
    avl_max = 0;
    keep_vl = 0;
    for (int vt = 0; vt < 256; vt++) begin
      requested_vtype = XLEN'(vt);
      // Around every VLMAX boundary, including fractional LMUL and AVL=0.
      for (int a = 0; a <= 2 * VLEN; a = (a < 40 ? a + 1 : a * 2)) begin
        avl = XLEN'(a);
        check();
      end
      for (int delta = -1; delta <= 1; delta++) begin
        avl = XLEN'(reference_max(requested_vtype) + 64'(delta));
        check();
      end
      avl = '1;
      check();
      avl_max = 1;
      avl = 0;
      check();
      avl_max = 0;
      keep_vl = 1;
      for (int old = 0; old < 256; old++) begin
        current_vtype = XLEN'(old);
        current_vl = XLEN'(reference_max(current_vtype));
        check();
        current_vl >>= 1;
        check();
      end
      current_vtype = XLEN'(1) << (XLEN-1);
      current_vl = 0;
      check();
      keep_vl = 0;
      for (int bitno = 8; bitno < XLEN; bitno++) begin
        requested_vtype = XLEN'(vt) | (XLEN'(1) << bitno);
        check();
      end
    end
    $display("PASS vtype XLEN=%0d VLEN=%0d ELEN=%0d checks=%0d", XLEN, VLEN, ELEN, checks);
    $finish;
  end
endmodule
