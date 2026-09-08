`include "rapt.svh"
`include "rapt_if.svh"
module tb_fd_decode_slot;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  logic [31:0] inst;
  integer checks = 0, failures = 0, legal_count = 0;
  task automatic check_one(input int expected_op, input bit to_gpr, input bit load_op = 0,
                           input bit store_op = 0);
    bit denied;
    fetched.inst = inst;
    #1;
    denied = expected_op == 0 || csr_bcast.fs == 0;
    checks++;
    if (!denied) legal_count++;
    if(decoded.uop.trap!=denied || (denied && (decoded.uop.cause!=X'(2)||decoded.uop.tval!=X'(inst)||decoded.uop.rd!=0))
    || (!denied && (!decoded.uop.execute.fp.valid || decoded.uop.execute.fp.op!=6'(expected_op)
      || decoded.uop.execute.fp.rm!=inst[14:12] || decoded.uop.rd!=(to_gpr?inst[11:7]:5'b0)
      || decoded.uop.execute.fp.rd!=inst[11:7] || decoded.uop.execute.memory.load!=load_op || decoded.uop.execute.memory.store!=store_op)))begin
      failures++;
      if (failures <= 16)
        $display(
            "FAIL RV%0d inst=%h fs=%0d expectedop=%0d denied=%0d trap=%0d actualop=%0d",
            X,
            inst,
            csr_bcast.fs,
            expected_op,
            denied,
            decoded.uop.trap,
            decoded.uop.execute.fp.op
        );
    end
  endtask
  initial begin
    int op;
    bit gpr;
    fetched='0;
    fetched.pc=X'(32'h80000000);
    fetched.pnpc=fetched.pc+4;
    csr_bcast.tvm=0;
    csr_bcast.tw=0;
    csr_bcast.tsr=0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int fs = 0; fs < 4; fs++) begin
        csr_bcast.fs = 2'(fs);
        for (int f7 = 0; f7 < 128; f7++)
        if ((f7 % 4) < 2)
          for (int rs2 = 0; rs2 < 32; rs2++)
          for (int rm = 0; rm < 8; rm++)
          for (int pat = 0; pat < 2; pat++) begin
            op=0;
            gpr=0;
            case (f7)
              'h00:op=15;
              'h01:op=17;
              'h04:op=16;
              'h05:op=18;
              'h08:op=19;
              'h09:op=20;
              'h0c:op=59;
              'h0d:op=60;
              'h10:if(rm<=2)op=3+rm;
              'h11:if(rm<=2)op=10+rm;
              'h14:if(rm<=1)op=21+rm;
              'h15:if(rm<=1)op=23+rm;
              'h20:if(rs2==1)op=49;else if(rs2==2)op=63;
              'h21:if(rs2==0)op=50;else if(rs2==2)op=63;
              'h2c:if(rs2==0)op=61;
              'h2d:if(rs2==0)op=62;
              'h50:begin if(rm<=2)op=25+rm;gpr=1;end
              'h51:begin if(rm<=2)op=29+rm;gpr=1;end
              'h60:begin if(rs2<2||(rs2<4&&X==64))op=33+rs2;gpr=1;end
              'h61:begin if(rs2<2||(rs2<4&&X==64))op=41+rs2;gpr=1;end
              'h68:if(rs2<2||(rs2<4&&X==64))op=37+rs2;
              'h69:if(rs2<2||(rs2<4&&X==64))op=45+rs2;
              'h70:begin if(rs2==0)begin if(rm==0)op=2;else if(rm==1)op=28;end gpr=1;end
              'h71:begin if(rs2==0)begin if(rm==0&&X==64)op=9;else if(rm==1)op=32;end gpr=1;end
              'h78:if(rs2==0&&rm==0)op=1;
              'h79:if(rs2==0&&rm==0&&X==64)op=8;
              default:op=0;
            endcase
            inst=(32'(f7)<<25)|(32'(rs2)<<20)|(32'(pat?31:0)<<15)|(32'(rm)<<12)|(32'(pat?31:0)<<7)|32'h53;
            check_one(op, gpr);
          end
        for (int fma = 0; fma < 4; fma++)
        for (int fmt = 0; fmt < 4; fmt++)
        for (int rs3 = 0; rs3 < 32; rs3++)
        for (int rm = 0; rm < 8; rm++)
        for (int pat = 0; pat < 2; pat++) begin
          inst=(32'(rs3)<<27)|(32'(fmt)<<25)|(32'(pat?31:0)<<20)|(32'(pat?0:31)<<15)|(32'(rm)<<12)|(32'(pat?31:0)<<7)|32'(7'h43+4*fma);
          check_one(fmt < 2 ? 51 + 2 * fma + fmt : 0, 0);
        end
        for (int width = 2; width <= 3; width++)
        for (int imm = 0; imm < 4096; imm++)
        for (int pat = 0; pat < 2; pat++) begin
          inst=(32'(imm)<<20)|(32'(pat?31:0)<<15)|(32'(width)<<12)|(32'(pat?31:0)<<7)|32'h07;
          check_one(width == 2 ? 6 : 13, 0, 1, 0);
          inst=(32'(imm>>5)<<25)|(32'(pat?31:0)<<20)|(32'(pat?0:31)<<15)|(32'(width)<<12)|(32'(imm&31)<<7)|32'h27;
          check_one(width == 2 ? 7 : 14, 0, 0, 1);
        end
      end
    end
    $display("FD decode RV%0d checks=%0d legal=%0d failures=%0d", X, checks, legal_count, failures);
    if (failures) $fatal(1, "FD decode failures");
    $finish;
  end
endmodule
