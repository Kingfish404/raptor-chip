`include "rapt.svh"
`include "rapt_if.svh"
module tb_compressed_register_legality;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  int checks = 0;
  task automatic check_encoding(input logic [15:0] encoding, input bit reserved);
    // Upper parcel must not contaminate the compressed illegal tval.
    fetched.inst = {16'hdead, encoding};
    #1;
    if (reserved) begin
      if (!decoded.uop.trap || decoded.uop.cause != X'(2)
          || decoded.uop.tval != X'(encoding) || decoded.uop.rd != 0)
        $fatal(
            1,
            "reserved compressed register RV%0d encoding=%h trap=%b cause=%h tval=%h",
            X,
            encoding,
            decoded.uop.trap,
            decoded.uop.cause,
            decoded.uop.tval
        );
    end else if (decoded.uop.trap || !decoded.uop.c)
      $fatal(1, "valid compressed register rejected RV%0d encoding=%h", X, encoding);
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
    end
    if (checks != 18528) $fatal(1, "incomplete checks=%0d", checks);
    $display("PASS: RV%0d compressed register legality checks=%0d", X, checks);
    $finish;
  end
endmodule
