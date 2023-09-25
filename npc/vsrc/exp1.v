module top(
    input [3:0] x,
    input [1:0] y,
    output reg f
);
    always @(*) begin
        case (y)
            2'b00: f = x[0];
            2'b01: f = x[1];
            2'b10: f = x[2];
            2'b11: f = x[3];
            default: 
                f = 1'b0;
        endcase
    end
endmodule //top
