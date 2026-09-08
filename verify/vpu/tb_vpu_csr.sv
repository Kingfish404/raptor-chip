module tb_vpu_csr #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64
);
  logic clock = 0, reset = 1, vector_enabled = 0;
  logic cfg_valid = 0, cfg_avl_max = 0, cfg_keep_vl = 0, cfg_illegal;
  logic [XLEN-1:0] cfg_vtype = 0, cfg_avl = 0, cfg_result;
  logic csr_valid = 0, csr_write = 0, csr_illegal;
  logic [11:0] csr_addr = 0;
  logic [XLEN-1:0] csr_wdata = 0, csr_rdata;
  logic exec_valid = 0, exec_fault = 0, exec_fof = 0, exec_saturated = 0;
  logic [$clog2(VLEN)-1:0] exec_vstart = 0, vstart;
  logic [XLEN-1:0] exec_vl = 0, vtype, vl;
  logic [1:0] vxrm;
  logic vxsat, dirty;
  int checks = 0;
  rapt_vpu_csr #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) dut (
      .*
  );

  task automatic tick;
    #1;
    clock = 1;
    #1;
    clock = 0;
  endtask

  task automatic read_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    csr_valid = 1;
    csr_write = 0;
    csr_addr = addr;
    #1;
    if (csr_illegal || csr_rdata !== value || dirty)
      $fatal(
          1,
          "read %h got=%h expected=%h illegal=%b dirty=%b",
          addr,
          csr_rdata,
          value,
          csr_illegal,
          dirty
      );
    tick();
    csr_valid = 0;
    checks++;
  endtask

  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value,
                           input logic illegal);
    csr_valid = 1;
    csr_write = 1;
    csr_addr = addr;
    csr_wdata = value;
    #1;
    if (csr_illegal !== illegal || dirty !== !illegal) $fatal(1, "write %h gating", addr);
    tick();
    csr_valid = 0;
    csr_write = 0;
    checks++;
  endtask

  initial begin
    tick();
    reset = 0;
    if (vl != 0 || !vtype[XLEN-1] || vstart != 0 || vxrm != 0 || vxsat) $fatal(1, "reset state");
    // VS=Off prevents both reads and writes, including configuration.
    write_csr(12'h008, '1, 1);
    cfg_valid = 1;
    cfg_avl = '1;
    #1;
    if (!cfg_illegal || dirty) $fatal(1, "disabled configuration");
    tick();
    cfg_valid = 0;
    if (vl != 0 || vstart != 0 || !vtype[XLEN-1]) $fatal(1, "disabled state mutation");
    vector_enabled = 1;
    read_csr(12'hc22, XLEN'(VLEN / 8));
    read_csr(12'hc21, XLEN'(1) << (XLEN - 1));

    cfg_valid = 1;
    cfg_vtype = 0; // e8,m1
    #1;
    if (cfg_result != XLEN'(VLEN / 8) || cfg_illegal || !dirty) $fatal(1, "configuration result");
    tick();
    cfg_valid = 0;
    read_csr(12'hc20, XLEN'(VLEN / 8));
    read_csr(12'hc21, 0);
    write_csr(12'hc20, 0, 1);
    write_csr(12'hc21, 0, 1);
    write_csr(12'hc22, 0, 1);
    read_csr(12'hc20, XLEN'(VLEN / 8));

    // WARL high bits and vcsr aliases, including explicit clearing of sticky
    // saturation. All possible low control combinations are exercised.
    for (int value = 0; value < 32; value++) begin
      write_csr(12'h00f, XLEN'(value), 0);
      read_csr(12'h009, XLEN'(value & 1));
      read_csr(12'h00a, (XLEN'(value) >> 1) & XLEN'(3));
      read_csr(12'h00f, XLEN'(value & 7));
      write_csr(12'h009, XLEN'(value), 0);
      write_csr(12'h00a, XLEN'(value), 0);
      read_csr(12'h00f, ((XLEN'(value) & XLEN'(3)) << 1) | (XLEN'(value) & XLEN'(1)));
    end
    write_csr(12'h008, '1, 0);
    read_csr(12'h008, XLEN'(VLEN - 1));
    cfg_valid = 1;
    cfg_keep_vl = 1;
    cfg_vtype = XLEN'('hc0); // change only tail/mask policy
    tick();
    cfg_valid = 0;
    cfg_keep_vl = 0;
    read_csr(12'h008, 0);
    read_csr(12'hc20, XLEN'(VLEN / 8));

    // Precise fault preserves VL/type and reports restart element.
    exec_valid = 1;
    exec_fault = 1;
    exec_vstart = $clog2(VLEN)'(3);
    tick();
    exec_valid = 0;
    exec_fault = 0;
    read_csr(12'h008, 3);
    read_csr(12'hc20, XLEN'(VLEN / 8));
    read_csr(12'hc21, XLEN'('hc0));
    // A normal completion clears restart; FOF shrinks VL without a fault.
    exec_valid = 1;
    exec_fof = 1;
    exec_vl = 2;
    tick();
    exec_valid = 0;
    exec_fof = 0;
    read_csr(12'h008, 0);
    read_csr(12'hc20, 2);
    write_csr(12'h009, 0, 0);
    exec_valid = 1;
    exec_saturated = 1;
    tick();
    exec_saturated = 0;
    tick();
    exec_valid = 0;
    read_csr(12'h009, 1);

    // Every unsupported address must reject reads and writes. Reads of
    // supported CSRs also reject when VS=Off.
    for (int addr = 0; addr < 4096; addr++) begin
      csr_addr = 12'(addr);
      if (addr == 'h008 || addr == 'h009 || addr == 'h00a || addr == 'h00f
          || addr == 'hc20 || addr == 'hc21 || addr == 'hc22) begin
        vector_enabled = 0;
      end
      csr_valid = 1;
      #1;
      if (!csr_illegal) $fatal(1, "unexpected readable CSR %h", csr_addr);
      tick();
      csr_valid = 0;
      write_csr(12'(addr), '1, 1);
      vector_enabled = 1;
    end
    read_csr(12'hc20, 2);
    read_csr(12'h009, 1);
    $display("PASS csr XLEN=%0d VLEN=%0d ELEN=%0d checks=%0d", XLEN, VLEN, ELEN, checks);
    $finish;
  end
endmodule
