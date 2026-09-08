`include "rapt.svh"
`include "rapt_if.svh"
module tb_zfhmin_decode_slot;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  integer checks = 0, legal_checks = 0, trap_checks = 0;
  logic [31:0] inst, base;
  bit supported;
  task automatic check_one(input bit legal_encoding);
    bit denied, load_op, store_op, to_gpr;
    fetched.inst = inst;
    #1;
    denied=!legal_encoding || csr_bcast.fs==0;
    load_op=inst[6:0]==7'h07;
    store_op=inst[6:0]==7'h27;
    to_gpr=inst[6:0]==7'h53 && inst[31:25]==7'h72;
    if (decoded.uop.trap != denied)
      $fatal(
          1,
          "trap RV%0d inst=%h fs=%0d priv=%0d expected=%0d",
          X,
          inst,
          csr_bcast.fs,
          csr_bcast.priv,
          denied
      );
    if (denied) begin
      trap_checks++;
      if (decoded.uop.cause != X'(2) || decoded.uop.tval != X'(inst) || decoded.uop.rd != 0)
        $fatal(1, "trap payload/destination RV%0d inst=%h", X, inst);
    end else begin
      legal_checks++;
      if (!decoded.uop.execute.fp.valid || decoded.uop.execute.fp.op !=
          `RAPT_FP_OP_ZFHMIN
          || decoded.uop.execute.fp.rm != inst[14:12] || decoded.uop.rd !=
              (to_gpr ? inst[11:7] : 5'b0) || decoded.uop.execute.fp.rd != inst[11:7] ||
              decoded.uop.execute.fp.rs1 != inst[19:15] || decoded.uop.execute.memory.load !=
              load_op || decoded.uop.execute.memory.store != store_op)
        $fatal(1, "route/destination RV%0d inst=%h", X, inst);
      if (load_op && decoded.uop.execute.int_op.alu != `RAPT_ALU_LH__)
        $fatal(1, "load width RV%0d inst=%h", X, inst);
      if (store_op && decoded.uop.execute.int_op.alu != `RAPT_SH_WSTRB)
        $fatal(1, "store width RV%0d inst=%h", X, inst);
      if ((load_op || store_op || inst[31:25] == 7'h7a) && decoded.rs1 != inst[19:15])
        $fatal(1, "integer source RV%0d inst=%h", X, inst);
    end
    checks++;
  endtask
  initial begin
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
        // All half-format OP-FP funct7, format/secondary fields and rm.
        for (int f7 = 2; f7 < 128; f7 += 4)
        for (int rs2 = 0; rs2 < 32; rs2++)
        for (int rm = 0; rm < 8; rm++)
        for (int pattern = 0; pattern < 4; pattern++) begin
          inst=(32'(f7)<<25)|(32'(rs2)<<20)|(32'(pattern==0?0:pattern==1?31:pattern==2?1:30)<<15)|(32'(rm)<<12)|(32'(pattern==0?0:pattern==1?31:pattern==2?30:1)<<7)|32'h53;
          supported=(f7==7'h22 && rs2<=1) || ((f7==7'h72 || f7==7'h7a) && rs2==0 && rm==0);
          check_one(supported);
        end
        // All source/destination registers and rm for the six non-memory forms.
        for (int form = 0; form < 6; form++)
        for (int rs = 0; rs < 32; rs++)
        for (int rd = 0; rd < 32; rd++)
        for (int rm = 0; rm < 8; rm++) begin
          case (form)
            0:base=32'he4000053;
            1:base=32'hf4000053;
            2:base=32'h40200053;
            3:base=32'h42200053;
            4:base=32'h44000053;
            default:base=32'h44100053;
          endcase
          inst = base | (32'(rs) << 15) | (32'(rd) << 7) | (32'(rm) << 12);
          check_one(form >= 2 || rm == 0);
        end
        // Q.H is unsupported in this frozen configuration.
        for (int rm = 0; rm < 8; rm++) begin
          inst = 32'h462f8fd3 | (32'(rm) << 12);
          check_one(0);
        end
        // Every signed offset, using f2/x2 and f31/x31 destination pairs.
        for (int imm = 0; imm < 4096; imm++)
        for (int pattern = 0; pattern < 2; pattern++) begin
          inst=(32'(imm)<<20)|(32'(pattern==0?1:30)<<15)|32'h1007|(32'(pattern==0?2:31)<<7);
          check_one(1);
          inst=(32'(imm>>5)<<25)|(32'(pattern==0?2:31)<<20)|(32'(pattern==0?1:30)<<15)|32'h1027|(32'(imm&31)<<7);
          check_one(1);
        end
      end
    end
    if (checks != 1179744) $fatal(1, "unexpected count %0d", checks);
    $display("PASS RV%0d Zfhmin decode slot checks=%0d legal=%0d traps=%0d", X, checks,
             legal_checks, trap_checks);
    $finish;
  end
endmodule
