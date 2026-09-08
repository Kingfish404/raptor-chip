`include "rapt.svh"
`include "rapt_if.svh"
module tb_compressed_expansion;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  string vectors;
  int fd, status, kind, count = 0;
  logic [15:0] enc;
  logic [31:0] expected;
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000002);
    fetched.pnpc = fetched.pc + X'(2);
    csr_bcast.fs = 3;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "missing vectors");
    fd = $fopen(vectors, "r");
    if (fd == 0) $fatal(1, "cannot open vectors");
    while (!$feof(
        fd
    )) begin
      status = $fscanf(fd, "%h %h %h\n", enc, kind, expected);
      if (status != 3) $fatal(1, "invalid vector row status=%0d", status);
      for (int fs = 0; fs < 4; fs++)
      for (int priv = 0; priv < 4; priv++)
      if (priv != 2) begin
        fetched.inst = {16'hdead, enc};
        csr_bcast.fs = 2'(fs);
        csr_bcast.priv = 2'(priv);
        #1;
        if (!decoded.uop.c) $fatal(1, "missing compressed length enc=%h", enc);
        if (kind == 1 || (fs == 0 && (expected[6:0] == 7'h07 || expected[6:0] == 7'h27))) begin
          if (!decoded.uop.trap || decoded.uop.cause != X'(2)
              || decoded.uop.tval != X'(enc) || decoded.uop.rd != 0)
            $fatal(1, "illegal compressed RV%0d enc=%h", X, enc);
        end else begin
          if (decoded.uop.inst != expected && !(kind == 2 && decoded.uop.inst == 32'h00000013))
            $fatal(
                1,
                "expansion RV%0d enc=%h expected=%h actual=%h kind=%0d",
                X,
                enc,
                expected,
                decoded.uop.inst,
                kind
            );
          if (kind == 3) begin
            // Breakpoint delivery belongs to retirement, not decode-time
            // illegality. Check the metadata that carries it there.
            if (decoded.uop.trap || !decoded.uop.execute.sys.ebreak)
              $fatal(1, "compressed breakpoint metadata RV%0d", X);
          end else if (decoded.uop.trap) $fatal(1, "legal compressed trapped RV%0d enc=%h", X, enc);
        end
        count++;
      end
    end
    $fclose(fd);
    if (count != 563712) $fatal(1, "incomplete count=%0d", count);
    $display("PASS: RV%0d compressed expansion 46976 encodings x M/S/U x FS=%0d", X, count);
    $finish;
  end
endmodule
