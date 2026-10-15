`include "rapt.svh"
`include "rapt_soc_if.svh"

// Real router + PLIC, with the MAC's queue-nonempty/latched-TX IRQ contract.
// This deliberately does not model the PHY, packet SRAM, or CPU instruction issue.
module tb_plic_network;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WB = XLEN / 8;
  localparam int Source = 4;
  localparam logic [XLEN-1:0] Base = XLEN'('h0c000000);
  localparam int EnableS = 'h2080;
  localparam int ClaimS = 'h201004;
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

  int scenario = 0, accepted_claims = 0, completed = 0;
  int rx_packets = 0;
  bit tx_pending = 0, mac_enabled = 1;
  assign plic_bus.ext_irq = 32'((mac_enabled && (rx_packets != 0 || tx_pending)) << Source);

  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1, "FAIL: XLEN=%0d CASE=%0d: %s", XLEN, scenario, message);
  endtask
  task automatic tick(input int count = 1);
    repeat (count) @(posedge clock);
    #1;
  endtask

  always @(posedge clock) begin
    if (!reset && plic_bus.ar_commit && plic_bus.araddr == Base + XLEN'(ClaimS)
        && plic_bus.rdata == XLEN'(Source))
      accepted_claims++;
    if (!reset && plic.complete_fire) completed++;
  end

  task automatic write_reg(input int offset, input logic [31:0] value, input int delay_cycles = 0);
    core_axi.awaddr = Base + XLEN'(offset);
    core_axi.awid = 5;
    core_axi.awvalid = 1;
    core_axi.wdata = XLEN'(value) << (8 * (offset % WB));
    core_axi.wstrb = WB'(15) << (offset % WB);
    core_axi.wvalid = 0;
    #1;
    check(core_axi.awready, "write address blocked");
    tick();
    core_axi.awvalid = 0;
    core_axi.awaddr = 0;
    tick(delay_cycles);
    core_axi.wvalid = 1;
    #1;
    check(core_axi.wready, "write data blocked");
    tick();
    core_axi.wvalid = 0;
    tick(delay_cycles);
    check(core_axi.bvalid && core_axi.bid == 5 && core_axi.bresp == 0,
          "write response lost under backpressure");
    core_axi.bready = 1;
    tick();
    core_axi.bready = 0;
  endtask

  task automatic issue_read(input logic [XLEN-1:0] address, input logic [3:0] id);
    core_axi.araddr = address;
    core_axi.arid = id;
    core_axi.arvalid = 1;
    #1;
    check(core_axi.arready, "read address blocked");
    tick();
    core_axi.arvalid = 0;
    core_axi.araddr = 0;
  endtask

  task automatic take_response(input logic [3:0] id, input logic [XLEN-1:0] value,
                               input int delay_cycles = 0);
    repeat (delay_cycles + 1) begin
      check(
          core_axi.rvalid && core_axi.rid == id && core_axi.rdata == value
            && core_axi.rlast && core_axi.rresp == 0,
          $sformatf(
          "response changed/lost: expected id=%0d data=%h, got id=%0d data=%h",
          id,
          value,
          core_axi.rid,
          core_axi.rdata
          ));
      tick();
    end
    core_axi.rready = 1;
    tick();
    core_axi.rready = 0;
  endtask

  task automatic read_reg(input int offset, output logic [31:0] value, input int delay_cycles = 0);
    logic [XLEN-1:0] held;
    issue_read(Base + XLEN'(offset), 9);
    held = core_axi.rdata;
    value = 32'(held >> (8 * (offset % WB)));
    take_response(9, held, delay_cycles);
  endtask

  logic [31:0] value;
  int claims_before;
  initial begin
    if ($value$plusargs("CASE=%d", scenario)) begin
    end
    if ($test$plusargs("TRACE")) begin
      $dumpfile("plic-network.vcd");
      $dumpvars(0, tb_plic_network);
    end
    core_axi.arvalid = 0;
    core_axi.araddr = 0;
    core_axi.arid = 0;
    core_axi.arlen = 0;
    core_axi.arsize = 2;
    core_axi.arburst = 1;
    core_axi.arcache = 0;
    core_axi.rready = 0;
    core_axi.awvalid = 0;
    core_axi.awaddr = 0;
    core_axi.awid = 0;
    core_axi.awlen = 0;
    core_axi.awsize = 2;
    core_axi.awburst = 1;
    core_axi.awcache = 0;
    core_axi.wvalid = 0;
    core_axi.wdata = 0;
    core_axi.wstrb = 0;
    core_axi.wlast = 1;
    core_axi.bready = 0;
    offchip_axi.arready = 1;
    offchip_axi.awready = 0;
    offchip_axi.wready = 0;
    offchip_axi.rvalid = 0;
    offchip_axi.rdata = 0;
    offchip_axi.rid = 0;
    offchip_axi.rresp = 0;
    offchip_axi.rlast = 1;
    offchip_axi.bvalid = 0;
    offchip_axi.bid = 0;
    offchip_axi.bresp = 0;
    clint_bus.rdata = 0;
    clint_bus.timer_int = 0;
    clint_bus.sw_int = 0;
    clint_bus.mtime_value = 0;
    tick(3);
    reset = 0;
    tick();
    write_reg(Source * 4, 1);
    write_reg(EnableS, 1 << Source);
    write_reg('h201000, 0);
    case (scenario)
      0: begin
        // More than the observed 44 interrupts: continuously nonempty RX queue,
        // RX/TX sharing source 4, W delay and both response channels stalled.
        for (int batch = 0; batch < 32; batch++) begin
          rx_packets = 8;
          tx_pending = 1;
          tick(3);
          for (int packet = 0; packet < 8; packet++) begin
            check(plic_bus.seip[0] && !plic_bus.meip[0], "S-mode IRQ missing/misrouted");
            claims_before = accepted_claims;
            read_reg(ClaimS, value, packet % 5);
            check(value == Source && accepted_claims == claims_before + 1,
                  "claim was lost or repeated under R backpressure");
            read_reg(ClaimS, value);
            check(value == 0, "same source claimed twice before completion");
            tx_pending = 0;
            rx_packets--;
            write_reg(ClaimS, Source, (batch + packet) % 7);
            tick(3);
          end
          read_reg(ClaimS, value);
          check(value == 0 && !plic_bus.seip[0], "empty MAC left a pending IRQ");
        end
        check(accepted_claims == 256 && completed == 256, "claim/complete count mismatch");
      end
      1: begin
        // A new packet arrives while the previous source is in service. The
        // low/high transition is not required: completing a held level rearms.
        rx_packets = 1;
        tick(3);
        read_reg(ClaimS, value);
        check(value == Source, "initial claim missing");
        rx_packets = 0;
        tick(2);
        rx_packets = 2;
        tick(2);
        write_reg(EnableS, 0);
        write_reg(ClaimS, Source);
        write_reg(EnableS, 1 << Source);
        read_reg(ClaimS, value);
        check(value == 0, "disabled-context completion incorrectly released source");
        write_reg(ClaimS, Source);
        tick(3);
        read_reg(ClaimS, value);
        check(value == Source, "packet arriving during service was lost");
        // MAC IRQ masking must not erase a PLIC request already admitted.
        mac_enabled = 0;
        write_reg(ClaimS, Source);
        tick(3);
        check(!plic_bus.seip[0], "MAC mask failed");
        mac_enabled = 1;
        tick(3);
        read_reg(ClaimS, value);
        check(value == Source, "MAC unmask did not retrigger queued RX");
        rx_packets = 0;
        write_reg(ClaimS, Source);
        tick(3);
        check(!plic_bus.seip[0], "IRQ remained after queue drain");
      end
      2: begin
        // Linux can poll claim while its previous completion is on W. Before
        // completion the polling read returns zero; the level must re-pend.
        rx_packets = 2;
        tick(3);
        read_reg(ClaimS, value);
        check(value == Source, "initial claim missing");
        core_axi.awaddr = Base + XLEN'(ClaimS);
        core_axi.awvalid = 1;
        tick();
        core_axi.awvalid = 0;
        core_axi.wdata = XLEN'(Source) << (8 * (ClaimS % WB));
        core_axi.wstrb = WB'(15) << (ClaimS % WB);
        core_axi.wvalid = 1;
        issue_read(Base + XLEN'(ClaimS), 9);
        core_axi.wvalid = 0;
        take_response(9, 0, 4);
        core_axi.bready = 1;
        tick();
        core_axi.bready = 0;
        read_reg(ClaimS, value);
        check(value == Source, "completion/read overlap lost the next IRQ");
        rx_packets = 0;
        write_reg(ClaimS, Source);
      end
      3, 4: begin
        // A packet-status read is already offered on R, but the CPU stalls.
        // A later, different-ID PLIC claim must not replace that offered beat.
        core_axi.arlen = scenario == 4 ? 3 : 0;
        issue_read(XLEN'('h11002810), 3);
        core_axi.arlen = 0;
        offchip_axi.rvalid = 1;
        offchip_axi.rid = 3;
        offchip_axi.rdata = XLEN'('h12345678);
        offchip_axi.rlast = scenario == 3;
        tick(2);
        rx_packets = 1;
        tick(3);
        issue_read(Base + XLEN'(ClaimS), 9);
        if (scenario == 3) begin
          take_response(3, XLEN'('h12345678), 4);
        end else begin
          for (int beat = 0; beat < 4; beat++) begin
            offchip_axi.rdata = XLEN'('h12345678 + beat);
            offchip_axi.rlast = beat == 3;
            #1;
            repeat (5) begin
              check(
                  core_axi.rvalid && core_axi.rid == 3
                    && core_axi.rdata == XLEN'('h12345678 + beat)
                    && core_axi.rlast == (beat == 3),
                  "PLIC response interleaved a burst");
              tick();
            end
            core_axi.rready = 1;
            tick();
            core_axi.rready = 0;
          end
        end
        offchip_axi.rvalid = 0;
        take_response(9, XLEN'(Source) << (8 * (ClaimS % WB)), 4);
        rx_packets = 0;
        write_reg(ClaimS, Source);
        check(accepted_claims == 1 && completed == 1, "claim lost behind stalled MAC read");
      end
      5: begin
        // Current W4 disables L2 and the core accepts every R beat. Exercise
        // the corresponding no-backpressure overlap as a separate control.
        rx_packets = 1;
        tick(3);
        issue_read(XLEN'('h11002810), 3);
        core_axi.rready = 1;
        offchip_axi.rvalid = 1;
        offchip_axi.rid = 3;
        offchip_axi.rdata = XLEN'('h12345678);
        #1;
        check(core_axi.rvalid && core_axi.rid == 3 && offchip_axi.rready,
              "ready MAC response did not handshake");
        issue_read(Base + XLEN'(ClaimS), 9);
        offchip_axi.rvalid = 0;
        #1;
        check(
            core_axi.rvalid && core_axi.rid == 9
              && core_axi.rdata == (XLEN'(Source) << (8 * (ClaimS % WB))),
            "claim following ready MAC response was lost");
        tick();
        core_axi.rready = 0;
        rx_packets = 0;
        write_reg(ClaimS, Source);
        check(accepted_claims == 1 && completed == 1, "ready-path claim count mismatch");
      end
      default: $fatal(1, "unknown CASE");
    endcase
    $display("PASS: PLIC network contract XLEN=%0d CASE=%0d claims=%0d completions=%0d", XLEN,
             scenario, accepted_claims, completed);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "PLIC network test timed out");
  end
endmodule
