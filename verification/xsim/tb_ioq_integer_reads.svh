// Give ready directed-test operands stable physical identities. Pending tags
// keep their supplied identity; the bank implements ordinary completion writes.
localparam int TestPhysRegs  = rapt_pkg::CoreConfig.phys_regs;
localparam int TestPhysBits  = rapt_pkg::PLENPkg;
localparam int TestEntries   = rapt_pkg::CoreConfig.ioq_entries;
localparam int TestIndexBits = $clog2(TestEntries);
logic [TestEntries-1:0] test_live;
logic [TestIndexBits-1:0] test_head, test_tail;
logic [1:0][TestPhysBits-1:0] test_sources[TestEntries];
logic [XLEN-1:0] test_prf[TestPhysRegs];
logic [TestPhysRegs-1:0] test_prf_valid;

always_comb begin
  logic [TestPhysRegs-1:0] used;
  used = '0;
  used[0] = 1'b1;
  for (int e = 0; e < TestEntries; e++) begin
    if (test_live[e]) begin
      used[test_sources[e][0]] = 1'b1;
      used[test_sources[e][1]] = 1'b1;
    end
  end
  for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
    used[dispatch[s].pr1] = 1'b1;
    used[dispatch[s].pr2] = 1'b1;
  end
  for (int p = 0; p < rapt_pkg::CompletionPorts; p++)
  if (completion[p].valid) used[completion[p].prd] = 1'b1;
  for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
    test_int_sources[s] = '0;
    for (int k = 0; k < 2; k++) begin
      automatic logic found;
      automatic logic [TestPhysBits-1:0] pending_tag;
      automatic logic [XLEN-1:0] value;
      found = 1'b0;
      pending_tag = k == 0 ? dispatch[s].pr1 : dispatch[s].pr2;
      value = k == 0 ? dispatch[s].op1 : dispatch[s].op2;
      if (pending_tag != '0) test_int_sources[s][k] = pending_tag;
      else if (value != '0) begin
        for (int pr = TestPhysRegs - 1; pr > 0; pr--) begin
          if (!found && !used[pr]) begin
            test_int_sources[s][k] = TestPhysBits'(pr);
            if (test_allocate[s]) used[pr] = 1'b1;
            found = 1'b1;
          end
        end
      end
    end
  end
end

always_ff @(posedge clock) begin
  int unsigned preceding;
  preceding = 0;
  for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
    if (test_allocate[s]) begin
      test_live[test_tail+TestIndexBits'(preceding)] <= 1'b1;
      test_sources[test_tail+TestIndexBits'(preceding)] <= test_int_sources[s];
      preceding++;
    end
  end
  test_tail <= test_tail + TestIndexBits'(preceding);
  if (test_retire) begin
    test_live[test_head] <= 1'b0;
    test_head <= test_head + 1'b1;
  end
  if (reset || cmu_bcast.flush_pipe) begin
    test_live <= '0;
    test_head <= '0;
    test_tail <= '0;
  end
end
for (genvar a = 0; a < TestPhysRegs; a++) begin : g_test_register
  always_ff @(posedge clock) begin
    logic hit;
    logic [XLEN-1:0] value;
    hit = 1'b0;
    value = '0;
    for (int p = 0; p < rapt_pkg::CompletionPorts; p++) begin
      if (completion[p].valid && completion[p].prd == TestPhysBits'(a) && a != 0) begin
        hit = 1'b1;
        value |= completion[p].result;
      end
    end
    if (hit) begin
      test_prf[a] <= value;
      test_prf_valid[a] <= 1'b1;
    end
    for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
      if (test_allocate[s]) begin
        if (dispatch[s].pr1 == '0 && test_int_sources[s][0] == TestPhysBits'(a)) begin
          test_prf[a] <= dispatch[s].op1;
          test_prf_valid[a] <= 1'b1;
        end
        if (dispatch[s].pr2 == '0 && test_int_sources[s][1] == TestPhysBits'(a)) begin
          test_prf[a] <= dispatch[s].op2;
          test_prf_valid[a] <= 1'b1;
        end
      end
    end
    if (reset) test_prf_valid[a] <= a == 0;
  end
end
for (genvar r = 0; r < 1; r++) begin : g_test_read
  always_comb begin
    logic hit;
    logic [XLEN-1:0] value;
    hit = 1'b0;
    value = '0;
    for (int p = 0; p < rapt_pkg::CompletionPorts; p++) begin
      if (test_operand_address[r] != '0 && completion[p].valid
          && completion[p].prd == test_operand_address[r]) begin
        hit = 1'b1;
        value |= completion[p].result;
      end
    end
    test_operand_value[r] = test_operand_address[r] == '0 ? '0
        : hit ? value : test_prf[test_operand_address[r]];
    test_operand_valid[r] = test_operand_address[r] == '0
        || hit || test_prf_valid[test_operand_address[r]];
  end
end
