module formal_predict_history #(
    parameter int GhrBits = 64,
    parameter int PhrBits = 8
) (
    input logic clock,
    reset,
    clear,
    flush,
    decode_recover,
    input logic fetch_valid,
    fetch_taken,
    fetch_pc_bit,
    input logic decode_valid,
    decode_taken,
    decode_pc_bit,
    input logic commit_valid,
    commit_taken,
    commit_pc_bit,
    output logic correct
);
  logic [GhrBits-1:0] fetch_ghr, decode_ghr, commit_ghr, query_ghr;
  logic [PhrBits-1:0] fetch_phr, decode_phr, commit_phr, query_phr;
  rapt_predict_history #(
      .GhrBits(GhrBits),
      .PhrBits(PhrBits)
  ) dut (
      .*
  );
  logic [GhrBits-1:0] g[3], ng[3];
  logic [PhrBits-1:0] p[3], np[3];
  wire [2:0] valid = {commit_valid, decode_valid, fetch_valid};
  wire [2:0] taken = {commit_taken, decode_taken, fetch_taken};
  wire [2:0] pc_bit = {commit_pc_bit, decode_pc_bit, fetch_pc_bit};
  always_comb begin
    for (int s = 0; s < 3; s++) begin
      for (int b = 0; b < GhrBits; b++)
      ng[s][b] = !valid[s] ? g[s][b] : b == 0 ? taken[s] : g[s][b-1];
      for (int b = 0; b < PhrBits; b++)
      np[s][b] = !valid[s] ? p[s][b] : b == 0 ? pc_bit[s] : p[s][b-1];
    end
    if (flush) begin
      ng[0] = ng[2];
      ng[1] = ng[2];
      np[0] = np[2];
      np[1] = np[2];
    end else if (decode_recover) begin
      ng[0] = ng[1];
      np[0] = np[1];
    end
    if (reset || clear) begin
      ng = '{default:'0};
      np = '{default:'0};
    end
  end
  always_ff @(posedge clock) begin
    g <= ng;
    p <= np;
  end
  assign correct = fetch_ghr == g[0] && decode_ghr == g[1] && commit_ghr == g[2]
      && fetch_phr == p[0] && decode_phr == p[1] && commit_phr == p[2]
      && query_ghr == ng[0] && query_phr == np[0];
endmodule
