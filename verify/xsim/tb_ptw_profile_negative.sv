`include "rapt.svh"

module tb_ptw_profile_negative;
  localparam int XLEN = 64;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic req_valid;
  logic kill;
  logic [XLEN-1:0] vaddr;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn;
  logic mmu_en;
  logic sbe;
  logic req_store;
  logic bus_arvalid;
  logic [XLEN-1:0] bus_araddr;
  logic bus_arready;
  logic bus_rvalid;
  logic [XLEN-1:0] bus_rdata;
  logic bus_awvalid;
  logic [XLEN-1:0] bus_awaddr;
  logic bus_wvalid;
  logic [XLEN-1:0] bus_wdata;
  logic [7:0] bus_wstrb;
  logic bus_wready;
  logic bus_werr;
  logic done;
  logic fault;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic busy;

  rapt_ptw #(.XLEN(XLEN)) dut (.*);

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic start_walk(input logic [XLEN-1:0] addr, input logic store);
    begin
      vaddr = addr;
      req_store = store;
      req_valid = 1'b1;
      tick(1);
      req_valid = 1'b0;
    end
  endtask

  task automatic accept_root_leaf(input logic [63:0] pte);
    begin
      check(bus_arvalid, "Sv39 PTW did not request the root PTE");
      bus_arready = 1'b1;
      tick(1);
      bus_arready = 1'b0;
      check(busy && !bus_arvalid, "Sv39 PTW did not wait for the root PTE");
      bus_rdata = pte;
      bus_rvalid = 1'b1;
      tick(1);
      bus_rvalid = 1'b0;
    end
  endtask

  task automatic clear_result;
    begin
      tick(1);
      check(!done && !fault, "PTW result pulse did not clear");
    end
  endtask

  initial begin
    req_valid = 1'b0;
    kill = 1'b0;
    vaddr = '0;
    satp_ppn = 'h100;
    mmu_en = 1'b1;
    sbe = 1'b0;
    req_store = 1'b0;
    bus_arready = 1'b0;
    bus_rvalid = 1'b0;
    bus_rdata = '0;
    bus_wready = 1'b0;
    bus_werr = 1'b0;
    tick(4);
    reset = 1'b0;
    tick(1);

    // bit39=1 while bit38=0: not a sign-extended Sv39 address.
    start_walk(64'h0000_0080_0000_1000, 1'b0);
    check(fault && !busy, "non-canonical Sv39 address did not fault immediately");
    check(!bus_arvalid, "non-canonical Sv39 address issued a PTE read");
    clear_result();

    // bit38=1 but the upper bits are zero: the opposite non-canonical form.
    start_walk(64'h0000_0040_0000_1000, 1'b0);
    check(fault && !busy, "non-sign-extended negative Sv39 address did not fault");
    check(!bus_arvalid, "negative non-canonical Sv39 address issued a PTE read");
    clear_result();

    // Valid level-2 leaf, D=1 but A=0.  A load must page-fault under Svade.
    start_walk(64'h0000_0000_4000_1000, 1'b0);
    accept_root_leaf(64'h0000_0000_0000_008f);
    check(fault && !done && !busy, "Sv39 A=0 load leaf did not fault");
    check(!bus_awvalid && !bus_wvalid, "Svade attempted to set A in memory");
    clear_result();

    // Valid level-2 leaf with A=1/D=0.  A store must page-fault under Svade.
    start_walk(64'h0000_0000_8000_1000, 1'b1);
    accept_root_leaf(64'h0000_0000_0000_004f);
    check(fault && !done && !busy, "Sv39 D=0 store leaf did not fault");
    check(!bus_awvalid && !bus_wvalid, "Svade attempted to set D in memory");
    clear_result();

    // D is irrelevant to a load when A is already set.
    start_walk(64'hffff_ffff_c000_1000, 1'b0);
    accept_root_leaf(64'h0000_0000_0000_004f);
    check(done && !fault && !busy, "Sv39 A=1 load was incorrectly rejected for D=0");
    clear_result();

    // A=1/D=1 is the legal store baseline.
    start_walk(64'h0000_0000_0000_1000, 1'b1);
    accept_root_leaf(64'h0000_0000_0000_00cf);
    check(done && !fault && !busy, "Sv39 A=1/D=1 store leaf did not complete");
    check(!bus_awvalid && !bus_wvalid, "Svade PTW exposed a write request");

    $display("PASS: RVA20S64 Sv39 canonical-address and Svade checks passed");
    $finish;
  end
endmodule
