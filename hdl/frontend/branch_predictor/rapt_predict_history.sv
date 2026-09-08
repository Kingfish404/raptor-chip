// Histories belong to instruction-stream boundaries, not prediction queries.
// Decode is a recovery watermark for IDU resteers; retirement is the watermark
// for full flush. Each boundary currently accepts at most one conditional/edge.
module rapt_predict_history #(
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
    output logic [GhrBits-1:0] fetch_ghr,
    decode_ghr,
    commit_ghr,
    query_ghr,
    output logic [PhrBits-1:0] fetch_phr,
    decode_phr,
    commit_phr,
    query_phr
);
  typedef struct packed {
    logic [GhrBits-1:0] ghr;
    logic [PhrBits-1:0] phr;
  } history_t;
  history_t fetched, decoded, committed, next_fetch, next_decode, next_commit;
  function automatic history_t append(input history_t old, input logic valid, taken, pc_bit);
    history_t result;
    result = old;
    if (valid) begin
      result.ghr = (old.ghr << 1) | GhrBits'(taken);
      result.phr = (old.phr << 1) | PhrBits'(pc_bit);
    end
    return result;
  endfunction
  always_comb begin
    next_commit = append(committed, commit_valid, commit_taken, commit_pc_bit);
    next_decode = append(decoded, decode_valid, decode_taken, decode_pc_bit);
    next_fetch = append(fetched, fetch_valid, fetch_taken, fetch_pc_bit);
    if (flush) begin
      next_decode = next_commit;
      next_fetch = next_commit;
    end else if (decode_recover) next_fetch = next_decode;
    if (reset || clear) begin
      next_commit = '0;
      next_decode = '0;
      next_fetch = '0;
    end
  end
  // The next PC request is issued on the same edge as acceptance/recovery.
  // Feed its predictor read the post-event history, including the current CFU.
  assign query_ghr = next_fetch.ghr;
  assign query_phr = next_fetch.phr;
  assign fetch_ghr = fetched.ghr;
  assign fetch_phr = fetched.phr;
  assign decode_ghr = decoded.ghr;
  assign decode_phr = decoded.phr;
  assign commit_ghr = committed.ghr;
  assign commit_phr = committed.phr;
  always_ff @(posedge clock) begin
    fetched <= next_fetch;
    decoded <= next_decode;
    committed <= next_commit;
  end
endmodule
