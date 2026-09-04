`include "rapt.svh"

module tb_addr_classification;
  import rapt_pkg::*;
  logic clock = 1'b0;

  `include "tb_common.svh"

  initial begin
`ifdef RAPT_RV64
    check(addr_cacheable(64'h0000_0000_8014_572c),
          "zero-extended RV64 PMEM address was not cacheable");
    check(addr_cacheable(64'hffff_ffff_8014_572c),
          "sign-extended RV64 PMEM address was not cacheable");
    check(addr_mapped(64'h0000_0000_1000_0000),
          "zero-extended RV64 UART address was not mapped");
    check(addr_mmio(64'hffff_ffff_c000_0000),
          "sign-extended RV64 SoC MMIO address was not classified as MMIO");

    check(!addr_cacheable(64'h0000_0002_8014_572c),
          "malformed RV64 upper bits aliased into cacheable PMEM");
    check(!addr_mapped(64'h0000_0002_8014_572c),
          "malformed RV64 upper bits aliased into the physical map");
    check(!addr_mmio(64'h0000_0002_c000_0000),
          "malformed RV64 upper bits aliased into MMIO");
`else
    check(addr_cacheable(32'h8014_572c),
          "RV32 PMEM address was not cacheable");
    check(addr_mapped(32'h1000_0000),
          "RV32 UART address was not mapped");
    check(addr_mmio(32'hc000_0000),
          "RV32 SoC MMIO address was not classified as MMIO");
`endif

    $display("PASS: physical-address classification passed");
    $finish;
  end
endmodule
