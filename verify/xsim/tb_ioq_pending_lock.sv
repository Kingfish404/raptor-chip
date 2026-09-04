`include "rapt.svh"
`include "rapt_if.svh"

module tb_ioq_pending_lock;
  localparam int XLEN = 32;

  `include "tb_ioq_harness.svh"

  task automatic drive_sc(input logic [31:0] addr, input logic [31:0] data,
                          input logic reservation_is_valid,
                          input logic [31:0] expected_result);
    begin
      exu_l1d.reservation = addr;
      exu_l1d.reservation_valid = reservation_is_valid;
      rou_exu.uop = '0;
      rou_exu.uop.pc = 32'h2000_0200;
      rou_exu.uop.pnpc = rou_exu.uop.pc + 32'd4;
      rou_exu.uop.atom = 1'b1;
      rou_exu.uop.wen = 1'b1;
      rou_exu.uop.word = 1'b1;
      rou_exu.uop.alu = `RAPT_ATO_SC__;
      rou_exu.uop.rd = 5'd3;
      rou_exu.op1 = addr;
      rou_exu.op2 = data;
      rou_exu.prd = 6'd3;
      rou_exu.dest = 5'd3;
      rou_exu.valid = 1'b1;
      disp.accept_a = 1'b1;
      tick(1);
      disp.accept_a = 1'b0;
      rou_exu.valid = 1'b0;

      check(exu_ioq_bcast.valid, "SC did not complete at IOQ head");
      check(exu_ioq_bcast.result == expected_result, "SC result mismatch");
      check(exu_ioq_bcast.wen == reservation_is_valid, "SC store enable mismatch");
      check(exu_l1d.reservation_clear, "SC completion did not clear reservation");
      tick(1);
    end
  endtask

  task automatic drive_load(input logic [31:0] addr, input logic [4:0] dest,
                            input logic [5:0] prd);
    begin
      rou_exu.uop = '0;
      rou_exu.uop.pc = 32'h2000_0100 + {25'h0, dest, 2'b00};
      rou_exu.uop.pnpc = rou_exu.uop.pc + 32'd4;
      rou_exu.uop.ren = 1'b1;
      rou_exu.uop.wen = 1'b0;
      rou_exu.uop.alu = `RAPT_ALU_LW__;
      rou_exu.uop.rd = dest;
      rou_exu.uop.imm = '0;
      rou_exu.op1 = addr;
      rou_exu.op2 = '0;
      rou_exu.pr1 = '0;
      rou_exu.pr2 = '0;
      rou_exu.prd = prd;
      rou_exu.prs = '0;
      rou_exu.dest = dest;
      rou_exu.valid = 1'b1;
      disp.accept_a = 1'b1;
      tick(1);
      disp.accept_a = 1'b0;
      rou_exu.valid = 1'b0;
    end
  endtask

  task automatic drive_store(input logic [31:0] addr, input logic [4:0] dest);
    begin
      rou_exu.uop = '0;
      rou_exu.uop.pc = 32'h2000_0000 + {25'h0, dest, 2'b00};
      rou_exu.uop.pnpc = rou_exu.uop.pc + 32'd4;
      rou_exu.uop.wen = 1'b1;
      rou_exu.uop.alu = `RAPT_SW_WSTRB;
      rou_exu.op1 = addr;
      rou_exu.op2 = 32'h55aa_1234;
      rou_exu.pr1 = '0;
      rou_exu.pr2 = '0;
      rou_exu.prd = '0;
      rou_exu.dest = dest;
      rou_exu.valid = 1'b1;
      disp.accept_a = 1'b1;
      tick(1);
      disp.accept_a = 1'b0;
      rou_exu.valid = 1'b0;
    end
  endtask

  task automatic expect_pending_addr(input logic [31:0] addr);
    begin
      check(exu_lsu.rvalid, "exu_lsu.rvalid dropped while pending");
      check(exu_lsu.raddr == addr, "exu_lsu.raddr changed while pending");
      check(exu_lsu.ralu == `RAPT_ALU_LW__, "exu_lsu.ralu changed while pending");
    end
  endtask

  task automatic wait_for_addr(input logic [31:0] addr);
    bit found;
    begin
      found = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 32; wait_cycle++) begin
        if (exu_lsu.rvalid && exu_lsu.raddr == addr) begin
          found = 1'b1;
          wait_cycle = 32;
        end else begin
          tick(1);
        end
      end
      if (!found) fail("timed out waiting for expected exu_lsu address");
    end
  endtask

  task automatic expect_load_broadcast(input logic [31:0] data, input string msg);
    bit found;
    begin
      found = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 8; wait_cycle++) begin
        if (!found && exu_ioq_bcast.valid) begin
          check(exu_ioq_bcast.result == data, {msg, " broadcast data mismatch"});
          found = 1'b1;
        end
        if (!found) tick(1);
      end
      if (!found) fail({msg, " did not broadcast after LSU completion"});
    end
  endtask

  task automatic complete_lsu_load(input logic [31:0] data);
    begin
      exu_lsu.rdata = data;
      exu_lsu.rready = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        if (exu_lsu.rvalid) begin
          tick(1);
          exu_lsu.rready = 1'b0;
          return;
        end
        tick(1);
      end
      exu_lsu.rready = 1'b0;
      fail("timed out waiting for LSU load handshake");
    end
  endtask

  task automatic complete_fast_load(input logic [31:0] data,
                                    input logic [5:0] expected_prd);
    begin
      exu_lsu.rdata = data;
      exu_lsu.rready = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        if (exu_lsu.rvalid) begin
          #1;
          check(load_fast.valid, "head integer load did not emit fast wake");
          check(!load_fast.rebusy, "head integer load emitted rebusy on return");
          check(load_fast.prd == expected_prd, "fast-wake physical destination mismatch");
          tick(1);
          exu_lsu.rready = 1'b0;
          return;
        end
        tick(1);
      end
      exu_lsu.rready = 1'b0;
      fail("timed out waiting for fast LSU load handshake");
    end
  endtask

  task automatic expect_flush_drops_late_response;
    begin
      cmu_bcast.flush_pipe = 1'b1;
      tick(1);
      cmu_bcast.flush_pipe = 1'b0;
      tick(1);

      drive_load(32'hc000_3000, 5'd7, 6'd9);
      wait_for_addr(32'hc000_3000);
      tick(1);
      expect_pending_addr(32'hc000_3000);

      cmu_bcast.flush_pipe = 1'b1;
      tick(1);
      cmu_bcast.flush_pipe = 1'b0;
      #1;
      check(!exu_lsu.rvalid, "flushed IOQ load still drove an LSU request");
      check(!exu_ioq_bcast.valid, "flushed IOQ load broadcast during flush");

      exu_lsu.rdata = 32'hdead_beef;
      exu_lsu.rready = 1'b1;
      tick(1);
      exu_lsu.rready = 1'b0;
      repeat (3) begin
        check(!exu_ioq_bcast.valid,
              "late LSU response broadcast after its IOQ entry was flushed");
        tick(1);
      end

      drive_load(32'hc000_4000, 5'd8, 6'd10);
      wait_for_addr(32'hc000_4000);
      complete_fast_load(32'h1234_abcd, 6'd10);
      expect_load_broadcast(32'h1234_abcd, "post-flush reused load");
      check(exu_ioq_bcast.dest == 5'd8,
            "post-flush reused load broadcast a stale ROB destination");
      check(exu_ioq_bcast.prd == 6'd10,
            "post-flush reused load broadcast a stale physical destination");
    end
  endtask

  initial begin
    init_ioq_inputs(1'b0);
    tick(5);
    reset = 1'b0;
    tick(2);

    drive_sc(32'h0000_0000, 32'h1234_5678, 1'b0, 32'd1);
    drive_sc(32'h8000_0080, 32'h89ab_cdef, 1'b1, 32'd0);
    $display("PASS: IOQ LR/SC reservation checks passed");

    reset = 1'b1;
    init_ioq_inputs(1'b1);
    tick(2);
    reset = 1'b0;
    tick(2);
    csr_bcast.dmmu_en = 1'b1;

    // Keep an older translating store at the IOQ/ROB head, then issue a
    // non-aliasing younger MMU load.  Its physical address (and therefore MMIO
    // classification) is only known after DTLB translation.  If L1D discovers
    // MMIO it waits for ordered=1, so the held request must be promoted only
    // after both the IOQ and ROB heads advance to it.
    cmu_bcast.rob_head = 5'd11;
    exu_lsu.stq_ready = 1'b0;
    drive_store(32'hc000_0000, 5'd11);
    drive_load(32'hc000_0800, 5'd12, 6'd12);
    wait_for_addr(32'hc000_0800);
    check(!exu_lsu.ordered, "out-of-order MMU load started ordered");
    repeat (3) begin
      check(!exu_lsu.ordered, "MMU load promoted before reaching ROB head");
      tick(1);
    end

    // Finish the older store's DTLB request and let it retire.  The pending
    // load is now IOQ head, but must remain unordered until ROB catches up.
    exu_l1d.paddr = 32'h8000_0000;
    exu_l1d.ready = 1'b1;
    tick(1);
    exu_l1d.ready = 1'b0;
    exu_lsu.stq_ready = 1'b1;
    #1;
    check(exu_ioq_bcast.valid && exu_ioq_bcast.dest == 5'd11,
          "older translated store did not become retireable");
    tick(1);
    #1;
    check(dut.ioq_head == 1, "IOQ head did not advance to pending load");
    check(!exu_lsu.ordered, "MMU load promoted before reaching ROB head");

    cmu_bcast.rob_head = 5'd12;
    tick(1);
    check(exu_lsu.ordered, "held MMU load did not become ordered at ROB head");
    complete_lsu_load(32'hfeed_1200);
    expect_load_broadcast(32'hfeed_1200, "ROB-head promoted MMU load");

    reset = 1'b1;
    init_ioq_inputs(1'b1);
    tick(2);
    reset = 1'b0;
    tick(2);
    csr_bcast.dmmu_en = 1'b1;

    drive_load(32'hc000_1000, 5'd0, 6'd1);
    wait_for_addr(32'hc000_1000);
    tick(1);
    expect_pending_addr(32'hc000_1000);

    drive_load(32'hc000_2000, 5'd1, 6'd2);
  `ifdef RAPT_LSU_HUM
    #1;
    check(dut.ioq_valid[1], "second MMU load was not resident in IOQ entry 1");
    check(dut.ioq_load_issue_vec[1], "second MMU load was not issue-eligible");
    check(exu_lsu.rvalid_b, "HUM B request missing immediately after second MMU load enqueue");
  `endif
    for (int i = 0; i < 8; i++) begin
      expect_pending_addr(32'hc000_1000);
      tick(1);
    end

  `ifdef RAPT_LSU_HUM
    check(exu_lsu.rvalid_b, "HUM B request missing while A load is pending");
    check(exu_lsu.raddr_b == 32'hc000_2000, "HUM B request address mismatch");
    exu_lsu.rdata = 32'h1111_2222;
    exu_lsu.rdata_b = 32'haaaa_5555;
    exu_lsu.rready = 1'b1;
    exu_lsu.rready_b = 1'b1;
    tick(1);
    exu_lsu.rready = 1'b0;
    exu_lsu.rready_b = 1'b0;
  `else
    complete_lsu_load(32'h1111_2222);
  `endif
    expect_load_broadcast(32'h1111_2222, "first load");

    tick(1);
  `ifdef RAPT_LSU_HUM
    expect_load_broadcast(32'haaaa_5555, "simultaneous HUM load");
    tick(1);
    check(!exu_ioq_bcast.valid, "IOQ did not retire both completed loads");
  `else
    wait_for_addr(32'hc000_2000);
    expect_pending_addr(32'hc000_2000);
  `endif

    expect_flush_drops_late_response();

    $display("PASS: IOQ pending-load lock and flush-kill xsim checks passed");
    $finish;
  end
endmodule
