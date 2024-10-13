`default_nettype none
//`define DBG

module UartTx #(
    parameter unsigned CLK_FREQ  = 66_000_000,
    parameter unsigned BAUD_RATE = 9600
) (
    input wire rst,
    input wire clk,
    input wire [7:0] data,  // data to send
    input wire go,  // enable to start transmission, disable after 'data' has been read
    output reg tx,  // uart tx wire
    output reg bsy  // enabled while sendng
);

  localparam unsigned BitTime = CLK_FREQ / BAUD_RATE;

  localparam unsigned StateIdle = 0;
  localparam unsigned StateStartBit = 1;
  localparam unsigned StateDataBits = 2;
  localparam unsigned StateStopBit = 3;
  localparam unsigned StateWaitGoLow = 4;

  reg [$clog2(5)-1:0] state;
  reg [$clog2(9)-1:0] bit_count;
  reg [(BitTime == 1 ? 1 : $clog2(BitTime))-1:0] BitTime_counter;

  always @(negedge clk) begin
    if (rst) begin
      state <= StateIdle;
      bit_count <= 0;
      BitTime_counter <= 0;
      tx <= 1;
      bsy <= 0;
    end else begin
      unique case (state)
        StateIdle: begin
          if (go) begin
            bsy <= 1;
            // -1 because first 'tick' of 'start bit' is being sent in this state
            BitTime_counter <= 12'(BitTime - 1);
            tx <= 0;  // start sending 'start bit'
            state <= StateStartBit;
          end
        end
        StateStartBit: begin
          if (BitTime_counter == 0) begin
            // -1 because first 'tick' of the first bit is being sent in this state
            BitTime_counter <= 12'(BitTime - 1);
            tx <= data[0];  // start sending first bit of data
            bit_count <= 1;  // first bit is being sent during this cycle
            state <= StateDataBits;
          end else begin
            BitTime_counter <= BitTime_counter - 1;
          end
        end
        StateDataBits: begin
          if (BitTime_counter == 0) begin
            tx <= data[bit_count[2:0]];
            // -1 because first 'tick' of next bit is sent in this state
            BitTime_counter <= 12'(BitTime - 1);
            bit_count <= bit_count + 1;
            if (bit_count == 8) begin
              bit_count <= 0;
              tx <= 1;  // start sending stop bit
              state <= StateStopBit;
            end
          end else begin
            BitTime_counter <= BitTime_counter - 1;
          end
        end
        StateStopBit: begin
          if (BitTime_counter == 0) begin
            bsy   <= 0;
            state <= StateWaitGoLow;
          end else begin
            BitTime_counter <= BitTime_counter - 1;
          end
        end
        StateWaitGoLow: begin
          if (!go) begin  // wait for acknowledge that 'data' has been sent
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
