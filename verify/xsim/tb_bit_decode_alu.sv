`include "rapt.svh"
`include "rapt_if.svh"
module tb_bit_decode_alu;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  logic [X-1:0] a, b, expected, operand2, result;
  assign operand2 = fetched.inst[6:0] == 7'h33 || fetched.inst[6:0] == 7'h3b ? b : decoded.op2;
  rapt_ieu_alu #(
      .XLEN(X)
  ) alu (
      .s1(a),
      .s2(operand2),
      .op(decoded.uop.execute.int_op.alu),
      .word(decoded.uop.execute.int_op.word),
      .out_r(result)
  );
  logic [X-1:0] simple_result;
  rapt_ieu_alu #(
      .XLEN(X),
      .EnableRareOps(1'b0)
  ) simple_alu (
      .s1(a),
      .s2(operand2),
      .op(decoded.uop.execute.int_op.alu),
      .word(decoded.uop.execute.int_op.word),
      .out_r(simple_result)
  );
  logic rare_op;
  // Classify the instruction encoding independently of the scheduling helper.
  assign rare_op = (fetched.inst[6:0] == 7'h33 && fetched.inst[31:25] == 7'h05
      && fetched.inst[14:12] inside {3'd1, 3'd2, 3'd3})
      || (fetched.inst[6:0] inside {7'h13, 7'h1b} && fetched.inst[14:12] == 3'd1
          && fetched.inst[31:20] inside {12'h600, 12'h601, 12'h602});
  string vectors;
  integer fd, status, count = 0;
  logic [31:0] inst;
  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "missing vectors");
    fd = $fopen(vectors, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    fetched='0;
    fetched.pc=X'(32'h80000000);
    fetched.pnpc=fetched.pc+X'(4);
    csr_bcast.fs=0;
    csr_bcast.tvm=1;
    csr_bcast.tw=1;
    csr_bcast.tsr=1;
    while (!$feof(
        fd
    )) begin
      status = $fscanf(fd, "%h %h %h %h\n", inst, a, b, expected);
      if (status != 4) $fatal(1, "malformed vector %0d", count);
      fetched.inst = inst;
      for (int priv = 0; priv < 4; priv++)
      if (priv != 2) begin
        csr_bcast.priv = 2'(priv);
        #1;
        assert (decoded.uop.schedule.issue_ports == (rare_op
            ? rapt_pkg::IntegerSystemPortMask : rapt_pkg::IntegerAluPortMask))
        else
          $fatal(
              1,
              "bit ALU port mask inst=%h mask=%b rare=%b",
              inst,
              decoded.uop.schedule.issue_ports,
              rare_op
          );
        assert (simple_result == (rare_op ? X'(0) : expected))
        else
          $fatal(
              1,
              "simple bit ALU inst=%h result=%h expected=%h rare=%b",
              inst,
              simple_result,
              expected,
              rare_op
          );
        if (decoded.uop.trap || result != expected)
          $fatal(
              1,
              "bit ALU RV%0d row=%0d inst=%h a=%h b=%h result=%h expected=%h trap=%b",
              X,
              count,
              inst,
              a,
              b,
              result,
              expected,
              decoded.uop.trap
          );
      end
      count++;
    end
    if (count != (X == 64 ? 3840 : 2784)) $fatal(1, "incomplete count %0d", count);
    $display("PASS: RV%0d real decode+ALU %0d vectors x M/S/U", X, count);
    $finish;
  end
endmodule
