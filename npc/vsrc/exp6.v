module top(
    input clk,
    output reg [7:0] out
);
    reg n;
    always @(posedge clk) begin
        if (out == 8'b00000000) begin
            out = 8'b00000001;
        end
        n = out[4] ^ out[3] ^ out[2] ^ out[0];
        out = out >> 1;
        out[7] = n;
    end
endmodule //top
