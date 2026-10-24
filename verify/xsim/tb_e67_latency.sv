`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Warm alternating indirect targets defeat last-target prediction. The real
// frontend/backend/cache composition supplies every recovery and refill edge.
module tb_e67_latency;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if axi ();
  rapt_core dut (
      .clock,
      .reset,
      .io_master(axi),
      .writeback_error_o(),
      .clint_timer_int_i(1'b0),
      .clint_sw_int_i(1'b0),
      .mtime_i(64'b0),
      .io_interrupt(1'b0),
      .s_ext_irq_i(1'b0),
      .hart_id_i('0),
      .dm_haltreq_i(1'b0),
      .halted_o(),
      .halt_pc_o(),
      .commit_fire_o(),
      .dbg_gpr_rdata_o(),
      .dbg_gpr_we_i(1'b0),
      .dbg_gpr_addr_i('0),
      .dbg_gpr_wdata_i('0)
  );
  rapt_tb_mem #(
      .XLEN(XLEN)
  ) memory_model (
      .clock,
      .reset,
      .awid(axi.awid),
      .awaddr(axi.awaddr),
      .awlen(axi.awlen),
      .awsize(axi.awsize),
      .awburst(axi.awburst),
      .awvalid(axi.awvalid),
      .awready(axi.awready),
      .wdata(axi.wdata),
      .wstrb(axi.wstrb),
      .wlast(axi.wlast),
      .wvalid(axi.wvalid),
      .wready(axi.wready),
      .bid(axi.bid),
      .bresp(axi.bresp),
      .bvalid(axi.bvalid),
      .bready(axi.bready),
      .arid(axi.arid),
      .araddr(axi.araddr),
      .arlen(axi.arlen),
      .arsize(axi.arsize),
      .arburst(axi.arburst),
      .arvalid(axi.arvalid),
      .arready(axi.arready),
      .rid(axi.rid),
      .rdata(axi.rdata),
      .rresp(axi.rresp),
      .rlast(axi.rlast),
      .rvalid(axi.rvalid),
      .rready(axi.rready),
      .sim_finish(),
      .sim_exit_code()
  );
  // e67_branch.S, assembled with relaxation and compressed instructions disabled.
  logic [31:0] program_words[23] = '{
      32'h10000393,
      32'h00000297,
      32'h02c28293,
      32'h00000317,
      32'h03430313,
      32'hfff38393,
      32'h02038a63,
      32'h00028067,
      32'hff5ff06f,
      32'h00000013,
      32'h00000013,
      32'h00000013,
      32'h00030293,
      32'hfe1ff06f,
      32'h00000013,
      32'h00000013,
      32'h00000297,
      32'hff028293,
      32'hfcdff06f,
      32'h00000513,
      32'h00100073,
      32'h00000013,
      32'h00000013
  };
  task automatic put_word(input longint unsigned address, input logic [31:0] word_value);
    for (int b = 0; b < 4; b++) memory_model.store[address+64'(b)] = word_value[8*b+:8];
  endtask
  initial begin
    put_word(64'h20000000, 32'h60000297);  // auipc t0,0x60000
    put_word(64'h20000004, 32'h00028067);  // jalr x0,t0,0
    for (int i = 0; i < 23; i++) put_word(64'h80000000 + 64'(4 * i), program_words[i]);
    repeat (8) @(negedge clock);
    reset = 0;
  end

  int cycle, flush_cycle, redirect_cycle, events, samples;
  int alloc_delay, dispatch_delay;
  longint alloc_sum, dispatch_sum, retire_sum, redirect_sum;
  logic measuring, allocated, dispatched;
  logic [XLEN-1:0] target;
  always @(posedge clock) begin
    if (reset) begin
      cycle = 0;
      events = 0;
      samples = 0;
      measuring = 0;
      allocated = 0;
      dispatched = 0;
      alloc_sum = 0;
      dispatch_sum = 0;
      retire_sum = 0;
      redirect_sum = 0;
      redirect_cycle = 0;
    end else begin
      cycle++;
      assert (!dut.backend.empty_o || dut.backend.rou.skid_count == 0)
      else $fatal(1, "backend reported empty with a held rename group");
      if (dut.recovery.redirect_valid
          && {dut.backend.rou.uop_pl[dut.recovery.owner].pc, 1'b0} == Base + XLEN'(28))
        redirect_cycle = cycle;
      if (dut.cmu_bcast.flush_pipe
          && {dut.backend.rou.uop_pl[dut.backend.rou.rob_head].pc, 1'b0} == Base + XLEN'(28)) begin
        assert (!measuring)
        else $fatal(1, "overlapping recovery measurements");
        target = dut.backend.rou.recovery_target;
        assert (target == Base + XLEN'(48) || target == Base + XLEN'(64))
        else $fatal(1, "indirect loop recovered to unexpected target");
        events++;
        flush_cycle = cycle;
        measuring = 1;
        allocated = 0;
        dispatched = 0;
      end else if (measuring) begin
        for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
          if (!allocated && dut.backend.rou.deq_fire[s]
              && dut.backend.rou.allocation[s].uop.pc == target) begin
            alloc_delay = cycle - flush_cycle;
            allocated = 1;
          end
          if (!dispatched && dut.backend.dispatch_valid[s]
              && dut.backend.dispatch[s].uop.pc == target) begin
            dispatch_delay = cycle - flush_cycle;
            dispatched = 1;
          end
        end
        for (int c = 0; c < rapt_pkg::CommitWidth; c++) begin
          if (dut.backend.rou.commit_fire[c] && dut.backend.rou.rou_cmu.slot[c].pc == target) begin
            assert (allocated && dispatched)
            else $fatal(1, "target retired without allocation/dispatch");
            if (events > 8) begin
              samples++;
              alloc_sum += 64'(alloc_delay);
              dispatch_sum += 64'(dispatch_delay);
              retire_sum += 64'(cycle - flush_cycle);
              redirect_sum += 64'(cycle - redirect_cycle);
              $display(
                  "E67_RECOVERY event=%0d flush_to_alloc=%0d flush_to_dispatch=%0d flush_to_retire=%0d redirect_to_retire=%0d",
                  events, alloc_delay, dispatch_delay, cycle - flush_cycle, cycle - redirect_cycle);
            end
            measuring = 0;
          end
        end
      end
      if (samples == 64) begin
        $display(
            "E67_RECOVERY_SUM samples=%0d allocation=%0d dispatch=%0d retirement=%0d redirect_retirement=%0d XLEN=%0d",
            samples, alloc_sum, dispatch_sum, retire_sum, redirect_sum, XLEN);
        $display("PASS: directed alternating-target branch misprediction latency RV%0d", XLEN);
        $finish;
      end
      if (cycle > 20000) $fatal(1, "branch loop timeout events=%0d samples=%0d", events, samples);
    end
  end
endmodule
