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
    check(addr_mapped(64'h0000_0000_1000_0000), "zero-extended RV64 UART address was not mapped");
    check(addr_mmio(64'hffff_ffff_c000_0000),
          "sign-extended RV64 SoC MMIO address was not classified as MMIO");

    check(!addr_cacheable(64'h0000_0002_8014_572c),
          "malformed RV64 upper bits aliased into cacheable PMEM");
    check(!addr_mapped(64'h0000_0002_8014_572c),
          "malformed RV64 upper bits aliased into the physical map");
    check(!addr_mmio(64'h0000_0002_c000_0000), "malformed RV64 upper bits aliased into MMIO");
`else
    check(addr_cacheable(32'h8014_572c), "RV32 PMEM address was not cacheable");
    check(addr_mapped(32'h1000_0000), "RV32 UART address was not mapped");
    check(addr_mmio(32'hc000_0000), "RV32 SoC MMIO address was not classified as MMIO");
`endif

    check(!addr_mmio(XLENPkg'('h10011000)) && !addr_mmio(XLENPkg'('h10011fff)) && !addr_mmio(
          XLENPkg'('h10012000)), "retired timer window must not bypass difftest");

    check(addr_mapped(XLENPkg'('h0f000000)) && addr_mapped(XLENPkg'('h0f001fff)),
          "implemented 8 KiB SRAM must remain mapped");
    for (int offset = 0; offset < 3; offset++) begin
      automatic logic [XLENPkg-1:0] addr;
      addr=offset==0 ? XLENPkg'('h0f002000)
          : offset==1 ? XLENPkg'('h0f00ffff) : XLENPkg'('h0f010000);
      check(!addr_mapped(addr) && !addr_cacheable(addr) && !addr_writable(addr),
            "unimplemented SRAM tail retained data PMA capabilities");
      check(!addr_zero_capable(addr), "unimplemented SRAM tail permits block zero");
    end
    check(addr_ptw_readable(XLENPkg'('h0f001ff8), 7), "last SRAM PTE span was rejected");
    check(!addr_ptw_readable(XLENPkg'('h0f002000), 3), "SRAM hole permits PTE reads");
    check(addr_atomic_capable(XLENPkg'('h0f001ffc), 3), "last SRAM AMO word rejected");
    check(!addr_atomic_capable(XLENPkg'('h0f002000), 3), "SRAM hole permits atomics");
    check(addr_zero_capable(XLENPkg'('h0f001fff)), "last SRAM zero block rejected");
    check(addr_executable(XLENPkg'('h0f001ffe), 1), "last SRAM compressed instruction rejected");
    check(!addr_executable(XLENPkg'('h0f001ffe), 3), "cross-boundary SRAM fetch was accepted");
    $display("PASS: physical-address classification passed");
    $finish;
  end
endmodule
