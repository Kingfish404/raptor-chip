`include "rapt.svh"
`include "rapt_if.svh"

module tb_pmp_permissions;
  localparam int X = `RAPT_XLEN;
  localparam int P = `RAPT_PADDR_BITS;
  localparam int A = P - 2;
  localparam int N = `RAPT_PMP_NUM;
  logic [X-1:0] addr;
  logic [3:0] size_m1;
  logic [1:0] priv;
  logic op_r, op_w, op_x;
  logic [A-1:0] pmp_raw_addr[N], pmp_napot_mask[N];
  logic [N-1:0] pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l;
  logic [N-1:0] pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot;
  logic fault, fault_lo_o, fault_read_o, fault_write_o;
  rapt_pmp_permissions #(
      .XLEN(X),
      .PADDR_BITS(P)
  ) dut (
      .*
  );

  int unsigned rng = 32'h504d5039;
  int allow_read = 0, allow_write = 0, deny_read = 0, deny_write = 0;
  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  // Independent byte walk: lowest entry overlapping any byte must contain
  // every byte. No endpoint formula, parallel priority encoder or range-start
  // shortcut is shared with the implementation.
  function automatic bit reference_fault(input bit write_access);
    bit any_byte, all_bytes, hit;
    logic [P-1:0] byte_addr;
    logic [A-1:0] word_addr, lower;
    for (int e = 0; e < N; e++) begin
      any_byte = 0;
      all_bytes = 1;
      lower = e == 0 ? '0 : pmp_raw_addr[e-1];
      for (int b = 0; b <= int'(size_m1); b++) begin
        byte_addr = P'(addr) + P'(b);
        word_addr = byte_addr[P-1:2];
        hit = (pmp_mode_tor[e] && word_addr >= lower && word_addr < pmp_raw_addr[e])
            || (pmp_mode_na4[e] && word_addr == pmp_raw_addr[e])
            || (pmp_mode_napot[e]
                && (word_addr & ~pmp_napot_mask[e])
                   == (pmp_raw_addr[e] & ~pmp_napot_mask[e]));
        any_byte |= hit;
        all_bytes &= hit;
      end
      if (any_byte) begin
        if (!all_bytes) return 1;
        if (priv == `RAPT_PRIV_M && !pmp_cfg_l[e]) return 0;
        return !(write_access ? pmp_cfg_w[e] : pmp_cfg_r[e]);
      end
    end
    return priv != `RAPT_PRIV_M;
  endfunction

  initial begin
    for (int n = 0; n < 40000; n++) begin
      automatic int selected;
      automatic logic [A-1:0] region;
      pmp_mode_off = 0;
      pmp_mode_tor = 0;
      pmp_mode_na4 = 0;
      pmp_mode_napot = 0;
      pmp_cfg_r = N'(random_word());
      pmp_cfg_w = N'(random_word());
      pmp_cfg_x = N'(random_word());
      pmp_cfg_l = N'(random_word());
      for (int e = 0; e < N; e++) begin
        pmp_raw_addr[e] = A'({random_word(), random_word()});
        // Mix dense overlapping regions and full-width physical addresses.
        if (n % 3 == 0) pmp_raw_addr[e] &= A'(255);
        if (n % 29 == 0) pmp_raw_addr[e] = '1;
        if (n % 31 == 0) pmp_raw_addr[e] = '0;
        pmp_napot_mask[e] = pmp_raw_addr[e] ^ (pmp_raw_addr[e] + A'(1));
        case (random_word() % 4)
          0: pmp_mode_off[e] = 1;
          1: pmp_mode_tor[e] = 1;
          2: pmp_mode_na4[e] = 1;
          3: pmp_mode_napot[e] = 1;
        endcase
      end
      selected = int'(random_word() % N);
      region = pmp_raw_addr[selected];
      if (n % 2 == 0) region &= ~pmp_napot_mask[selected];
      addr = X'({region, 2'b00}) + X'(int'(random_word() % 33) - 16);
      size_m1 = 4'(n % 16);
      priv = 2'(random_word() % 4);
      op_w = (n % 2 == 0);
      op_r = !op_w;
      op_x = 0;
      #1;
      assert (fault_read_o == reference_fault(0))
      else $fatal(1, "PMP R n=%0d", n);
      assert (fault_write_o == reference_fault(1))
      else $fatal(1, "PMP W n=%0d", n);
      assert (fault == (op_w ? fault_write_o : fault_read_o))
      else $fatal(1, "PMP request selection n=%0d", n);
      if (fault_read_o) deny_read++;
      else allow_read++;
      if (fault_write_o) deny_write++;
      else allow_write++;
    end
    assert (allow_read > 100 && allow_write > 100 && deny_read > 100 && deny_write > 100)
    else $fatal(1, "PMP permission coverage");
    $display("PASS: PMP shared range XLEN=%0d read=%0d/%0d write=%0d/%0d", X, allow_read,
             deny_read, allow_write, deny_write);
    $finish;
  end
endmodule
