`include "rapt.svh"
`include "rapt_if.svh"
module tb_zexth_decode_alu;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  logic [X-1:0] a, result;
  logic [31:0] inst;
  integer count=0;
  rapt_ieu_alu #(
      .XLEN(X)
  ) alu (
      .s1(a),
      .s2(X'(0)),
      .op(decoded.uop.execute.int_op.alu),
      .word(decoded.uop.execute.int_op.word),
      .out_r(result)
  );
  task automatic check_one(input bit legal_op, input int rd, input int rs, input bit compressed);
    fetched.inst = inst;
    #1;
    if (legal_op) begin
      if (decoded.uop.trap || decoded.uop.rd!=5'(rd) || decoded.rs1!=5'(rs)
          || decoded.uop.c!=compressed || result!=X'(a[15:0]))
        $fatal(1, "ZEXT.H decode/result RV%0d inst=%h a=%h result=%h", X, inst, a, result);
    end else if (!decoded.uop.trap || decoded.uop.cause!=X'(2)
                 || decoded.uop.tval!=X'(inst) || decoded.uop.rd!=0)
      $fatal(1, "wrong-XLEN ZEXT.H accepted RV%0d inst=%h", X, inst);
    count++;
  endtask
  initial begin
    fetched='0;
    fetched.pc=X'(32'h80000000);
    fetched.pnpc=fetched.pc+X'(4);
    csr_bcast.fs=0;
    csr_bcast.tvm=1;
    csr_bcast.tw=1;
    csr_bcast.tsr=1;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      // Every low halfword with nonzero upper bits, native and compressed.
      for (int val = 0; val < 65536; val++) begin
        a=~X'(65535)|X'(val);
        inst=(X==64 ? 32'h0800443b : 32'h08004433)|(32'(8)<<15);
        check_one(1, 8, 8, 0);
        inst = 32'h00009c69;  // C.ZEXT.H s0
        check_one(1, 8, 8, 1);
      end
      for (int shortreg = 0; shortreg < 8; shortreg++) begin
        a=~X'(0);
        inst=32'h00009c69|(32'(shortreg)<<7);
        check_one(1, 8 + shortreg, 8 + shortreg, 1);
        if (decoded.uop.inst[6:0] != (X == 64 ? 7'h3b : 7'h33))
          $fatal(1, "compressed expansion chose wrong XLEN opcode");
      end
      for (int form64 = 0; form64 < 2; form64++)
      for (int rd = 0; rd < 32; rd++)
      for (int rs = 0; rs < 32; rs++) begin
        a=~X'(0);
        inst=(form64!=0 ? 32'h0800403b : 32'h08004033)|(32'(rd)<<7)|(32'(rs)<<15);
        check_one((X == 64) == (form64 != 0), rd, rs, 0);
      end
    end
    if (count != 399384) $fatal(1, "incomplete checks=%0d", count);
    $display("PASS: RV%0d ZEXT.H native/compressed and XLEN checks=%0d", X, count);
    $finish;
  end
endmodule
