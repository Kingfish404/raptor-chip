// Native completion projections use the same registered-stage wiring.
`define TB_COMPLETION_STAGE(kind, index) \
  kind``_completion_t kind``_input, kind``_output; \
  assign kind``_input = pack_``kind``_completion(source[index]); \
  assign actual[index] = expand_``kind``_completion(kind``_output); \
  rapt_completion_stage #(.CompletionT(kind``_completion_t)) kind``_stage ( \
      .clock, .reset, .flush, .accepted(kind``_input), .completion(kind``_output));
