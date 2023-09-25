module top(
    input [2:0]mode,
    input [3:0] a,
    input [3:0] b,
    output reg [3:0] c,
    output reg of, cr
);
    always @(*) begin
        of = 0;
        cr = 0;
        case (mode)
            3'b000:
                begin
                    c = a + b;
                    cr = (c < a) | (c < b);
                end
            3'b001: 
                begin
                    c = a - b;
                    of = (c > a);
                end
            3'b010: c = ~a;
            3'b011: c = a & b;
            3'b100: c = a | b;
            3'b101: c = a ^ b;
            3'b110: c = a < b ? 1 : 0;
            3'b111: c = a == b ? 1 : 0;
            default: 
                c = 0;
        endcase
    end
endmodule //top
