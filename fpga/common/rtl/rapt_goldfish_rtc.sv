// Synthesizable Google Goldfish RTC (`google,goldfish-rtc`) peripheral.
// Implements the standard 32-bit MMIO register ABI used by Linux
// (`drivers/rtc/rtc-goldfish.c`) and QEMU `virt`:
//   0x00 TIME_LOW        (R: atomic latch high + read low 32b ns; W: set low 32b ns)
//   0x04 TIME_HIGH       (R: latched high 32b ns; W: set high 32b ns)
//   0x08 ALARM_LOW       (R/W: low 32b alarm ns; write arms alarm)
//   0x0C ALARM_HIGH      (R/W: high 32b alarm ns)
//   0x10 IRQ_ENABLED     (R/W: bit 0 enables alarm interrupt)
//   0x14 CLEAR_ALARM     (W: disarms pending alarm)
//   0x18 ALARM_STATUS    (R: bit 0 indicates alarm is armed)
//   0x1C CLEAR_INTERRUPT (W: clears pending alarm interrupt)
module rapt_goldfish_rtc #(
    parameter int ClockHz = 50_000_000
) (
    input logic clk,
    input logic reset,
    input logic rd_i,
    input logic wr_i,
    input logic [4:0] addr_i,
    input logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic irq_o
);
  localparam logic [63:0] NsPerSec = 64'd1_000_000_000;
  localparam logic [63:0] ClkHzU = 64'(ClockHz);
  localparam logic [63:0] NsPerTick = NsPerSec / ClkHzU;
  localparam logic [63:0] NsRemPerTick = NsPerSec % ClkHzU;

  logic [63:0] time_ns_q;
  logic [31:0] time_high_latch_q;
  logic [63:0] alarm_ns_q;
  logic [63:0] frac_acc_q;
  logic alarm_armed_q;
  logic irq_enabled_q;
  logic irq_pending_q;

  logic [63:0] frac_sum;
  logic frac_carry;
  logic [63:0] time_ns_next;
  logic [63:0] frac_acc_next;
  logic alarm_hit;
  logic _unused;

  assign _unused = &{1'b0, addr_i[1:0]};
  assign irq_o = irq_pending_q & irq_enabled_q;

  always_comb begin
    frac_sum = frac_acc_q + NsRemPerTick;
    frac_carry = (NsRemPerTick != 64'd0) && (frac_sum >= ClkHzU);
    frac_acc_next = frac_carry ? (frac_sum - ClkHzU) : frac_sum;
    time_ns_next = time_ns_q + NsPerTick + (frac_carry ? 64'd1 : 64'd0);
    alarm_hit = alarm_armed_q && (time_ns_next >= alarm_ns_q);

    case (addr_i[4:2])
      3'h0: rdata_o = time_ns_q[31:0];
      3'h1: rdata_o = time_high_latch_q;
      3'h2: rdata_o = alarm_ns_q[31:0];
      3'h3: rdata_o = alarm_ns_q[63:32];
      3'h4: rdata_o = {31'd0, irq_enabled_q};
      3'h5: rdata_o = 32'd0;
      3'h6: rdata_o = {31'd0, alarm_armed_q};
      3'h7: rdata_o = 32'd0;
      default: rdata_o = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      time_ns_q         <= 64'd0;
      time_high_latch_q <= 32'd0;
      alarm_ns_q        <= 64'd0;
      frac_acc_q        <= 64'd0;
      alarm_armed_q     <= 1'b0;
      irq_enabled_q     <= 1'b0;
      irq_pending_q     <= 1'b0;
    end else begin
      // Advance monotonic nanosecond counter unless overridden by TIME write.
      time_ns_q  <= time_ns_next;
      frac_acc_q <= frac_acc_next;

      // Latch TIME_HIGH atomically on TIME_LOW read.
      if (rd_i && addr_i[4:2] == 3'h0) begin
        time_high_latch_q <= time_ns_q[63:32];
      end

      // Fire one-shot alarm when counter reaches or passes alarm target.
      if (alarm_hit && !(wr_i && (addr_i[4:2] == 3'h2 || addr_i[4:2] == 3'h5))) begin
        alarm_armed_q <= 1'b0;
        irq_pending_q <= 1'b1;
      end

      // MMIO register writes take precedence on the same cycle.
      if (wr_i) begin
        case (addr_i[4:2])
          3'h0: begin
            time_ns_q  <= {time_ns_q[63:32], wdata_i};
            frac_acc_q <= 64'd0;
          end
          3'h1: begin
            time_ns_q <= {wdata_i, time_ns_q[31:0]};
          end
          3'h2: begin
            alarm_ns_q[31:0] <= wdata_i;
            alarm_armed_q    <= 1'b1;
          end
          3'h3: begin
            alarm_ns_q[63:32] <= wdata_i;
          end
          3'h4: begin
            irq_enabled_q <= wdata_i[0];
          end
          3'h5: begin
            alarm_armed_q <= 1'b0;
          end
          3'h7: begin
            irq_pending_q <= 1'b0;
          end
          default: ;
        endcase
      end
    end
  end
endmodule
