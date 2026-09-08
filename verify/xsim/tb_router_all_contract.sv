// ---- tb_router_clint_contract ----
// ---- tb_router_clint_subword ----
`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_router_clint_subword;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WB = XLEN / 8;
  localparam logic [XLEN-1:0] Cmp = XLEN'('h02004000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if core_axi (), offchip_axi ();
  clint_bus_if clint_bus ();
  plic_bus_if plic_bus ();
  rapt_router router (.*);
  rapt_clint #(
      .MTIME_DIV(1024)
  ) clint (
      .clock,
      .reset,
      .clint_bus
  );
  `include "tb_common.svh"
  logic [63:0] expected;
  int commits = 0, cases = 0;
  always @(posedge clock) if (!reset && clint_bus.wvalid) commits++;
  task automatic read_cmp(input int off, input int size);
    logic [XLEN-1:0] want, held, mask;
    int lane;
    lane=off%WB;
    mask=size==WB ? '1 : (XLEN'(1)<<(8*size))-XLEN'(1);
    want=XLEN'(expected>>(off*8)) & mask;
    core_axi.araddr=Cmp+XLEN'(off);
    core_axi.arvalid=1;
    core_axi.arid=9;
    core_axi.arsize=3'($clog2(size));
    #1;
    check(core_axi.arready, "internal AR not ready");
    tick(1);
    core_axi.arvalid=0;
    core_axi.araddr=0;
    check(core_axi.rvalid && core_axi.rid == 9 && core_axi.rlast && core_axi.rresp == 0,
          "read ownership lost");
    check(((core_axi.rdata >> (8 * lane)) & mask) == want, "CLINT addressed subword mismatch");
    held = core_axi.rdata;
    tick(2);
    check(core_axi.rvalid && core_axi.rdata == held, "read changed under backpressure");
    core_axi.rready = 1;
    tick(1);
    core_axi.rready = 0;
  endtask
  task automatic write_cmp(input int off, input int size, input int mask, input bit early);
    logic [XLEN-1:0] data;
    int lane, before_count;
    lane=off%WB;
    data=XLEN'(64'h195b_6d7f_2345_6789)^XLEN'(mask+off);
    before_count=commits;
    core_axi.awaddr=Cmp+XLEN'(off);
    core_axi.awvalid=1;
    core_axi.awid=5;
    core_axi.awsize=3'($clog2(size));
    core_axi.wdata=data<<(lane*8);
    core_axi.wstrb=WB'(mask)<<lane;
    core_axi.wvalid=early;
    #1;
    check(core_axi.awready && !core_axi.wready, "internal AW/W phase mismatch");
    tick(1);
    core_axi.awvalid=0;
    core_axi.awaddr=XLEN'('h02000000);
    if (!early) tick(2);
    core_axi.wvalid = 1;
    #1;
    check(core_axi.wready, "internal W not accepted");
    tick(1);
    core_axi.wvalid = 0;
    for (int b = 0; b < size; b++)
      if ((mask & (1 << b)) != 0) expected[8*(off+b)+:8] = data[8*b+:8];
    check(commits == before_count + 1, "write duplicated or missing");
    check(clint.mtimecmp == expected, "CLINT subword changed unselected bytes");
    check(core_axi.bvalid && core_axi.bid == 5 && core_axi.bresp == 0,
          "write response ownership lost");
    tick(3);
    check(commits == before_count + 1 && core_axi.bvalid, "B backpressure repeated write");
    core_axi.bready = 1;
    tick(1);
    core_axi.bready = 0;
    read_cmp(off, size);
    read_cmp(0, 4);
    read_cmp(4, 4);
    cases++;
  endtask
  initial begin
    core_axi.arvalid=0;
    core_axi.araddr=0;
    core_axi.arid=0;
    core_axi.arlen=0;
    core_axi.arsize=0;
    core_axi.arburst=1;
    core_axi.arcache=0;
    core_axi.rready=0;
    core_axi.awvalid=0;
    core_axi.awaddr=0;
    core_axi.awid=0;
    core_axi.awlen=0;
    core_axi.awsize=0;
    core_axi.awburst=1;
    core_axi.awcache=0;
    core_axi.wvalid=0;
    core_axi.wdata=0;
    core_axi.wstrb=0;
    core_axi.wlast=1;
    core_axi.bready=0;
    offchip_axi.arready=0;
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.rvalid=0;
    offchip_axi.rdata=0;
    offchip_axi.rid=0;
    offchip_axi.rresp=0;
    offchip_axi.rlast=1;
    offchip_axi.bvalid=0;
    offchip_axi.bid=0;
    offchip_axi.bresp=0;
    plic_bus.rdata=0;
    tick(3);
    reset=0;
    expected='1;
    tick(1);
    for (int early = 0; early < 2; early++)
    for (int size = 1; size <= WB; size *= 2)
    for (int off = 0; off < 8; off += size)
    for (int mask = 0; mask < (1 << size); mask++) write_cmp(off, size, mask, early != 0);
    $display(
        "PASS: actual router/CLINT natural widths byte offsets masks ownership XLEN=%0d cases=%0d",
        XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_router_clint_width ----
`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_router_clint_width;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WB = XLEN / 8;
  localparam logic [XLEN-1:0] Cmp = XLEN'('h02004000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if core_axi (), offchip_axi ();
  clint_bus_if clint_bus ();
  plic_bus_if plic_bus ();
  rapt_router router (.*);
  rapt_clint #(
      .MTIME_DIV(1024)
  ) clint (
      .clock,
      .reset,
      .clint_bus
  );
  `include "tb_common.svh"
  logic [63:0] expected;
  int commits = 0, cases = 0;
  always @(posedge clock) if (!reset && clint_bus.wvalid) commits++;
  task automatic read_cmp(input int half);
    logic [XLEN-1:0] want, held;
    int lane;
    lane=(half*4)%WB;
    want=XLEN'(expected>>(half*32)) << (8*lane);
    core_axi.araddr=Cmp+XLEN'(half*4);
    core_axi.arvalid=1;
    core_axi.arid=9;
    core_axi.arsize=half==0 ? 3'($clog2(WB)) : 3'd2;
    #1;
    check(core_axi.arready, "internal AR not ready");
    tick(1);
    core_axi.arvalid=0;
    core_axi.araddr=0;
    check(core_axi.rvalid && core_axi.rid == 9 && core_axi.rlast && core_axi.rresp == 0,
          "read ownership lost");
    check(core_axi.rdata == want, "CLINT read lane/upper-half mismatch");
    held = core_axi.rdata;
    tick(2);
    check(core_axi.rvalid && core_axi.rdata == held, "read changed under backpressure");
    core_axi.rready = 1;
    tick(1);
    core_axi.rready = 0;
  endtask
  task automatic write_cmp(input int half, input int mask, input bit early, input bit native_word);
    logic [XLEN-1:0] data;
    int lane, nbytes, before_count;
    lane=(half*4)%WB;
    nbytes=native_word ? WB : 4;
    data=XLEN'(64'h195b_6d7f_2345_6789)^XLEN'(mask);
    before_count=commits;
    core_axi.awaddr=Cmp+XLEN'(half*4);
    core_axi.awvalid=1;
    core_axi.awid=5;
    core_axi.awsize=native_word ? 3'($clog2(WB)) : 3'd2;
    core_axi.wdata=data<<(lane*8);
    core_axi.wstrb=WB'(mask)<<lane;
    core_axi.wvalid=early;
    #1;
    check(core_axi.awready && !core_axi.wready, "internal AW/W phase mismatch");
    tick(1);
    core_axi.awvalid=0;
    core_axi.awaddr=XLEN'('h02000000);
    if (!early) tick(2);
    core_axi.wvalid = 1;
    #1;
    check(core_axi.wready, "internal W not accepted");
    tick(1);
    core_axi.wvalid = 0;
    for (int b = 0; b < nbytes; b++)
      if ((mask & (1 << b)) != 0) expected[8*(half*4+b)+:8] = data[8*b+:8];
    check(commits == before_count + 1, "write duplicated or missing");
    check(clint.mtimecmp == expected, "CLINT write changed unselected bytes");
    check(core_axi.bvalid && core_axi.bid == 5 && core_axi.bresp == 0,
          "write response ownership lost");
    tick(3);
    check(commits == before_count + 1 && core_axi.bvalid, "B backpressure repeated write");
    core_axi.bready = 1;
    tick(1);
    core_axi.bready = 0;
    read_cmp(0);
    read_cmp(1);
    cases++;
  endtask
  initial begin
    core_axi.arvalid=0;
    core_axi.araddr=0;
    core_axi.arid=0;
    core_axi.arlen=0;
    core_axi.arsize=0;
    core_axi.arburst=1;
    core_axi.arcache=0;
    core_axi.rready=0;
    core_axi.awvalid=0;
    core_axi.awaddr=0;
    core_axi.awid=0;
    core_axi.awlen=0;
    core_axi.awsize=0;
    core_axi.awburst=1;
    core_axi.awcache=0;
    core_axi.wvalid=0;
    core_axi.wdata=0;
    core_axi.wstrb=0;
    core_axi.wlast=1;
    core_axi.bready=0;
    offchip_axi.arready=0;
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.rvalid=0;
    offchip_axi.rdata=0;
    offchip_axi.rid=0;
    offchip_axi.rresp=0;
    offchip_axi.rlast=1;
    offchip_axi.bvalid=0;
    offchip_axi.bid=0;
    offchip_axi.bresp=0;
    plic_bus.rdata=0;
    tick(3);
    reset=0;
    expected='1;
    tick(1);
    for (int early = 0; early < 2; early++) begin
      for (int mask = 0; mask < (1 << WB); mask++) write_cmp(0, mask, early != 0, 1);
      for (int half = 0; half < 2; half++)
      for (int mask = 0; mask < 16; mask++) write_cmp(half, mask, early != 0, 0);
    end
    $display("PASS: actual router/CLINT lanes masks ownership XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_router_clint_strobe ----
`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_router_clint_strobe;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if core_axi (), offchip_axi ();
  clint_bus_if clint_bus ();
  plic_bus_if plic_bus ();
  rapt_router dut (.*);
  rapt_clint clint (
      .clock,
      .reset,
      .clint_bus
  );
  `include "tb_common.svh"
  int writes = 0;
  always @(posedge clock) if (!reset && clint_bus.wvalid) writes <= writes + 1;

  task automatic write_word(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                            input logic [Bytes-1:0] mask, input int delay_cycles);
    automatic int before_count=writes;
    automatic int offset=int'(addr & XLEN'(Bytes-1));
    core_axi.awaddr=addr;
    core_axi.awvalid=1;
    core_axi.wdata=data;
    core_axi.wstrb=mask;
    core_axi.wvalid=delay_cycles==0;
    #1;
    check(core_axi.awready, "AW not accepted from idle");
    tick(1);
    core_axi.awvalid=0;
    // Poison the live AW address: the W beat belongs to the captured AW.
    core_axi.awaddr=XLEN'('h80000000);
    if (delay_cycles != 0) tick(delay_cycles);
    core_axi.wvalid = 1;
    #1;
    check(core_axi.wready && clint_bus.wvalid, "CLINT W handshake missing");
    check(
        clint_bus.awaddr==addr && clint_bus.wstrb==(mask>>offset)
          && clint_bus.wdata==(data>>(offset*8)),
        "captured AW lane steering mismatch");
    check(!offchip_axi.wvalid && !plic_bus.wvalid, "internal write escaped target");
    tick(1);
    core_axi.wvalid = 0;
    for (int hold = 0; hold < 3; hold++) begin
      #1;
      check(core_axi.bvalid && core_axi.bid == 4'd9 && core_axi.bresp == 0,
            "B response not retained under backpressure");
      check(!clint_bus.wvalid && writes == before_count + 1, "CLINT write repeated");
      tick(1);
    end
    core_axi.bready = 1;
    tick(1);
    core_axi.bready = 0;
  endtask

  initial begin
    logic [63:0] expected;
    logic [XLEN-1:0] payload;
    core_axi.arvalid=0;
    core_axi.araddr=0;
    core_axi.arid=0;
    core_axi.arcache=0;
    core_axi.arburst=1;
    core_axi.arsize=2;
    core_axi.arlen=0;
    core_axi.rready=0;
    core_axi.awvalid=0;
    core_axi.awaddr=0;
    core_axi.awid=9;
    core_axi.awcache=0;
    core_axi.awburst=1;
    core_axi.awsize=2;
    core_axi.awlen=0;
    core_axi.wvalid=0;
    core_axi.wdata=0;
    core_axi.wstrb=0;
    core_axi.wlast=1;
    core_axi.bready=0;
    offchip_axi.arready=0;
    offchip_axi.rvalid=0;
    offchip_axi.rdata=0;
    offchip_axi.rid=0;
    offchip_axi.rresp=0;
    offchip_axi.rlast=0;
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.bvalid=0;
    offchip_axi.bid=0;
    offchip_axi.bresp=0;
    plic_bus.rdata=0;
    plic_bus.meip=0;
    plic_bus.seip=0;
    plic_bus.ext_irq=0;
    tick(2);
    reset = 0;
    tick(1);
    expected = '1;
    for (int half = 0; half < 2; half++)
    for (int mask = 0; mask < (1 << Bytes); mask++) begin
      automatic int offset = (half * 4) % Bytes;
      payload = XLEN'(64'h0123456789abcdef) ^ XLEN'(mask);
      write_word(XLEN'('h02004000) + XLEN'(half) * XLEN'(4), payload, Bytes'(mask), mask % 3);
      for (int b = offset; b < Bytes; b++)
      if ((mask & (1 << b)) != 0) expected[half*32+(b-offset)*8+:8] = payload[b*8+:8];
      check(clint.mtimecmp == expected, "router/CLINT end-to-end byte update mismatch");
    end
    $display("PASS: router CLINT WSTRB ownership and B backpressure XLEN=%0d writes=%0d", XLEN,
             writes);
    $finish;
  end
