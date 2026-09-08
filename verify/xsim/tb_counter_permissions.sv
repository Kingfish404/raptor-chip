`include "rapt.svh"
`include "rapt_if.svh"
module tb_counter_permissions;
  localparam int XLEN = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  rapt_decode_slot #(.XLEN(XLEN)) dut (.*);
  int checks = 0;
  logic [11:0] addresses [12] = '{12'hc00,12'hc01,12'hc02,
      12'hc80,12'hc81,12'hc82,12'hb00,12'hb02,12'hb80,12'hb82,
      12'hb01,12'hb81};
  initial begin
    fetched = '0;
    fetched.pc = XLEN'(32'h80000000);
    fetched.pnpc = fetched.pc + XLEN'(4);
    csr_bcast.fs = 3;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    csr_bcast.menvcfg_stce = 0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2)
      for (int men = 0; men < 8; men++)
      for (int sen = 0; sen < 8; sen++)
      for (int a = 0; a < 12; a++)
      for (int op = 1; op < 8; op++)
      if (op != 4)
        for (int src = 0; src < 32; src++)
        for (int dst = 0; dst < 2; dst++) begin
          bit legal, write_intent;
          logic [31:0] inst;
          write_intent = op == 1 || op == 5 || src != 0;
          if (a < 6) begin
            legal = (a < 3 || XLEN == 32) && !write_intent;
            if (priv == 1) legal &= ((men >> (a % 3)) & 1) != 0;
            if (priv == 0) legal &= ((men >> (a % 3)) & (sen >> (a % 3)) & 1) != 0;
          end else if (a < 10) legal = priv == 3 && (a < 8 || XLEN == 32);
          else legal = 0;  // No architectural mtime/mtimeh CSR at b01/b81.
          csr_bcast.priv = 2'(priv);
          csr_bcast.mcounteren = 3'(men);
          csr_bcast.scounteren = 3'(sen);
          inst = {addresses[a],5'(src),3'(op),dst ? 5'd31 : 5'd0,7'h73};
          fetched.inst = inst;
          #1;
          if (decoded.uop.trap !== !legal || (!legal &&
          (decoded.uop.cause != XLEN'(2) || decoded.uop.tval != XLEN'(inst))))
            $fatal(
                1,
                "counter permissions RV%0d priv=%0d men=%0d sen=%0d inst=%h legal=%b trap=%b cause=%h tval=%h",
                XLEN,
                priv,
                men,
                sen,
                inst,
                legal,
                decoded.uop.trap,
                decoded.uop.cause,
                decoded.uop.tval
            );
          checks++;
        end
    $display("PASS: RV%0d counter permission/illegal-tval %0d checks", XLEN, checks);
    $finish;
  end
endmodule
