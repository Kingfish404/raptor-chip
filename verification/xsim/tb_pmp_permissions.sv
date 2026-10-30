`include "rapt.svh"
`include "rapt_if.svh"

module tb_pmp_permissions;
  localparam int X = `RAPT_XLEN;
  localparam int P = `RAPT_PADDR_BITS;
  localparam int A = P - 2;
  localparam int G = `RAPT_PMP_GRANULARITY_LOG2 - 2;
  localparam logic [A-1:0] LowMask = (A'(1) << G) - 1;
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
      lower = e == 0 ? '0 : pmp_raw_addr[e-1] & ~LowMask;
      for (int b = 0; b <= int'(size_m1); b++) begin
        byte_addr = P'(addr) + P'(b);
        word_addr = byte_addr[P-1:2];
        hit = (pmp_mode_tor[e] && word_addr >= lower && word_addr < (pmp_raw_addr[e] & ~LowMask))
            || (G == 0 && pmp_mode_na4[e] && word_addr == pmp_raw_addr[e])
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
        if (n % 3 == 0) pmp_raw_addr[e] &= A'(255 << G);
        if (n % 29 == 0) pmp_raw_addr[e] = '1;
        if (n % 31 == 0) pmp_raw_addr[e] = '0;
        pmp_napot_mask[e] = (pmp_raw_addr[e] | (LowMask >> 1))
            ^ ((pmp_raw_addr[e] | (LowMask >> 1)) + A'(1));
        case (random_word() % 4)
          0: pmp_mode_off[e] = 1;
          1: pmp_mode_tor[e] = 1;
          2: if (G == 0) pmp_mode_na4[e] = 1;
             else pmp_mode_off[e] = 1;
          3: pmp_mode_napot[e] = 1;
        endcase
      end
      selected = int'(random_word() % N);
      region = pmp_raw_addr[selected] & ~LowMask;
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

// ---- tb_pmp_shared_equiv ----
`include "rapt.svh"
`include "rapt_if.svh"

// Compare the shared fetch/PTW/slow checker against three independent
// instances of the original permission checker for arbitrary decoded PMP state.
module tb_pmp_shared_equiv;
  localparam int X = `RAPT_XLEN;
  localparam int P = `RAPT_PADDR_BITS;
  localparam int A = P - 2;
  localparam int G = `RAPT_PMP_GRANULARITY_LOG2 - 2;
  localparam int N = `RAPT_PMP_NUM;
  localparam logic [A-1:0] LowMask = (A'(1) << G) - 1;
  csr_bcast_if csr ();
  pmp_state_if pmp ();
  logic [X-1:0] addr[3];
  logic [3:0] shared_size;
  logic [1:0] shared_priv;
  logic shared_read, shared_active, is_c;
  logic fetch_fault, fetch_lo, ptw_fault, shared_fault, shared_read_fault;
  wire selected_fault = shared_read ? shared_read_fault : shared_fault;
  logic [2:0] reference_fault, reference_lo;
  wire reference_fetch = is_c ? reference_lo[0] : reference_fault[0];
  rapt_l1i_access #(
      .Lookahead(1'b0),
      .ShareSlowPath(1'b1)
  ) u_shared (
      .csr_bcast(csr),
      .pmp_state(pmp),
      .shared_check_active(shared_active),
      .shared_check_addr(addr[2]),
      .shared_check_size_m1(shared_size),
      .shared_check_priv(shared_priv),
      .shared_check_read(shared_read),
      .shared_check_fault(shared_fault),
      .shared_check_read_fault(shared_read_fault),
      .pc_ifu(addr[0]),
      .ptw_araddr(addr[1]),
      .lookahead_n1_addr('0),
      .lookahead_n2_addr('0),
      .lookahead_n3_addr('0),
      .lookahead_n4_addr('0),
      .sram_data_ready(1'b1),
      .is_c(is_c),
      .tlb_hit(1'b0),
      .itlb_pte('0),
      .ptw_result_pte('0),
      .pf_fetch_tlb(),
      .pf_fetch_ptw(),
      .pmp_fetch_pmp_fault(fetch_fault),
      .pmp_fetch_fault_lo(fetch_lo),
      .pmp_iptw_fault(ptw_fault),
      .pmp_n1_fetch_fault(),
      .pmp_n2_fetch_fault(),
      .pmp_n3_fetch_fault(),
      .pmp_n4_fetch_fault()
  );
  for (genvar i = 0; i < 3; i++) begin : g_original
    wire read_op = i == 1 || (i == 2 && shared_read);
    rapt_pmp_permissions u_check (
        .addr(addr[i]),
        .size_m1(i == 0 ? 4'd3 : (i == 1 ? 4'(X / 8 - 1) : shared_size)),
        .priv(i == 0 ? csr.priv : (i == 1 ? `RAPT_PRIV_S : shared_priv)),
        .op_r(read_op),
        .op_w(1'b0),
        .op_x(!read_op),
        .pmp_raw_addr(pmp.pmp_raw_addr),
        .pmp_napot_mask(pmp.pmp_napot_mask),
        .pmp_cfg_r(pmp.pmp_cfg_r),
        .pmp_cfg_w(pmp.pmp_cfg_w),
        .pmp_cfg_x(pmp.pmp_cfg_x),
        .pmp_cfg_l(pmp.pmp_cfg_l),
        .pmp_mode_off(pmp.pmp_mode_off),
        .pmp_mode_tor(pmp.pmp_mode_tor),
        .pmp_mode_na4(pmp.pmp_mode_na4),
        .pmp_mode_napot(pmp.pmp_mode_napot),
        .fault(reference_fault[i]),
        .fault_lo_o(reference_lo[i]),
        .fault_read_o(),
        .fault_write_o()
    );
  end
  int unsigned rng = 32'h504d5039;
  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  int queries = 0;
  initial begin
    for (int trial = 0; trial < 4096; trial++) begin
      pmp.pmp_cfg_r = N'(random_word());
      pmp.pmp_cfg_w = N'(random_word());
      pmp.pmp_cfg_x = N'(random_word());
      pmp.pmp_cfg_l = N'(random_word());
      for (int e = 0; e < N; e++) begin
        automatic int mode = int'(random_word() % 4);
        pmp.pmp_raw_addr[e] = A'({random_word(), random_word()});
        if (trial % 3 == 0) pmp.pmp_raw_addr[e] &= A'(255 << G);
        if (trial % 17 == 0) pmp.pmp_raw_addr[e] = '0;
        if (trial % 19 == 0) pmp.pmp_raw_addr[e] = '1;
        pmp.pmp_napot_mask[e] = (pmp.pmp_raw_addr[e] | (LowMask >> 1))
            ^ ((pmp.pmp_raw_addr[e] | (LowMask >> 1)) + A'(1));
        pmp.pmp_mode_off[e] = mode == 0 || (G != 0 && mode == 2);
        pmp.pmp_mode_tor[e] = mode == 1;
        pmp.pmp_mode_na4[e] = G == 0 && mode == 2;
        pmp.pmp_mode_napot[e] = mode == 3;
      end
      for (int sample = 0; sample < 48; sample ++) begin
        automatic int owner = sample % 3;
        for (int port_idx = 0; port_idx < 3; port_idx++) begin
          automatic int entry = int'(random_word() % N);
          automatic logic [A-1:0] word_addr = pmp.pmp_raw_addr[entry] & ~LowMask;
          case (sample % 4)
            0: word_addr &= ~pmp.pmp_napot_mask[entry];
            1: word_addr |= pmp.pmp_napot_mask[entry];
            2: word_addr = A'({random_word(), random_word()});
            default: if (trial % 2 == 0) word_addr = '1;
          endcase
          addr[port_idx] = X'({word_addr, 2'b0}) + X'(int'(random_word() % 33) - 16);
        end
        addr[0][0] = 0;
        addr[1] &= ~X'(X / 8 - 1);
        csr.priv = 2'(random_word());
        shared_priv = 2'(random_word());
        shared_size = 4'(sample / 3);
        shared_read = 1'(random_word());
        shared_active = owner == 2;
        is_c = 1'(random_word());
        #1;
        if (owner == 0) begin
          `RAPT_SVA_IMM(PMP_SHARED_FETCH, fetch_fault == reference_fetch)
          `RAPT_SVA_IMM(PMP_SHARED_FETCH_LOW, fetch_lo == reference_lo[0])
        end else if (owner == 1) begin
          automatic
          logic
          expected = reference_fault[1] || !rapt_pkg::addr_ptw_readable(
              addr[1], 4'(X / 8 - 1)
          );
          `RAPT_SVA_IMM(PMP_SHARED_WALK, ptw_fault == expected)
        end else begin
          `RAPT_SVA_IMM(PMP_SHARED_SLOW, selected_fault == reference_fault[2])
        end
        queries++;
      end
    end
`ifdef RAPT_SVA_ACTIVE
    $display("PASS: PMP shared fetch/PTW/slow equivalence XLEN=%0d queries=%0d", X, queries);
`endif
    $finish;
  end
endmodule
