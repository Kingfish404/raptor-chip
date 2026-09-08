`include "rapt.svh"
`include "rapt_if.svh"
module tb_svinval_decode;
  localparam int XLEN = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded, reference_decode;
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  rapt_decode_slot #(.XLEN(XLEN)) dut (.*);
  int checks = 0;
  task automatic legality(input logic [31:0] inst, input bit legal);
    fetched.inst = inst;
    #1;
    if (decoded.uop.trap !== !legal || (!legal &&
        (decoded.uop.cause != XLEN'(2) || decoded.uop.tval != XLEN'(inst))))
      $fatal(
          1,
          "Svinval RV%0d priv=%0d TVM=%b inst=%h legal=%b trap=%b",
          XLEN,
          csr_bcast.priv,
          csr_bcast.tvm,
          inst,
          legal,
          decoded.uop.trap
      );
    checks++;
  endtask
  initial begin
    fetched='0;
    fetched.pc=XLEN'(32'h80000000);
    fetched.pnpc=fetched.pc+XLEN'(4);
    csr_bcast.fs=0;
    csr_bcast.tw=0;
    csr_bcast.tsr=0;
    csr_bcast.mcounteren=0;
    csr_bcast.scounteren=0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2)
      for (int tvm = 0; tvm < 2; tvm++) begin
        csr_bcast.priv=2'(priv);
        csr_bcast.tvm=1'(tvm);
        for (int rs1 = 0; rs1 < 32; rs1++)
        for (int rs2 = 0; rs2 < 32; rs2++) begin
          bit permitted;
          permitted=priv==3 || (priv==1 && tvm==0);
          fetched.inst={7'h09,5'(rs2),5'(rs1),3'b000,5'b0,7'h73};
          #1;
          reference_decode = decoded;
          for (int rd = 0; rd < 32; rd++) begin
            legality({7'h0b, 5'(rs2), 5'(rs1), 3'b000, 5'(rd), 7'h73}, rd == 0 && permitted);
            if(rd==0 && permitted && (decoded.uop.execute !== reference_decode.uop.execute
              || !decoded.uop.execute.sys.fence || !decoded.uop.execute.sys.fence_i))
              $fatal(1, "SINVAL does not use full SFENCE execution controls");
          end
        end
        fetched.inst = 32'h00000013;
        #1;
        reference_decode = decoded;
        for (int rs1 = 0; rs1 < 32; rs1++)
        for (int rs2 = 0; rs2 < 32; rs2++)
        for (int rd = 0; rd < 32; rd++) begin
          bit legal;
          legal = priv != 0 && rs1 == 0 && rs2 < 2 && rd == 0;
          legality({7'h0c, 5'(rs2), 5'(rs1), 3'b000, 5'(rd), 7'h73}, legal);
          // Inactive FP operand fields retain raw instruction bits; they are
          // not execution side effects when fp.valid is clear.
          reference_decode.uop.execute.fp = decoded.uop.execute.fp;
          if(legal && (decoded.uop.execute.fp.valid
            || decoded.uop.execute !== reference_decode.uop.execute))
            $fatal(1, "SFENCE ordering-only instruction is not a NOP on this implementation");
        end
      end
    $display("PASS: RV%0d Svinval decode/permissions/semantics %0d checks", XLEN, checks);
    $finish;
  end
endmodule
