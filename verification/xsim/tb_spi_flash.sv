`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

module tb_spi_flash #(
    parameter bit BadIdentity = 1'b0,
    parameter bit MaxTimings = 1'b0,
    parameter realtime ReturnDelayNs = 0.0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [31:0] Base = 32'h00100800;
  logic clock = 0, reset = 1;
  always #5 clock = !clock;
  axi4_if #(.XLEN(XLEN)) bus ();
  rapt_pkg::sram_ctrl_t sram_ctrl;
  logic sclk, cs_n;
  logic [7:0] host_dq, host_oe, flash_dq, flash_oe, dq;
  logic stuck_busy = 0, deny_wren = 0, ignore_mutation = 0, corrupt_read = 0, suspended = 0;
  logic [5:0] protect = 0;
  logic complement = 0;
  wire [7:0] delayed_dq, delayed_oe;
  assign #(ReturnDelayNs) delayed_dq = flash_dq;
  assign #(ReturnDelayNs) delayed_oe = flash_oe;
  int checks = 0;
  always_comb begin
    for (int i = 0; i < 8; i++)
    dq[i] = host_oe[i] ? host_dq[i] : delayed_oe[i] ? delayed_dq[i] : 1'b1;
  end

  rapt_axi_flash #(
      .XLEN(XLEN),
      .HalfPeriod(2),
      .PowerupCycles(8),
      .ResetCycles(4000),
      .PollCycles(MaxTimings ? 50_000_000 : 20_000)
  ) dut (
      .clock,
      .reset,
      .sram_ctrl_o(sram_ctrl),
      .axi(bus),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(host_dq),
      .dq_oe_o(host_oe),
      .dq_i(dq),
      .ds_i(1'b0)
  );
  rapt_w25q64jw_model #(
      // Reject the 3.3 V JV profile, even though its basic SPI commands look alike.
      .JedecId(BadIdentity ? 24'hef4017 : 24'hef6017),
      .ProgramTime(MaxTimings ? 3_000_000.0 : 40_000.0),
      .EraseTime(MaxTimings ? 400_000_000.0 : 80_000.0)
  ) flash (
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .host_oe_i(host_oe),
      .stuck_busy_i(stuck_busy),
      .deny_wren_i(deny_wren),
      .ignore_mutation_i(ignore_mutation),
      .corrupt_read_i(corrupt_read),
      .suspended_i(suspended),
      .protect_i(protect),
      .complement_i(complement),
      .dq_o(flash_dq),
      .dq_oe_o(flash_oe)
  );

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic read_bus(input logic [XLEN-1:0] addr, input int size, input int len,
                          input int burst, input logic [1:0] response,
                          output logic [XLEN-1:0] result[$]);
    logic [XLEN-1:0] saved;
    result.delete();
    @(negedge clock);
    bus.araddr = addr;
    bus.arsize = 3'(size);
    bus.arlen = 8'(len);
    bus.arburst = 2'(burst);
    bus.arid = 4'ha;
    bus.arvalid = 1;
    #1;
    while (!bus.arready) @(negedge clock);
    tick();
    bus.arvalid = 0;
    for (int b = 0; b <= len; b++) begin
      @(negedge clock);
      while (!bus.rvalid) @(negedge clock);
      saved = bus.rdata;
      repeat (3 + b % 4) begin
        tick();
        if (!bus.rvalid || bus.rdata !== saved || bus.rresp != response
            || bus.rid != 4'ha || bus.rlast != (b == len))
          $fatal(
              1,
              "Read stability/response addr=%h beat=%0d resp=%b want=%b data=%h",
              addr,
              b,
              bus.rresp,
              response,
              bus.rdata
          );
      end
      result.push_back(saved);
      bus.rready = 1;
      tick();
      bus.rready = 0;
      checks++;
    end
  endtask

  task automatic write_bus(input logic [XLEN-1:0] addr, input int size, input int len,
                           input int burst, input logic [XLEN-1:0] words[$],
                           input logic [Bytes-1:0] strobes[$], input logic [1:0] response,
                           input bit bad_last);
    @(negedge clock);
    bus.awaddr = addr;
    bus.awsize = 3'(size);
    bus.awlen = 8'(len);
    bus.awburst = 2'(burst);
    bus.awid = 4'h5;
    bus.awvalid = 1;
    #1;
    while (!bus.awready) @(negedge clock);
    tick();
    bus.awvalid = 0;
    for (int b = 0; b <= len; b++) begin
      repeat (b % 3 + 1) tick();
      bus.wdata = words[b];
      bus.wstrb = strobes[b];
      bus.wlast = (b == len) ^ bad_last;
      bus.wvalid = 1;
      @(negedge clock);
      while (!bus.wready) @(negedge clock);
      tick();
      bus.wvalid = 0;
    end
    @(negedge clock);
    while (!bus.bvalid) @(negedge clock);
    repeat (7) begin
      tick();
      if (!bus.bvalid || bus.bresp != response || bus.bid != 4'h5)
        $fatal(1, "Write response addr=%h got=%b want=%b", addr, bus.bresp, response);
    end
    bus.bready = 1;
    tick();
    bus.bready = 0;
    checks++;
  endtask

  task automatic reg_write(input logic [31:0] addr, input logic [31:0] value,
                           input logic [1:0] response);
    logic [XLEN-1:0] words[$];
    logic [Bytes-1:0] strobes[$];
    int lane;
    lane = int'(addr % Bytes);
    words.push_back(XLEN'(value) << (8 * lane));
    strobes.push_back(Bytes'(4'hf) << lane);
    write_bus(XLEN'(addr), 2, 0, 1, words, strobes, response, 0);
  endtask

  task automatic reg_read(input logic [31:0] addr, output logic [31:0] value);
    logic [XLEN-1:0] words[$];
    read_bus(XLEN'(addr), 2, 0, 1, 0, words);
    value = 32'(words[0] >> (8 * int'(addr % Bytes)));
  endtask

  task automatic recover;
    reg_write(Base + 32'h20, 32'h52460003, 0);
  endtask

  task automatic program_word(input logic [31:0] offset, input logic [31:0] value,
                              input logic [1:0] response);
    reg_write(Base + 32'h18, offset, 0);
    reg_write(Base + 32'h1c, value, 0);
    reg_write(Base + 32'h20, 32'h52460001, response);
  endtask

  task automatic start_command_no_reply(input logic [31:0] command);
    @(negedge clock);
    bus.awaddr = XLEN'(Base+32);
    bus.awsize = 2;
    bus.awlen = 0;
    bus.awburst = 1;
    bus.awvalid = 1;
    #1;
    while (!bus.awready) @(negedge clock);
    tick();
    bus.awvalid = 0;
    bus.wdata = XLEN'(command);
    bus.wstrb = Bytes'(4'hf);
    bus.wlast = 1;
    bus.wvalid = 1;
    while (!bus.wready) @(negedge clock);
    tick();
    bus.wvalid = 0;
  endtask

  task automatic reset_host;
    @(negedge clock);
    reset = 1;
    bus.arvalid = 0;
    bus.awvalid = 0;
    bus.wvalid = 0;
    bus.rready = 0;
    bus.bready = 0;
    repeat (5) tick();
    if (!cs_n || sclk || host_oe != 0 || bus.rvalid || bus.bvalid)
      $fatal(1, "Reset did not release pins/old responses");
    reset = 0;
  endtask

  initial begin
    logic [XLEN-1:0] rd[$], wr[$];
    logic [Bytes-1:0] st[$];
    logic [31:0] value;
    int before_program, before_erase;
    bus.arvalid = 0;
    bus.awvalid = 0;
    bus.wvalid = 0;
    bus.rready = 0;
    bus.bready = 0;
    tick();
    for (int i = 0; i < 512; i++) flash.mem[i] = 8'(i ^ (i >> 3));
    reset_host();

    if (BadIdentity) begin
      read_bus(XLEN'(32'h20000000), 2, 2, 1, 2, rd);
      if (rd[0] != 0 || rd[1] != 0 || rd[2] != 0) $fatal(1, "Identity failure data");
      reg_read(Base + 16, value);
      if (value[15:8] != 2 || !value[2]) $fatal(1, "Identity failure status %h", value);
      reg_write(Base + 32, 32'h52460003, 2);
      if (flash.wren_frames != 0 || flash.program_frames != 0 || flash.erase_frames != 0)
        $fatal(1, "Unknown device mutated");
      $display("PASS: rejected Flash identity XLEN=%0d", XLEN);
      $finish;
    end
    if (MaxTimings) begin
      realtime started;
      reg_read(Base + 32'h14, value);
      // The local ID snapshot can be read while initialization is still busy.
      read_bus(XLEN'(32'h20000000), 2, 0, 1, 0, rd);
      flash.mem[8192] = 0;
      reg_write(Base + 24, 8192, 0);
      started = $realtime;
      reg_write(Base + 32, 32'h52460002, 0);
      if ($realtime - started < 400_000_000.0) $fatal(1, "Short JW erase busy interval");
      started = $realtime;
      program_word(8192, 32'h01234567, 0);
      if ($realtime - started < 3_000_000.0) $fatal(1, "Short JW program busy interval");
      read_bus(XLEN'(32'h30002000), 2, 0, 1, 0, rd);
      if (rd[0][31:0] != 32'h01234567) $fatal(1, "JW maximum-time readback");
      $display("PASS: JW documented maximum busy times XLEN=%0d pp=3ms se=400ms", XLEN);
      $finish;
    end
    // Mapping readback is available before physical initialization completes.
    for (int i = 0; i < 3; i++) begin
      reg_read(Base + 32'h30 + 4 * i, value);
      if (value != (i == 2 ? 32'h00800000 : 0)) $fatal(1, "Legacy map readback");
      reg_write(Base + 32'h30 + 4 * i, 32'hdeadbeef, 2);
    end
    // First read is accepted while initialization is still running.
    read_bus(XLEN'(32'h20000000), 2, 3, 1, 0, rd);
    if (rd[0][31:0] != 32'h03020100) $fatal(1, "Reset alias/data order %h", rd[0]);
    reg_read(Base + 32'h14, value);
    if (value != 32'hef6017 || flash.reset_frames != 1) $fatal(1, "Boot ID/reset %h", value);
    reg_write(Base + 32'h20, 32'h52460004, 0);
    reg_write(Base + 32'h20, 32'h52460005, 0);
    reg_read(Base + 32'h10, value);
    if (value[15:0] != 1 || value[16] != 0) $fatal(1, "Boot status %h", value);
    // Every supported size/lane, INCR and FIXED, with response stalls.
    for (int size = 0; size <= $clog2(Bytes); size++) begin
      for (int lane = 0; lane < Bytes; lane += 1 << size) begin
        read_bus(XLEN'(32'h30000000 + lane), size, 3, 1, 0, rd);
        for (int b = 0; b < 4; b++) begin
          int a;
          logic [XLEN-1:0] expected;
          a = lane + (b << size);
          expected = 0;
          for (int j = 0; j < (1 << size); j++) expected[8*((a%Bytes)+j)+:8] = flash.mem[a+j];
          if (rd[b] !== expected) $fatal(1, "Narrow XIP lane %0d size %0d", lane, size);
        end
      end
      read_bus(XLEN'(32'h30000010), size, 2, 0, 0, rd);
      if (rd[0] !== rd[1] || rd[1] !== rd[2]) $fatal(1, "FIXED read");
    end
    // SRAM burst writes/reads, partial strobes and byte lanes.
    for (int b = 0; b < 16; b++) begin
      wr.push_back(XLEN'(b + 32'h12340000));
      st.push_back('1);
    end
    write_bus(XLEN'(32'h0f000000), $clog2(Bytes), 15, 1, wr, st, 0, 0);
    read_bus(XLEN'(32'h0f000000), $clog2(Bytes), 15, 1, 0, rd);
    for (int b = 0; b < 16; b++) if (rd[b] != wr[b]) $fatal(1, "SRAM burst %0d", b);
    for (int lane = 0; lane < Bytes; lane++) begin
      wr.delete();
      st.delete();
      wr.push_back(XLEN'(32'ha5) << (8 * lane));
      st.push_back(Bytes'(1) << lane);
      write_bus(XLEN'(32'h0f000100 + lane), 0, 0, 1, wr, st, 0, 0);
      read_bus(XLEN'(32'h0f000100 + lane), 0, 0, 1, 0, rd);
      if (rd[0] != wr[0]) $fatal(1, "SRAM byte lane %0d", lane);
    end
    wr[0] = '1;
    st[0] = '0;
    write_bus(XLEN'(32'h0f000100), $clog2(Bytes), 0, 1, wr, st, 0, 0);
    read_bus(XLEN'(32'h0f000100), $clog2(Bytes), 0, 1, 0, rd);
    if (rd[0] != {Bytes{8'ha5}}) $fatal(1, "Zero strobe changed SRAM");
    st[0] = '1;
    write_bus(XLEN'(32'h0f000100), 0, 0, 1, wr, st, 2, 0);
    write_bus(XLEN'(32'h0f000100), $clog2(Bytes), 0, 1, wr, st, 2, 1);
    // Concurrent AW/AR must each complete once, including reversed priorities.
    fork
      write_bus(XLEN'(32'h0f000200), $clog2(Bytes), 0, 1, wr, st, 0, 0);
      read_bus(XLEN'(32'h30000000), 2, 0, 1, 0, rd);
    join
    wr.delete();
    st.delete();
    for (int b = 0; b < 3; b++) begin
      wr.push_back('1);
      st.push_back('1);
    end
    reg_write(Base + 4, 32'hffff1234, 0);
    if (sram_ctrl != 16'h1234) $fatal(1, "SRAM control");
    // Unsupported addressing, widths/bursts, register shapes, ordinary NOR writes.
    read_bus(XLEN'(32'h30800000), 2, 2, 1, 3, rd);
    read_bus(XLEN'(32'h20010000), 2, 0, 1, 3, rd);
    read_bus(XLEN'(32'h30000ffc), 2, 1, 1, 2, rd);
    // AXI permits an unaligned first read beat. The core uses this on RV64
    // ROM word loads; only lanes from ARADDR to the size boundary are valid.
    for (int size = 1; size <= $clog2(Bytes); size++) begin
      for (int offset = 1; offset < (1 << size); offset++) begin
        read_bus(XLEN'(32'h30000000 + offset), size, 3, 1, 0, rd);
        for (int b = 0; b < 4; b++) begin
          int a, n;
          logic [XLEN-1:0] expected;
          a = b == 0 ? offset : b << size;
          n = b == 0 ? (1 << size) - offset : (1 << size);
          expected = 0;
          for (int j = 0; j < n; j++) expected[8*((a%Bytes)+j)+:8] = flash.mem[a+j];
          if (rd[b] != expected)
            $fatal(1, "Unaligned read size/offset/beat=%0d/%0d/%0d", size, offset, b);
        end
      end
    end
    read_bus(XLEN'(Base + 17), 2, 0, 1, 2, rd);
    read_bus(XLEN'(32'h30000000), $clog2(Bytes) + 1, 0, 1, 2, rd);
    read_bus(XLEN'(32'h30000000), 2, 0, 2, 2, rd);
    read_bus(XLEN'(Base + 16), 1, 1, 1, 2, rd);
    read_bus(XLEN'(Base + 32), 2, 0, 1, 2, rd);
    if (XLEN == 64) read_bus(XLEN'(64'h10030000000), 2, 0, 1, 3, rd);
    write_bus(XLEN'(32'h30000000), 2, 2, 1, wr, st, 2, 0);
    reg_write(Base + 32, 1, 2);
    reg_write(Base + 24, 32'h800000, 0);
    reg_write(Base + 32, 32'h52460001, 2);
    reg_write(Base + 24, 3, 0);
    reg_write(Base + 32, 32'h52460001, 2);
    reg_write(Base + 32, 32'h52460002, 2);
    if (flash.program_frames != 0 || flash.erase_frames != 0) $fatal(1, "Implicit mutation");

    // Erase then program/readback; complete sector blank check and neighbour preservation.
    flash.mem[4096] = 8'h5a;
    reg_write(Base + 24, 0, 0);
    reg_write(Base + 32, 32'h52460002, 0);
    for (int i = 0; i < 4096; i++) if (flash.mem[i] != 8'hff) $fatal(1, "Erase byte %0d", i);
    if (flash.mem[4096] != 8'h5a) $fatal(1, "Erase neighbour");
    program_word(252, 32'h12345678, 0);
    program_word(256, 32'h89abcdef, 0);
    program_word(32'h7ffffc, 32'hfeed7654, 0);
    if (flash.last_program_bytes != 4) $fatal(1, "PROGRAM32 frame size");
    read_bus(XLEN'(32'h300000fc), 2, 0, 1, 0, rd);
    if (32'(rd[0] >> (8 * (252 % Bytes))) != 32'h12345678) $fatal(1, "Readback");
    read_bus(XLEN'(32'h307ffffc), 2, 0, 1, 0, rd);
    if (32'(rd[0] >> (8 * (252 % Bytes))) != 32'hfeed7654) $fatal(1, "Last word");
    // NOR 0->1 request must fail verification, with no retry and recovery latch.
    before_program = flash.program_frames;
    program_word(252, 32'hffffffff, 2);
    if (flash.program_frames != before_program + 1 || flash.mem[252] != 8'h78)
      $fatal(1, "NOR/replay semantics");
    reg_read(Base + 16, value);
    if (value[15:8] != 5 || !value[2]) $fatal(1, "Verify error not latched %h", value);
    read_bus(XLEN'(32'h30000100), 2, 1, 1, 2, rd);
    if (rd[0] != 0 || rd[1] != 0) $fatal(1, "Failed read leaked data");
    recover();
    // Ignored/protected command and WEL denial cannot look successful.
    ignore_mutation = 1;
    program_word(512, 32'h00000000, 2);
    ignore_mutation = 0;
    recover();
    deny_wren = 1;
    before_program = flash.program_frames;
    program_word(516, 32'h0, 2);
    if (flash.program_frames != before_program) $fatal(1, "Mutation without WEL");
    deny_wren = 0;
    recover();
    suspended = 1;
    read_bus(XLEN'(32'h30000000), 2, 0, 1, 2, rd);
    suspended = 0;
    recover();
    // JW SR1 block protection and SR2 CMP prevent mutation before WREN.
    before_program = flash.wren_frames;
    protect = 6'b000001;
    program_word(528, 32'h0, 2);
    if (flash.wren_frames != before_program) $fatal(1, "WREN despite JW protection");
    protect = 0;
    recover();
    complement = 1;
    program_word(528, 32'h0, 2);
    if (flash.wren_frames != before_program) $fatal(1, "WREN despite JW CMP");
    complement = 0;
    recover();
    // Busy timeout: no implicit recovery or successful subsequent XIP.
    stuck_busy = 1;
    before_program = flash.program_frames;
    program_word(520, 32'h0, 2);
    reg_read(Base + 16, value);
    if (value[15:8] != 1 || !value[2]) $fatal(1, "Missing busy deadline %h", value);
    stuck_busy = 0;
    read_bus(XLEN'(32'h30000000), 2, 0, 1, 2, rd);
    if (flash.program_frames != before_program) $fatal(1, "Timed-out command replay");
    recover();

    // Timeout after accepting a destructive command also latches failure.
    before_program = flash.program_frames;
    fork
      program_word(524, 32'h12345678, 2);
      begin
        wait (flash.program_frames == before_program + 1);
        stuck_busy = 1;
      end
    join
    reg_read(Base + 16, value);
    if (value[15:8] != 1 || !value[2]) $fatal(1, "Post-command timeout %h", value);
    stuck_busy = 0;
    read_bus(XLEN'(32'h3000020c), 2, 1, 1, 2, rd);
    recover();
    if (flash.program_frames != before_program + 1) $fatal(1, "Post-timeout mutation replay");

    // Reset while receiving serial data; no old AXI reply is resurrected.
    @(negedge clock);
    bus.araddr = XLEN'(32'h30000000);
    bus.arsize = 2;
    bus.arlen = 3;
    bus.arburst = 1;
    bus.arvalid = 1;
    tick();
    bus.arvalid = 0;
    wait (flash.command == 8'h03 && flash.frame_bits > 40);
    reset_host();
    read_bus(XLEN'(32'h30000000), 2, 0, 1, 0, rd);
    if (rd[0][31:0] != 32'hffffffff) $fatal(1, "Reset read");
    // A reset can commit complete bytes from a partial PROGRAM frame.
    // The controller must neither claim an old success nor replay the word.
    reg_write(Base + 24, 768, 0);
    reg_write(Base + 28, 32'h11223344, 0);
    before_program = flash.program_frames;
    start_command_no_reply(32'h52460001);
    wait (flash.command == 8'h02 && flash.program_bytes == 2 && flash.frame_bits % 8 == 0);
    reset_host();
    read_bus(XLEN'(32'h30000300), 2, 0, 1, 0, rd);
    if (flash.program_frames != before_program + 1 || rd[0][31:0] != 32'hffff3344)
      $fatal(1, "Partial program reset/replay %h", rd[0]);
    // Reset while a completed B response is held must discard that response.
    reg_write(Base + 24, 772, 0);
    reg_write(Base + 28, 32'h55667788, 0);
    before_program = flash.program_frames;
    start_command_no_reply(32'h52460001);
    wait (bus.bvalid);
    repeat (9) tick();
    reset_host();
    read_bus(XLEN'(32'h30000304), 2, 0, 1, 0, rd);
    if (flash.program_frames != before_program+1
        || 32'(rd[0] >> (8 * (772 % Bytes))) != 32'h55667788)
      $fatal(1, "Reset held write response/replay");
    // Accepted mutation survives in the device; reset must poll WIP and never replay.
    before_erase = flash.erase_frames;
    reg_write(Base + 24, 4096, 0);
    start_command_no_reply(32'h52460002);
    wait (flash.erase_frames == before_erase + 1);
    reset_host();
    repeat (6) tick();
    read_bus(XLEN'(32'h30001000), 2, 0, 1, 0, rd);
    if (flash.erase_frames != before_erase + 1 || rd[0][31:0] != 32'hffffffff)
      $fatal(1, "Reset mutation replay/data");
    $display("PASS: direct SPI Flash XLEN=%0d checks=%0d reads=%0d program=%0d erase=%0d", XLEN,
             checks, flash.read_frames, flash.program_frames, flash.erase_frames);
    $finish;
  end
  initial begin
    #(MaxTimings ? 1200ms : 80ms);
    $fatal(1, "Flash test timeout");
  end
endmodule