endmodule


// ---- tb_router_plic_contract ----
`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_router_plic_contract;
  localparam int XLEN = `RAPT_XLEN, WB = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h0c000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  axi4_if core_axi (), offchip_axi ();
  clint_bus_if clint_bus ();
  plic_bus_if plic_bus ();
  rapt_router router (.*);
  rapt_plic plic (
      .clock,
      .reset,
      .plic_bus
  );
  `include "tb_common.svh"
  int scenario = 0, reads = 0, writes = 0;
  always @(posedge clock)
    if (!reset) begin
      if (plic_bus.ar_commit) reads++;
      if (plic_bus.wvalid) writes++;
    end
  task automatic write_reg(input int offset, input logic [31:0] value, input int mask);
    int lane, before_count;
    lane=offset%WB;
    before_count=writes;
    core_axi.awaddr=Base+XLEN'(offset);
    core_axi.awvalid=1;
    core_axi.awid=5;
    core_axi.awsize=2;
    core_axi.wdata=XLEN'(value)<<(lane*8);
    core_axi.wstrb=WB'(mask)<<lane;
    core_axi.wvalid=1;
    #1;
    check(core_axi.awready && !core_axi.wready, "PLIC AW/W phase mismatch");
    tick(1);
    core_axi.awvalid=0;
    core_axi.awaddr=0;
    #1;
    check(core_axi.wready, "PLIC W stalled");
    tick(1);
    core_axi.wvalid = 0;
    check(core_axi.bvalid && core_axi.bid == 5 && core_axi.bresp == 0, "PLIC B ownership");
    tick(3);
    check(writes == before_count + 1 && core_axi.bvalid, "PLIC repeated write under B stall");
    core_axi.bready = 1;
    tick(1);
    core_axi.bready = 0;
  endtask
  task automatic read_reg(input int offset, output logic [31:0] value);
    logic [XLEN-1:0] held;
    int lane, before_count;
    lane=offset%WB;
    before_count=reads;
    core_axi.araddr=Base+XLEN'(offset);
    core_axi.arvalid=1;
    core_axi.arid=9;
    core_axi.arsize=2;
    #1;
    check(core_axi.arready, "PLIC AR stalled");
    tick(1);
    core_axi.arvalid=0;
    core_axi.araddr=0;
    check(core_axi.rvalid && core_axi.rid == 9 && core_axi.rlast && core_axi.rresp == 0,
          "PLIC R ownership");
    held=core_axi.rdata;
    value=32'(held>>(lane*8));
    tick(3);
    check(core_axi.rvalid && core_axi.rdata == held && reads == before_count + 1,
          "PLIC read side effect repeated under R stall");
    core_axi.rready = 1;
    tick(1);
    core_axi.rready = 0;
  endtask
  logic [31:0] value, expected;
  initial begin
    if ($value$plusargs("CASE=%d", scenario)) begin
    end
    core_axi.arvalid=0;
    core_axi.araddr=0;
    core_axi.arid=0;
    core_axi.arlen=0;
    core_axi.arsize=0;
    core_axi.arburst=1;
    core_axi.arcache=0;
    core_axi.rready=0;
    core_axi.awvalid=0;
    core_axi.awaddr=0;
    core_axi.awid=0;
    core_axi.awlen=0;
    core_axi.awsize=0;
    core_axi.awburst=1;
    core_axi.awcache=0;
    core_axi.wvalid=0;
    core_axi.wdata=0;
    core_axi.wstrb=0;
    core_axi.wlast=1;
    core_axi.bready=0;
    offchip_axi.arready=0;
    offchip_axi.awready=0;
    offchip_axi.wready=0;
    offchip_axi.rvalid=0;
    offchip_axi.rdata=0;
    offchip_axi.rid=0;
    offchip_axi.rresp=0;
    offchip_axi.rlast=1;
    offchip_axi.bvalid=0;
    offchip_axi.bid=0;
    offchip_axi.bresp=0;
    clint_bus.rdata=0;
    clint_bus.timer_int=0;
    clint_bus.sw_int=0;
    clint_bus.mtime_value=0;
    plic_bus.ext_irq=0;
    tick(3);
    reset = 0;
    tick(1);
    case (scenario)
      0: begin
        write_reg(4, 5, 15);
        write_reg(4, 3, 0);
        read_reg(4, value);
        check(value == 5, "zero WSTRB changed PLIC priority");
      end
      1: begin
        write_reg(4, 2, 15);
        write_reg('h2000, 2, 15);
        write_reg('h200000, 7, 15);
        write_reg('h1000, 2, 15);
        tick(2);
        check(!plic_bus.meip[0], "threshold did not mask notification");
        read_reg('h200004, value);
        check(value == 1, "threshold incorrectly masked claim");
      end
      2, 3, 5: begin
        write_reg(4, 2, 15);
        write_reg('h2000, 2, 15);
        write_reg('h1000, 2, 15);
        read_reg('h200004, value);
        check(value == 1, "initial claim failed");
        if (scenario == 2) write_reg('h200004, 33, 15);
        else if (scenario == 3) write_reg('h201004, 1, 15);
        else write_reg('h200004, 1, 0);
        write_reg('h1000, 2, 15);
        read_reg('h1000, value);
        check(value == 0, "invalid or masked completion released gateway");
        write_reg('h200004, 1, 15);
        write_reg('h1000, 2, 15);
        read_reg('h200004, value);
        check(value == 1, "valid completion did not release gateway");
      end
      4: begin
        for (int mask = 0; mask < 16; mask++) begin
          write_reg('h2000, 32'haa55ccfe, 15);
          expected = 32'haa55ccfe;
          write_reg('h2000, 32'h55aa3300, mask);
          for (int b = 0; b < 4; b++)
          if ((mask & (1 << b)) != 0) expected[b*8+:8] = 8'(32'h55aa3300 >> (b * 8));
          read_reg('h2000, value);
          check(value == expected, "PLIC enable changed unselected bytes");
        end
      end
      6: begin
        // Completion authorization follows the selected context's enable bit,
        // not an implicit binding to the context that performed the claim.
        write_reg(4, 2, 15);
        write_reg('h2000, 2, 15);
        write_reg('h2080, 2, 15);
        write_reg('h1000, 2, 15);
        read_reg('h200004, value);
        check(value == 1, "initial cross-context claim failed");
        write_reg('h201004, 1, 15);
        write_reg('h1000, 2, 15);
        read_reg('h201004, value);
        check(value == 1, "enabled cross-context completion did not release gateway");
        read_reg('h200004, value);
        check(value == 0, "cross-context claim did not consume pending source");
      end
      default: $fatal(1,"unknown CASE");
    endcase
    $display("PASS: actual router/PLIC contract XLEN=%0d CASE=%0d", XLEN, scenario);
    $finish;
  end
endmodule
