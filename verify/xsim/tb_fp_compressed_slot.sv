`include "rapt.svh"
`include "rapt_if.svh"
module tb_fp_compressed_slot;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  integer checks = 0, failures = 0, traps = 0, fp_legal = 0, int_legal = 0;
  initial begin
    int q, f3, base, regno, offset, width, op;
    bit store_op, double_width, is_fp, denied;
    logic [31:0] expanded;
    fetched='0;
    fetched.pc=X'(32'h80000000);
    fetched.pnpc=fetched.pc+2;
    csr_bcast.tvm=0;
    csr_bcast.tw=0;
    csr_bcast.tsr=0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int fs = 0; fs < 4; fs++) begin
        csr_bcast.fs = 2'(fs);
        for (int c = 0; c < 65536; c++) begin
          q=c&3;
          f3=(c>>13)&7;
          if ((q == 0 || q == 2) && (f3 == 1 || f3 == 3 || f3 == 5 || f3 == 7)) begin
            store_op=f3>=4;
            is_fp=(f3==1||f3==5||X==32);
            double_width=(f3==1||f3==5||X==64);
            width=double_width?3:2;
            if (q == 0) begin
              base=8+((c>>7)&7);
              regno=8+((c>>2)&7);
              offset=double_width?(((c>>5)&3)<<6)|(((c>>10)&7)<<3):(((c>>5)&1)<<6)|(((c>>10)&7)<<3)|(((c>>6)&1)<<2);
            end else begin
              base=2;
              regno=store_op?((c>>2)&31):((c>>7)&31);
              if (store_op)
                offset=double_width?(((c>>7)&7)<<6)|(((c>>10)&7)<<3):(((c>>7)&3)<<6)|(((c>>9)&15)<<2);
              else
                offset=double_width?(((c>>2)&7)<<6)|(((c>>12)&1)<<5)|(((c>>5)&3)<<3):(((c>>2)&3)<<6)|(((c>>12)&1)<<5)|(((c>>4)&7)<<2);
            end
            op=is_fp?(store_op?(double_width?14:7):(double_width?13:6)):0;
            expanded=(32'(base)<<15)|(32'(width)<<12)|32'(store_op?(is_fp?7'h27:7'h23):(is_fp?7'h07:7'h03));
            if (store_op)
              expanded |= (32'(offset >> 5) << 25) | (32'(regno) << 20) | (32'(offset & 31) << 7);
            else expanded |= (32'(offset) << 20) | (32'(regno) << 7);
            denied=(is_fp&&fs==0)||(!is_fp&&!store_op&&q==2&&regno==0);
            fetched.inst=32'hdead0000|32'(c);
            #1;
            checks++;
            if (denied) traps++;
            else if (is_fp) fp_legal++;
            else int_legal++;
            if(decoded.uop.trap!=denied
       ||(denied&&(decoded.uop.cause!=X'(2)||decoded.uop.tval!=X'(c)||decoded.uop.rd!=0))
       ||(!denied&&(decoded.uop.inst!=expanded||!decoded.uop.c||decoded.uop.imm!=X'(offset)
         ||decoded.rs1!=5'(base)||decoded.uop.rd!=5'(!is_fp&&!store_op?regno:0)
         ||decoded.uop.execute.memory.load==store_op||decoded.uop.execute.memory.store!=store_op
         ||decoded.uop.execute.fp.valid!=is_fp
         ||(is_fp&&(decoded.uop.execute.fp.op!=6'(op)
            ||(store_op?decoded.uop.execute.fp.rs2:decoded.uop.execute.fp.rd)!=5'(regno))))))begin
              failures++;
              if (failures <= 12)
                $display(
                    "FAIL RV%0d c=%h fs=%0d expected=%h got=%h offset=%0d gotimm=%h trap=%0d/%0d",
                    X,
                    16'(c),
                    fs,
                    expanded,
                    decoded.uop.inst,
                    offset,
                    decoded.uop.imm,
                    decoded.uop.trap,
                    denied
                );
            end
          end
        end
      end
    end
    $display("Compressed FP RV%0d checks=%0d fp=%0d integer=%0d traps=%0d failures=%0d", X, checks,
             fp_legal, int_legal, traps, failures);
    if (checks != 196608 || failures) $fatal(1, "compressed matrix failed");
    $display("PASS: compressed FP decode");
    $finish;
  end
endmodule
