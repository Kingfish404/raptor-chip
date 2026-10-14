// Console UART: NS16550 register layout, 16-byte receive FIFO, fixed 8N1.
// Divisor is in units of 16 input clocks. THR has one holding slot in addition
// to the shift register. FIFO identification stays disabled (16450 TX depth),
// so the Linux 8250 driver never assumes a 16-byte transmit FIFO.
module rapt_native_uart #(
    parameter int ClockHz = 50_000_000,
    parameter int Baud = 115200
) (
    input logic clk,
    input logic reset,
    input logic rx,
    output logic tx,
    output logic irq,
    input logic rd,
    input logic wr,
    input logic [2:0] addr,
    input logic [7:0] wdata,
    output logic [7:0] rdata
);
  localparam int DefaultDivisor = (ClockHz + Baud * 8) / (Baud * 16);
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync = '1;
  logic [15:0] divisor;
  logic [7:0] lcr, mcr, scratch;
  logic [3:0] ier;
  logic [19:0] bit_ticks;
  logic [19:0] tx_ticks, rx_ticks;
  logic [9:0] tx_shift;
  logic [3:0] tx_bits, rx_bits;
  logic [7:0] tx_hold, rx_shift;
  logic tx_pending, tx_irq, rx_active, overrun, framing;
  logic [7:0] rx_fifo[16];
  logic [3:0] rx_head, rx_tail;
  logic [4:0] rx_count;
  logic rx_push, rx_pop, rx_clear, tx_clear;
  logic [7:0] iir;

  assign bit_ticks = {divisor == 0 ? 16'd1 : divisor, 4'b0};
  assign tx = tx_bits == 0 ? 1'b1 : tx_shift[0];
  assign rx_pop = rd && addr == 0 && !lcr[7] && rx_count != 0;
  assign rx_push = rx_active && rx_ticks == 0 && rx_bits == 9 && rx_sync[1];
  assign rx_clear = wr && addr == 2 && wdata[1];
  assign tx_clear = wr && addr == 2 && wdata[2];
  always_comb begin
    iir = 8'h01;
    if (ier[2] && (overrun || framing)) iir = 8'h06;
    else if (ier[0] && rx_count != 0) iir = 8'h04;
    else if (ier[1] && tx_irq) iir = 8'h02;
    irq = !iir[0];
    case (addr)
      0: rdata = lcr[7] ? divisor[7:0] : (rx_count != 0 ? rx_fifo[rx_head] : 8'b0);
      1: rdata = lcr[7] ? divisor[15:8] : {4'b0, ier};
      2: rdata = iir;
      3: rdata = lcr;
      4: rdata = mcr;
      5: rdata = {1'b0, !tx_pending && tx_bits == 0, !tx_pending, 1'b0,
                 framing, 1'b0, overrun, rx_count != 0};
      6: rdata = 8'hb0;  // CTS, DSR, DCD asserted; no modem flow control.
      7: rdata = scratch;
      default: rdata = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    rx_sync <= {rx_sync[0], rx};
    if (reset) begin
      divisor <= 16'(DefaultDivisor);
      lcr <= 8'h03;
      mcr <= 0;
      scratch <= 0;
      ier <= 0;
      tx_ticks <= 0;
      tx_shift <= '1;
      tx_bits <= 0;
      tx_hold <= 0;
      tx_pending <= 0;
      tx_irq <= 1;
      rx_ticks <= 0;
      rx_bits <= 0;
      rx_shift <= 0;
      rx_active <= 0;
      rx_head <= 0;
      rx_tail <= 0;
      rx_count <= 0;
      overrun <= 0;
      framing <= 0;
    end else begin
      if (rd && addr == 2 && iir == 8'h02) tx_irq <= 0;
      if (rd && addr == 5) begin
        overrun <= 0;
        framing <= 0;
      end
      if (tx_bits != 0) begin
        if (tx_ticks != 0) tx_ticks <= tx_ticks - 1'b1;
        else begin
          tx_ticks <= bit_ticks - 1'b1;
          tx_shift <= {1'b1, tx_shift[9:1]};
          tx_bits <= tx_bits - 1'b1;
        end
      end else if (tx_pending) begin
        tx_shift <= {1'b1, tx_hold, 1'b0};
        tx_bits <= 10;
        tx_ticks <= bit_ticks - 1'b1;
        tx_pending <= 0;
        tx_irq <= 1;
      end
      if (wr) begin
        case (addr)
          0:
          if (lcr[7]) divisor[7:0] <= wdata;
          else begin
            tx_hold <= wdata;
            tx_pending <= 1;
            tx_irq <= 0;
          end
          1:
          if (lcr[7]) divisor[15:8] <= wdata;
          else begin
            ier <= wdata[3:0];
            if (wdata[1] && !ier[1] && !tx_pending) tx_irq <= 1;
          end
          3: lcr <= wdata;
          4: mcr <= wdata;
          7: scratch <= wdata;
          default: ;
        endcase
      end
      if (tx_clear) begin
        tx_pending <= 0;
        tx_irq <= 1;
      end

      if (!rx_active) begin
        if (!rx_sync[1]) begin
          rx_active <= 1;
          rx_ticks <= (bit_ticks >> 1) - 1'b1;
          rx_bits <= 0;
        end
      end else if (rx_ticks != 0) rx_ticks <= rx_ticks - 1'b1;
      else begin
        rx_ticks <= bit_ticks - 1'b1;
        rx_bits <= rx_bits + 1'b1;
        if (rx_bits == 0 && rx_sync[1]) rx_active <= 0;
        else if (rx_bits >= 1 && rx_bits <= 8) rx_shift[rx_bits-1] <= rx_sync[1];
        else if (rx_bits == 9) begin
          rx_active <= 0;
          if (!rx_sync[1]) framing <= 1;
        end
      end
      if (rx_pop) rx_head <= rx_head + 1'b1;
      if (rx_push) begin
        if (rx_count < 16 || rx_pop) begin
          rx_fifo[rx_tail] <= rx_shift;
          rx_tail <= rx_tail + 1'b1;
        end else overrun <= 1;
      end
      case ({
        rx_push && (rx_count < 16 || rx_pop), rx_pop
      })
        2'b10: rx_count <= rx_count + 1'b1;
        2'b01: rx_count <= rx_count - 1'b1;
        default: ;
      endcase
      if (rx_clear) begin
        rx_count <= 0;
        rx_head <= 0;
        rx_tail <= 0;
        overrun <= 0;
        framing <= 0;
      end
    end
  end
endmodule
