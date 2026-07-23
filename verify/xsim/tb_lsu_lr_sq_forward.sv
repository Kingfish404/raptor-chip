`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_lr_sq_forward;
  localparam int XLEN = 32;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam logic [31:0] TestAddr = 32'h8000_0080;
  localparam logic [31:0] StoreData = 32'h89ab_cdef;

  `include "tb_lsu_harness.svh"

  task automatic allocate_store;
    begin
      exu_ioq_bcast.valid = 1'b1;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.alu = 6'b00_1111;
      exu_ioq_bcast.dest = 6'd7;
      exu_ioq_bcast.tval = TestAddr;
      exu_ioq_bcast.sq_waddr = TestAddr;
      exu_ioq_bcast.sq_wdata = StoreData;
      tick(1);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      tick(1);
    end
  endtask

  task automatic drive_allocate(
      input logic [31:0] addr,
      input logic [31:0] data,
      input logic [5:0] dest);
    begin
      exu_ioq_bcast.valid = 1'b1;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.alu = 6'b00_1111;
      exu_ioq_bcast.dest = dest;
      exu_ioq_bcast.tval = addr;
      exu_ioq_bcast.sq_waddr = addr;
      exu_ioq_bcast.sq_wdata = data;
    end
  endtask

  task automatic drive_commit(
      input logic [31:0] addr,
      input logic [31:0] data,
      input logic [5:0] dest);
    begin
      rou_lsu.store = 1'b1;
      rou_lsu.alu = 6'b00_1111;
      rou_lsu.dest = dest;
      rou_lsu.sq_waddr = addr;
      rou_lsu.sq_vaddr = addr;
      rou_lsu.sq_wdata = data;
      rou_lsu.valid = 1'b1;
    end
  endtask

  initial begin
    init_lsu_inputs(1'b1, 32'h1020_3040, '0);
    tick(5);
    reset = 1'b0;
    tick(2);

    allocate_store();

    exu_lsu.rvalid = 1'b1;
    exu_lsu.raddr = TestAddr;
    exu_lsu.ralu = `RAPT_ALU_LW__;
    exu_lsu.atomic_lock = 1'b0;
    #1;
    check(exu_lsu.rready, "ordinary load did not forward from full-width SQ store");
    check(exu_lsu.rdata == StoreData, "ordinary SQ forwarding returned wrong data");
    check(!lsu_l1d.rvalid, "forwarded ordinary load unexpectedly reached L1D");

  `ifdef RAPT_LSU_HUM
    exu_lsu.rvalid = 1'b0;
    csr_bcast.dmmu_en = 1'b1;
    exu_lsu.rvalid_b = 1'b1;
    exu_lsu.raddr_b = TestAddr;
    exu_lsu.ralu_b = `RAPT_ALU_LW__;
    #1;
    check(exu_lsu.rready_b, "MMU-enabled HUM load did not forward from SQ");
    check(exu_lsu.rdata_b == StoreData, "MMU-enabled HUM SQ forwarding returned wrong data");
    check(!lsu_l1d.rvalid_b, "MMU-enabled forwarded HUM load unexpectedly reached L1D");
    exu_lsu.rvalid_b = 1'b0;
  `endif

    exu_lsu.raddr = TestAddr + 32'h1000;
    #1;
    check(!exu_lsu.rready, "MMU alias load incorrectly forwarded from a different VA");
    check(!lsu_l1d.rvalid, "MMU alias load bypassed a pending SQ store");
    exu_lsu.raddr = TestAddr;
    csr_bcast.dmmu_en = 1'b0;

    exu_lsu.rvalid = 1'b1;
    exu_lsu.atomic_lock = 1'b1;
    #1;
    check(!exu_lsu.rready, "LR incorrectly completed through SQ forwarding");
    check(!lsu_l1d.rvalid, "LR reached L1D before the older store drained");
    tick(2);
    check(!exu_lsu.rready, "blocked LR became ready while SQ store remained pending");

    exu_lsu.rvalid = 1'b0;
    rou_lsu.store = 1'b1;
    rou_lsu.alu = 6'b00_1111;
    rou_lsu.dest = 6'd7;
    rou_lsu.sq_waddr = TestAddr;
    rou_lsu.sq_vaddr = TestAddr;
    rou_lsu.sq_wdata = StoreData;
    rou_lsu.valid = 1'b1;
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    lsu_l1d.wready = 1'b1;
    tick(3);

    exu_lsu.rvalid = 1'b1;
    exu_lsu.atomic_lock = 1'b1;
    #1;
    check(lsu_l1d.rvalid, "LR did not reach L1D after the older store drained");
    check(lsu_l1d.atomic_lock, "LR request lost atomic_lock at the L1D boundary");
    lsu_l1d.rready = 1'b1;
    #1;
    check(exu_lsu.rready, "LR did not complete from L1D");
    check(exu_lsu.rdata == 32'h1020_3040, "LR returned wrong L1D data");

    exu_lsu.rvalid = 1'b0;
    lsu_l1d.rready = 1'b0;
    lsu_l1d.wready = 1'b0;
    reset = 1'b1;
    tick(2);
    reset = 1'b0;
    tick(1);

    drive_allocate(32'h8000_0100, 32'hc4aa_4680, 6'd10);
    tick(1);
    drive_allocate(32'h8000_0104, 32'hc4bb_4680, 6'd11);
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;
    drive_commit(32'h8000_0100, 32'hc4aa_4680, 6'd10);
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;

    lsu_l1d.wready = 1'b1;
    #1;
    check(lsu_l1d.wvalid, "first committed store was not presented");
    check(lsu_l1d.waddr == 32'h8000_0100, "first store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4aa_4680, "first store lost bit 30");
    tick(1);

    drive_allocate(32'h8000_0108, 32'hc4cc_4680, 6'd12);
    drive_commit(32'h8000_0104, 32'hc4bb_4680, 6'd11);
    tick(1);
    exu_ioq_bcast.valid = 1'b0;
    exu_ioq_bcast.wen = 1'b0;
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    #1;
    check(lsu_l1d.wvalid, "second store disappeared after alloc+commit+drain");
    check(lsu_l1d.waddr == 32'h8000_0104, "second store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4bb_4680, "second store lost bit 30");
    tick(1);
    tick(1);

    drive_commit(32'h8000_0108, 32'hc4cc_4680, 6'd12);
    tick(1);
    rou_lsu.valid = 1'b0;
    rou_lsu.store = 1'b0;
    #1;
    check(lsu_l1d.wvalid, "third store disappeared after concurrent allocation");
    check(lsu_l1d.waddr == 32'h8000_0108, "third store address was corrupted");
    check(lsu_l1d.wdata == 32'hc4cc_4680, "third store lost bit 30");
    tick(2);
    check(dut.sq_all_empty, "SQ did not empty after lifecycle stress");

        reset = 1'b1;
        lsu_l1d.rready = 1'b0;
        tick(2);
        reset = 1'b0;
        tick(1);

        exu_lsu.rvalid = 1'b1;
        exu_lsu.raddr = 32'h8000_0201;
        exu_lsu.ralu = `RAPT_ALU_LW__;
        lsu_l1d.rready = 1'b1;
        lsu_l1d.rdata = 32'h4433_2211;
        #1;
        check(lsu_l1d.raddr == 32'h8000_0200, "misaligned low beat used wrong address");
        check(!exu_lsu.rready, "misaligned load completed before its high beat");
        tick(1);

        lsu_l1d.rdata = 32'h8877_6655;
        #1;
        check(lsu_l1d.raddr == 32'h8000_0204, "misaligned high beat used wrong address");
        check(!exu_lsu.rready, "misaligned load completed on its high-beat cycle");
        tick(1);

        #1;
        check(exu_lsu.rready, "merged misaligned load did not complete");
        check(exu_lsu.rdata == 32'h5544_3322, "misaligned load merged the wrong bytes");
        tick(1);

        exu_lsu.raddr = 32'h8000_0300;
        lsu_l1d.rdata = 32'hdead_beef;
        #1;
        check(exu_lsu.rready, "no-bubble aligned follower did not complete");
        check(exu_lsu.rdata == 32'hdead_beef,
          "aligned follower consumed stale misaligned merged data");

    $display("PASS: LSU forwarding and concurrent SQ lifecycle preserve store data");
    $finish;
  end
endmodule
