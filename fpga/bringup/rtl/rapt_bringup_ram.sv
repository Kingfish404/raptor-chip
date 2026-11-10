// Same-clock dual-port byte-write memory. Neither port resets the stored data.
// Host and CPU writes are mutually exclusive at the platform boundary. Keep one
// procedural writer to satisfy the repository's native SystemVerilog contract.
module rapt_bringup_ram #(
    parameter int Words = 16384,
    parameter int AddrBits = $clog2(Words)
) (
    input logic clock,
    input logic a_en_i,
    input logic [AddrBits-1:0] a_addr_i,
    input logic [3:0] a_strb_i,
    input logic [31:0] a_data_i,
    output logic [31:0] a_data_o,
    input logic b_en_i,
    input logic [AddrBits-1:0] b_addr_i,
    input logic [3:0] b_strb_i,
    input logic [31:0] b_data_i,
    output logic [31:0] b_data_o
);
  (* ram_style = "block" *) logic [31:0] mem[Words];
  always_ff @(posedge clock) begin
    if (a_en_i) begin
      for (int lane = 0; lane < 4; lane++)
      if (a_strb_i[lane]) mem[a_addr_i][8*lane+:8] <= a_data_i[8*lane+:8];
      a_data_o <= mem[a_addr_i];
    end
    if (b_en_i) begin
      for (int lane = 0; lane < 4; lane++)
      if (b_strb_i[lane]) mem[b_addr_i][8*lane+:8] <= b_data_i[8*lane+:8];
      b_data_o <= mem[b_addr_i];
    end
  end
endmodule
