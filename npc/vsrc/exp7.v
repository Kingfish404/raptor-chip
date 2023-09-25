module top (
    input clk,
    input rst,
    input ps2_clk,
    input ps2_data,
    output [7:0] seg0,
    output [7:0] seg1,
    output [7:0] seg2,
    output [7:0] seg3,
    output [7:0] seg4,
    output [7:0] seg5,
    output [7:0] seg6,
    output [7:0] seg7
);
    reg [7:0] count;
    reg [7:0] data;
    reg [23:0] buffer;
    reg [7:0] data_ascii;
    reg ready;
    reg overflow;
    reg pressed = 0;

    reg [1:0] state = 2'b00;
    reg [1:0] nextstate = 2'b00;

    reg [4:0] toseg0;
    reg [4:0] toseg1;
    reg [4:0] toseg2;
    reg [4:0] toseg3;
    ps2_keyboard my_keyboard(
        .clk(clk),
        .clrn(~rst),
        .ps2_clk(ps2_clk),
        .ps2_data(ps2_data),
        .nextdata_n(1'b0),

        .data(data),
        .ready(ready),
        .overflow(overflow)
    );

    num_to_seg num_to_seg0(.en(toseg0[4]), .num(toseg0[3:0]), .seg(seg0));
    num_to_seg num_to_seg1(.en(toseg1[4]), .num(toseg1[3:0]), .seg(seg1));
    num_to_seg num_to_seg2(.en(toseg2[4]), .num(toseg2[3:0]), .seg(seg2));
    num_to_seg num_to_seg3(.en(toseg3[4]), .num(toseg3[3:0]), .seg(seg3));
    num_to_seg num_to_seg4(.en(0), .num(4'b0000), .seg(seg4));
    num_to_seg num_to_seg5(.en(0), .num(4'b0000), .seg(seg5));
    num_to_seg_rom num_to_seg6(.en(1), .num(count[3:0]), .seg(seg6));
    num_to_seg num_to_seg7(.en(1), .num(count[7:4]), .seg(seg7));

    num_to_ascii_rom to_ascii(.en(pressed), .data(buffer[7:0]), .ascii(data_ascii));

    always @(*) begin
        state = nextstate;
    end

    always @(*) begin
        pressed = state == 2'b01;
        toseg0 = {pressed, buffer[3:0]};
        toseg1 = {pressed, buffer[7:4]};
    end

    always @(*) begin
        toseg2 = {pressed, data_ascii[3:0]};
        toseg3 = {pressed, data_ascii[7:4]};
    end

    always @(posedge clk) begin
        if (rst == 1) begin
            count = 0;
            buffer = 0;
            state = 2'b00;
        end
        else begin
            if (ready) begin
                buffer = {buffer[15:8], buffer[7:0], data};
                $display(
                "data=%x, buffer=%x%x%x, ready=%d, overflow=%d, count=%x, state=%b",
                data, buffer[23:16], buffer[15:8], buffer[7:0], ready, overflow, count, state);
                case (state)
                    2'b00: begin
                        nextstate = 2'b01;
                        count = count + 1;
                    end
                    2'b01: begin
                        if (buffer[15:8] == buffer[7:0]) begin
                            nextstate = 2'b01;
                        end
                        else begin
                            nextstate = 2'b10;
                        end
                    end
                    2'b10: nextstate = 2'b00;
                    default: 
                nextstate = 2'b00;
                endcase                
            end
            else;
        end
    end
endmodule

module num_to_ascii_rom(
    input en,
    input [7:0] data,
    output reg [7:0] ascii
);
    reg [7:0] mem[0:255] = {
        8'h00,  8'h01,  8'h02,  8'h03,  8'h04,  8'h05,  8'h06,  8'h07,  
        8'h08,  8'h09,  8'h0a,  8'h0b,  8'h0c,  8'h0d,  8'h60,  8'h0f,  
        8'h10,  8'h11,  8'h12,  8'h13,  8'h14,  8'h51,  8'h31,  8'h17,  
        8'h18,  8'h19,  8'h5a,  8'h53,  8'h41,  8'h57,  8'h32,  8'h1f,  
        8'h20,  8'h43,  8'h58,  8'h44,  8'h45,  8'h34,  8'h33,  8'h27,  
        8'h28,  8'h29,  8'h56,  8'h46,  8'h54,  8'h52,  8'h35,  8'h2f,  
        8'h30,  8'h4e,  8'h42,  8'h48,  8'h47,  8'h59,  8'h36,  8'h37,  
        8'h38,  8'h39,  8'h4d,  8'h4a,  8'h55,  8'h37,  8'h38,  8'h3f,  
        8'h40,  8'h2c,  8'h4b,  8'h49,  8'h4f,  8'h30,  8'h39,  8'h47,  
        8'h48,  8'h2e,  8'h2f,  8'h4c,  8'h3b,  8'h50,  8'h2d,  8'h4f,  
        8'h50,  8'h51,  8'h27,  8'h53,  8'h5b,  8'h3d,  8'h56,  8'h57,  
        8'h58,  8'h59,  8'h5a,  8'h5d,  8'h5c,  8'h5c,  8'h5e,  8'h5f,  
        8'h60,  8'h61,  8'h62,  8'h63,  8'h64,  8'h65,  8'h66,  8'h67,  
        8'h68,  8'h69,  8'h6a,  8'h6b,  8'h6c,  8'h6d,  8'h6e,  8'h6f,  
        8'h70,  8'h71,  8'h72,  8'h73,  8'h74,  8'h75,  8'h76,  8'h77,  
        8'h78,  8'h79,  8'h7a,  8'h7b,  8'h7c,  8'h7d,  8'h7e,  8'h7f,  
        8'h80,  8'h81,  8'h82,  8'h83,  8'h84,  8'h85,  8'h86,  8'h87,  
        8'h88,  8'h89,  8'h8a,  8'h8b,  8'h8c,  8'h8d,  8'h8e,  8'h8f,  
        8'h90,  8'h91,  8'h92,  8'h93,  8'h94,  8'h95,  8'h96,  8'h97,  
        8'h98,  8'h99,  8'h9a,  8'h9b,  8'h9c,  8'h9d,  8'h9e,  8'h9f,  
        8'ha0,  8'ha1,  8'ha2,  8'ha3,  8'ha4,  8'ha5,  8'ha6,  8'ha7,  
        8'ha8,  8'ha9,  8'haa,  8'hab,  8'hac,  8'had,  8'hae,  8'haf,  
        8'hb0,  8'hb1,  8'hb2,  8'hb3,  8'hb4,  8'hb5,  8'hb6,  8'hb7,  
        8'hb8,  8'hb9,  8'hba,  8'hbb,  8'hbc,  8'hbd,  8'hbe,  8'hbf,  
        8'hc0,  8'hc1,  8'hc2,  8'hc3,  8'hc4,  8'hc5,  8'hc6,  8'hc7,  
        8'hc8,  8'hc9,  8'hca,  8'hcb,  8'hcc,  8'hcd,  8'hce,  8'hcf,  
        8'hd0,  8'hd1,  8'hd2,  8'hd3,  8'hd4,  8'hd5,  8'hd6,  8'hd7,  
        8'hd8,  8'hd9,  8'hda,  8'hdb,  8'hdc,  8'hdd,  8'hde,  8'hdf,  
        8'he0,  8'he1,  8'he2,  8'he3,  8'he4,  8'he5,  8'he6,  8'he7,  
        8'he8,  8'he9,  8'hea,  8'heb,  8'hec,  8'hed,  8'hee,  8'hef,  
        8'hf0,  8'hf1,  8'hf2,  8'hf3,  8'hf4,  8'hf5,  8'hf6,  8'hf7,  
        8'hf8,  8'hf9,  8'hfa,  8'hfb,  8'hfc,  8'hfd,  8'hfe,  8'hff
    };
    always @(*) begin
        if (en) begin
            ascii = mem[data];
        end
        else begin
            ascii = 8'h00;
        end
    end
endmodule

module num_to_seg_rom(
    input en,
    input [3:0] num,
    output reg [7:0] seg
);
    reg [7:0] mem [0:15] = {
        8'b11111101, 8'b01100000, 8'b11011010, 8'b11110010,
        8'b01100110, 8'b10110110, 8'b10111110, 8'b11100000,

        8'b11111110, 8'b11110110, 8'b11101110, 8'b00111110,
        8'b10011101, 8'b01111010, 8'b10011110, 8'b10001110
    };
    always @(*) begin
        if (en) begin
            seg = ~mem[num];
        end
        else begin
            seg = ~8'b00000000;
        end
    end
endmodule

module num_to_seg(
    input en,
    input [3:0] num,
    output reg [7:0] seg
);
    always @(*) begin
        if (en) begin
            case (num)
                4'b0000: seg = ~8'b11111101;
                4'b0001: seg = ~8'b01100000;
                4'b0010: seg = ~8'b11011010;
                4'b0011: seg = ~8'b11110010;
                4'b0100: seg = ~8'b01100110;
                4'b0101: seg = ~8'b10110110;
                4'b0110: seg = ~8'b10111110;
                4'b0111: seg = ~8'b11100000;

                4'b1000: seg = ~8'b11111110;
                4'b1001: seg = ~8'b11110110;
                4'b1010: seg = ~8'b11101110;
                4'b1011: seg = ~8'b00111110;
                4'b1100: seg = ~8'b10011101;
                4'b1101: seg = ~8'b01111010;
                4'b1110: seg = ~8'b10011110;
                4'b1111: seg = ~8'b10001110;
                default: 
                seg = ~8'b11111111;
            endcase
        end
        else begin
            seg = ~8'b00000000;
        end
    end
endmodule

module ps2_keyboard(clk,clrn,ps2_clk,ps2_data,data,
                    ready,nextdata_n,overflow);
    input clk,clrn,ps2_clk,ps2_data;
    input nextdata_n;
    output [7:0] data;
    output reg ready;
    output reg overflow;     // fifo overflow
    // internal signal, for test
    reg [9:0] buffer;        // ps2_data bits
    reg [7:0] fifo[7:0];     // data fifo
    reg [2:0] w_ptr,r_ptr;   // fifo write and read pointers
    reg [3:0] count;  // count ps2_data bits
    // detect falling edge of ps2_clk
    reg [2:0] ps2_clk_sync;

    always @(posedge clk) begin
        ps2_clk_sync <=  {ps2_clk_sync[1:0],ps2_clk};
    end

    wire sampling = ps2_clk_sync[2] & ~ps2_clk_sync[1];

    always @(posedge clk) begin
        if (clrn == 0) begin // reset
            count <= 0; w_ptr <= 0; r_ptr <= 0; overflow <= 0; ready<= 0;
        end
        else begin
            if ( ready ) begin // read to output next data
                if(nextdata_n == 1'b0) //read next data
                begin
                    r_ptr <= r_ptr + 3'b1;
                    if(w_ptr==(r_ptr+1'b1)) //empty
                        ready <= 1'b0;
                end
            end
            if (sampling) begin
              if (count == 4'd10) begin
                if ((buffer[0] == 0) &&  // start bit
                    (ps2_data)       &&  // stop bit
                    (^buffer[9:1])) begin      // odd  parity
                    fifo[w_ptr] <= buffer[8:1];  // kbd scan code
                    w_ptr <= w_ptr+3'b1;
                    ready <= 1'b1;
                    overflow <= overflow | (r_ptr == (w_ptr + 3'b1));
                end
                count <= 0;     // for next
              end else begin
                buffer[count] <= ps2_data;  // store ps2_data
                count <= count + 3'b1;
              end
            end
        end
    end
    assign data = fifo[r_ptr]; //always set output data

endmodule