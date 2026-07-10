`include "rapt.svh"
`include "rapt_if.svh"

module tb_ioq_pending_lock;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic pmu_ioq_full;

  cmu_bcast_if cmu_bcast();
  csr_bcast_if csr_bcast();
  rou_exu_if rou_exu();
  exu_disp_ioq_if disp();
  exu_wb_if exu_rou();
  exu_wb_if exu_rou_b();
  exu_wb_if exu_wb_mul();
  exu_lsu_if exu_lsu();
  exu_l1d_if exu_l1d();
  exu_wb_if exu_ioq_bcast();

  rapt_exu_ioq dut (
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .rou_exu(rou_exu),
      .disp(disp),
      .exu_rou(exu_rou),
      .exu_rou_b(exu_rou_b),
      .exu_wb_mul(exu_wb_mul),
      .exu_lsu(exu_lsu),
      .exu_l1d(exu_l1d),
      .exu_ioq_bcast(exu_ioq_bcast),
      .pmu_ioq_full(pmu_ioq_full)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, 32'h2000_0000, 1'b1);

      rou_exu.uop = '0;
      rou_exu.op1 = '0;
      rou_exu.op2 = '0;
      rou_exu.pr1 = '0;
      rou_exu.pr2 = '0;
      rou_exu.prd = '0;
      rou_exu.prs = '0;
      rou_exu.dest = '0;
      rou_exu.valid = 1'b0;
`ifdef RAPT_DUAL_ISSUE
      rou_exu.uop_b = '0;
      rou_exu.op1_b = '0;
      rou_exu.op2_b = '0;
      rou_exu.pr1_b = '0;
      rou_exu.pr2_b = '0;
      rou_exu.prd_b = '0;
      rou_exu.prs_b = '0;
      rou_exu.dest_b = '0;
      rou_exu.valid_b = 1'b0;
`endif

      disp.accept_a = 1'b0;
      disp.accept_b_paired = 1'b0;
      disp.accept_b_alone = 1'b0;

      exu_rou.pc = '0;
      exu_rou.npc = '0;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.dest = '0;
      exu_rou.result = '0;
      exu_rou.prd = '0;
      exu_rou.rd = '0;
      exu_rou.csr_wen = 1'b0;
      exu_rou.csr_wdata = '0;
      exu_rou.trap = 1'b0;
      exu_rou.tval = '0;
      exu_rou.cause = '0;
      exu_rou.difftest_skip = 1'b0;
      exu_rou.valid = 1'b0;

      exu_rou_b.pc = '0;
      exu_rou_b.npc = '0;
      exu_rou_b.btaken = 1'b0;
      exu_rou_b.mispredict = 1'b0;
      exu_rou_b.dest = '0;
      exu_rou_b.result = '0;
      exu_rou_b.prd = '0;
      exu_rou_b.rd = '0;
      exu_rou_b.difftest_skip = 1'b0;
      exu_rou_b.valid = 1'b0;

      exu_wb_mul.result = '0;
      exu_wb_mul.prd = '0;
      exu_wb_mul.valid = 1'b0;

      exu_lsu.rdata = '0;
      exu_lsu.trap = 1'b0;
      exu_lsu.cause = '0;
      exu_lsu.difftest_skip = 1'b0;
      exu_lsu.rready = 1'b0;
      exu_lsu.stq_ready = 1'b1;

      exu_l1d.paddr = '0;
      exu_l1d.trap = 1'b0;
      exu_l1d.cause = '0;
      exu_l1d.reservation = '0;
      exu_l1d.ready = 1'b0;
    end
  endtask

  task automatic drive_load(input logic [31:0] addr, input logic [4:0] dest,
                            input logic [5:0] prd);
    begin
      rou_exu.uop = '0;
      rou_exu.uop.pc = 32'h2000_0100 + {25'h0, dest, 2'b00};
      rou_exu.uop.pnpc = rou_exu.uop.pc + 32'd4;
      rou_exu.uop.ren = 1'b1;
      rou_exu.uop.wen = 1'b1;
      rou_exu.uop.alu = `RAPT_ALU_LW__;
      rou_exu.uop.rd = dest;
      rou_exu.uop.imm = '0;
      rou_exu.op1 = addr;
      rou_exu.op2 = '0;
      rou_exu.pr1 = '0;
      rou_exu.pr2 = '0;
      rou_exu.prd = prd;
      rou_exu.prs = '0;
      rou_exu.dest = dest[$bits(rou_exu.dest)-1:0];
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
    begin
      for (int wait_cycle = 0; wait_cycle < 8; wait_cycle++) begin
        if (exu_ioq_bcast.valid) begin
          check(exu_ioq_bcast.result == data, {msg, " broadcast data mismatch"});
          return;
        end
        tick(1);
      end
      fail({msg, " did not broadcast after LSU completion"});
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

  initial begin
    init_inputs();
    tick(5);
    reset = 1'b0;
    tick(2);

    drive_load(32'h8000_1000, 5'd0, 6'd1);
    wait_for_addr(32'h8000_1000);
    tick(1);
    expect_pending_addr(32'h8000_1000);

    drive_load(32'h8000_2000, 5'd1, 6'd2);
    for (int i = 0; i < 8; i++) begin
      expect_pending_addr(32'h8000_1000);
      tick(1);
    end

    complete_lsu_load(32'h1111_2222);
    expect_load_broadcast(32'h1111_2222, "first load");

    tick(1);
    wait_for_addr(32'h8000_2000);
    expect_pending_addr(32'h8000_2000);

    $display("PASS: IOQ pending-load lock xsim checks passed");
    $finish;
  end
endmodule
