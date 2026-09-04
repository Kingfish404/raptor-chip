`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_cmo_permissions;
  localparam int XLEN = 64;
  localparam logic [63:0] Vaddr = 64'h0000_0000_4000_0123;
  localparam logic [63:0] Paddr = 64'h0000_0000_8000_0123;

  logic clock = 1'b0;
  logic reset = 1'b1;
  cmu_bcast_if cmu_bcast();
  lsu_l1d_if lsu_l1d();
  l1d_bus_if l1d_bus();
  csr_bcast_if csr_bcast();
  pmp_update_if pmp_update();
  lsu_l1d_mmu_if exu_l1d();
  rou_cmu_if rou_cmu();

  rapt_l1d dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic install_store_tlb(input logic [6:0] pte);
    begin
      dut.u_dstlb.valid[0] = 1'b1;
      dut.u_dstlb.vtags[0] = Vaddr[63:12];
      dut.u_dstlb.ptags[0] = 64'(Paddr >> 12);
      dut.u_dstlb.asids[0] = '0;
      dut.u_dstlb.ptes[0] = pte;
    end
  endtask

  task automatic expect_cmo_success(input string name);
    begin
      exu_l1d.vaddr = Vaddr;
      exu_l1d.walu = `RAPT_CBO_MGMT_WALU;
      exu_l1d.cmo_mgmt = 1'b1;
      exu_l1d.mmu_en = 1'b1;
      exu_l1d.valid = 1'b1;
      #1;
      check(exu_l1d.ready && !exu_l1d.trap, {name, " did not authorize"});
      tick(1);
      exu_l1d.valid = 1'b0;
      exu_l1d.mmu_en = 1'b0;
      exu_l1d.cmo_mgmt = 1'b0;
      tick(1);
    end
  endtask

  task automatic expect_store_page_fault(input logic cmo, input string name);
    begin
      exu_l1d.vaddr = Vaddr;
      exu_l1d.walu = cmo ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
      exu_l1d.cmo_mgmt = cmo;
      exu_l1d.mmu_en = 1'b1;
      exu_l1d.valid = 1'b1;
      tick(1);
      #1;
      check(exu_l1d.ready && exu_l1d.trap, {name, " did not trap"});
      check(exu_l1d.cause == `RAPT_CAUSE_STORE_PAGE_FAULT,
            {name, " reported a non-store page-fault cause"});
      exu_l1d.valid = 1'b0;
      exu_l1d.mmu_en = 1'b0;
      exu_l1d.cmo_mgmt = 1'b0;
      tick(2);
    end
  endtask

  initial begin
    init_l1d_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);
    csr_bcast.dmmu_en = 1'b1;

    // {D,A,G,U,X,W,R}: read-only, A=1, D=0.  CMO management must
    // succeed via load permission while an ordinary store faults.
    install_store_tlb(7'b010_0001);
    expect_cmo_success("read-only A=1,D=0 CMO");
    expect_store_page_fault(1'b0, "ordinary store on read-only D=0 PTE");

    // A=0 is always a CMO page fault, even when R permission is present.
    install_store_tlb(7'b000_0001);
    expect_store_page_fault(1'b1, "CMO with A=0");

    // Execute-only becomes load-permitted under MXR and therefore also
    // authorizes a cache-block management operation.
    install_store_tlb(7'b010_0100);
    expect_store_page_fault(1'b1, "execute-only CMO with MXR=0");
    csr_bcast.mxr = 1'b1;
    expect_cmo_success("execute-only CMO with MXR=1");

    $display("PASS: Zicbom R-or-W, A-only PTE permission and store-fault semantics");
    $finish;
  end
endmodule
