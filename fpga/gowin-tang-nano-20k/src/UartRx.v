`default_nettype none
//`define DBG

module UartRx #(
    parameter unsigned CLK_FREQ  = 66_000_000,
    parameter unsigned BAUD_RATE = 9600
) (
    input wire rst,
    input wire clk,
    input wire rx,
    input wire go,
    output reg [7:0] data,
    output reg dr  // enabled when data is ready
);

  localparam unsigned BitTime = CLK_FREQ / BAUD_RATE;

  localparam unsigned StateIdle = 0;
  localparam unsigned StateStartBit = 1;
  localparam unsigned StateDataBits = 2;
  localparam unsigned StateStopBit = 3;
  localparam unsigned StateWaitGoLow = 4;

  reg [$clog2(5)-1:0] state;
  reg [$clog2(9)-1:0] bit_count;
  reg [(BitTime == 1 ? 1 : $clog2(BitTime))-1:0] bit_counter;

  always @(posedge clk) begin
    if (rst) begin
      state <= StateIdle;
      data <= 0;
      bit_count <= 0;
      bit_counter <= 0;
      dr <= 0;
    end else begin
      unique case (state)
        StateIdle: begin
          if (!rx && go) begin  // does the cpu wait for data and start bit has started?
            bit_count <= 0;
            if (BitTime == 1) begin
              // the start bit has been read, jump to data
              // -1 because one of the ticks has been read before switching state
              bit_counter <= 12'(BitTime - 1);
              state <= StateDataBits;
            end else begin
              // get sample from half of the cycle
              // -1 because one of the ticks has been read before switching state
              bit_counter <= 12'(BitTime / 2 - 1);
              state <= StateStartBit;
            end
          end
        end
        StateStartBit: begin
          if (bit_counter == 0) begin  // no check if rx==0 because there is no error recovery
            // -1 because one of the ticks has been read before switching state
            bit_counter <= 12'(BitTime - 1);
            state <= StateDataBits;
          end else begin
            bit_counter <= bit_counter - 1;
          end
        end
        StateDataBits: begin
          if (bit_counter == 0) begin
            data[bit_count[2:0]] <= rx;
            // -1 because one of the ticks has been read before switching state
            bit_counter <= 12'(BitTime - 1);
            bit_count <= bit_count + 1;
            if (bit_count == 7) begin  // 7, not 8, because of NBA of bit_count
              bit_count <= 0;
              state <= StateStopBit;
            end
          end else begin
            bit_counter <= bit_counter - 1;
          end
        end
        StateStopBit: begin
          if (bit_counter == 0) begin  // no check if rx==1 because there is no error recovery
            dr <= 1;
            state <= StateWaitGoLow;
          end else begin
            bit_counter <= bit_counter - 1;
          end
        end
        StateWaitGoLow: begin
          if (!go) begin
            data <= 0;
            dr <= 0;
            state <= StateIdle;
          end
        end
        default: begin
          state <= StateIdle;
        end
      endcase
    end
  end

endmodule

`undef DBG
`default_nettype wire
