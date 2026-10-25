`include "rapt.svh"
`include "rapt_if.svh"
module tb_compressed_legality;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  int checks = 0;
  task automatic check_encoding(input logic [15:0] enc, input bit reserved, input bit nop = 0);
    // Upper parcel must not contaminate a compressed illegal-instruction tval.
    fetched.inst = {16'hcafe, enc};
    #1;
    if (reserved) begin
      if (!decoded.uop.trap || decoded.uop.cause != X'(2) ||
          `RAPT_UOP_TVAL(X, decoded.uop)
          != X'(enc) || decoded.uop.rd != 0)
        $fatal(
            1,
            "reserved compressed RV%0d enc=%h trap=%b cause=%d tval=%h expected_tval=%h rd=%d",
            X,
            enc,
            decoded.uop.trap,
            decoded.uop.cause,
            `RAPT_UOP_TVAL(X, decoded.uop),
            X'(enc),
            decoded.uop.rd
        );
    end else begin
      if (decoded.uop.trap || !decoded.uop.c)
        $fatal(1, "legal compressed encoding RV%0d rejected enc=%h", X, enc);
      if (nop && decoded.uop.rd != 0)
        $fatal(1, "compressed HINT/MOP writes register RV%0d enc=%h", X, enc);
    end
    checks++;
  endtask
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000002);
    fetched.pnpc = fetched.pc + X'(2);
    csr_bcast.fs = 3;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int rd = 0; rd < 32; rd++) begin
        for (int imm = 0; imm < 64; imm++) begin
          check_encoding(16'h4002 | (16'(rd) << 7) | (16'(imm & 31) << 2) | (16'(imm >> 5) << 12),
                         rd == 0);  // C.LWSP
          check_encoding(16'h6002 | (16'(rd) << 7) | (16'(imm & 31) << 2) | (16'(imm >> 5) << 12),
                         X == 64 && rd == 0);  // LDSP/FLWSP
          check_encoding(16'h2001 | (16'(rd) << 7) | (16'(imm & 31) << 2) | (16'(imm >> 5) << 12),
                         X == 64 && rd == 0);  // ADDIW/JAL
        end
        check_encoding(16'h8002 | (16'(rd) << 7), rd == 0);  // C.JR
      end
      for (int imm = 0; imm < 256; imm++)
      for (int rd = 0; rd < 8; rd++) check_encoding((16'(imm) << 5) | (16'(rd) << 2), imm == 0, 0);
      for (int imm = 0; imm < 64; imm++)
      for (int rd = 0; rd < 32; rd++) begin
        bit mop;
        mop = imm == 0 && rd < 16 && (rd & 1) != 0;
        check_encoding(16'h6001 | (16'(rd) << 7) | (16'(imm & 31) << 2) | (16'(imm >> 5) << 12),
                       imm == 0 && !mop, mop || (rd == 0 && imm != 0));
      end
    end
    if (checks != 30816) $fatal(1, "incomplete checks=%0d", checks);
    $display("PASS: RV%0d compressed register/immediate/HINT/MOP checks=%0d", X, checks);
    $finish;
  end
endmodule
