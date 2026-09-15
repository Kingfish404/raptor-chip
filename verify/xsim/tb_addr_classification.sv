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
    if (PmemBytes == 32'h40000000) begin
      for (int region = 0; region < 4; region++) begin
        automatic logic [XLENPkg-1:0] addr = XLENPkg'(32'h80000000 + 32'(region) * 32'h10000000);
        check(addr_mapped(addr) && addr_cacheable(addr) && addr_writable(addr),
              "1 GiB DDR quadrant lacks RAM PMA");
        check(!addr_device(addr) && !addr_mmio(addr), "DDR classified as device");
        check(addr_ptw_readable(addr, 3) && addr_executable(addr, 3) && addr_atomic_capable(addr, 3
              ) && addr_zero_capable(addr), "DDR quadrant lacks PTW/fetch/atomic/zero capability");
      end
      check(addr_cacheable(XLENPkg'('hbfffffff)), "last DDR byte rejected");
      check(addr_ptw_readable(XLENPkg'('hbffffff8), 7), "last DDR PTE rejected");
      check(addr_executable(XLENPkg'('hbffffffe), 1), "last DDR instruction rejected");
      check(!addr_executable(XLENPkg'('hbffffffe), 3), "fetch crossed DDR/MMIO boundary");
`ifdef RAPT_RV64
      check(addr_cacheable(64'hffff_ffff_bfff_ffff), "sign-extended upper DDR rejected");
      check(!addr_mapped(64'h0000_0001_bfff_ffff), "malformed upper DDR alias accepted");
`endif
    end else if (PmemBytes == 32'h10000000) begin
      check(!addr_mapped(XLENPkg'('h90000000)) && !addr_cacheable(XLENPkg'('hbfffffff)),
            "default platform unexpectedly gained the KU15P DDR window");
    end
    check(addr_device(XLENPkg'('hc0000000)) && !addr_cacheable(XLENPkg'('hc0000000)),
          "MMIO boundary must remain device memory");
    check(!addr_ptw_readable(XLENPkg'('hc0000000), 3) && !addr_atomic_capable(
          XLENPkg'('hc0000000), 3) && !addr_zero_capable(XLENPkg'('hc0000000)),
          "MMIO gained RAM capabilities");
    $display("PASS: physical-address classification passed");
    $finish;
  end
endmodule
