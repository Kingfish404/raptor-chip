module top(
    input en,
    input [7:0] sw,
    output reg [2:0] led
);
    always @(*) begin
        if(en) begin
            casez (sw)
                8'b1???????: led = 3'b111;
                8'b01??????: led = 3'b110;
                8'b001?????: led = 3'b101;
                8'b0001????: led = 3'b100;
                8'b00001???: led = 3'b011;
                8'b000001??: led = 3'b010;
                8'b0000001?: led = 3'b001;
                8'b00000001: led = 3'b000;
                default:
                    led = 3'b000;
            endcase
        end
    end
endmodule //top
