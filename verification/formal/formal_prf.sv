// Select a harness explicitly so unused hierarchical monitors are not elaborated.
`ifdef RAPT_FORMAL_PRF_CONTRACT
// ---- formal_prf_contract ----
`include "rapt.svh"
`include "rapt_if.svh"

// A stable symbolic physical byte proves all addresses and data lanes. Only
// accepted-writer uniqueness, address bounds and quiescent debug are assumed.
module formal_prf_contract #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int ArchRegs = 4,
    parameter int Entries = 8,
    parameter int ReadPorts = 2,
    parameter int RetirePorts = 2,
    parameter int Ports = 3,
    parameter int ExtraPorts = 3,
    parameter int Bits = rapt_pkg::index_bits(Entries),
    parameter int ExtraSlots = ExtraPorts > 0 ? ExtraPorts : 1
) (
    input logic clock,
    reset,
    flush,
    input logic write_valid[Ports],
    input logic [4:0] write_rd[Ports],
    input logic [Bits-1:0] write_address[Ports],
    input logic [Xlen-1:0] write_data[Ports],
    input logic commit_valid[RetirePorts],
    input logic [4:0] commit_rd[RetirePorts],
    input logic [Bits-1:0] commit_prd[RetirePorts],
    commit_prs[RetirePorts],
    input logic [Bits-1:0] read_a[ReadPorts],
    read_b[ReadPorts],
    extra_address[ExtraSlots],
    input logic [Bits-1:0] maps[ArchRegs],
    rat[ArchRegs],
    watched_address,
    input logic [$clog2(Xlen/8)-1:0] watched_byte,
    input logic dbg_we,
    input logic [4:0] dbg_address,
    input logic [Xlen-1:0] dbg_data
);
  localparam int WriterBits = rapt_pkg::index_bits(Ports + 1);
`ifdef SYNTHESIS
  localparam bit FullView = !`RAPT_FPGA_LUTRAM;
`else
  localparam bit FullView = 1;
`endif
  typedef struct packed {
    logic valid;
    logic [4:0] rd;
    logic [Bits-1:0] prd;
    logic [Xlen-1:0] result;
  } CompletionT;
  CompletionT completion[Ports];
  exu_prf_if #(
      .Width(ReadPorts),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) reads ();
  rou_cmu_if #(
      .Width(RetirePorts),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) commits ();
  cmu_bcast_if #(.XLEN(Xlen)) broadcast ();
  wire [Xlen-1:0] extra_value[ExtraSlots], rf[ArchRegs], rf_map[ArchRegs], debug_value;
  wire extra_valid[ExtraSlots];
`ifdef RAPT_RVFI
  wire [Xlen-1:0] rvfi_value[RetirePorts];
`endif
  for (genvar p = 0; p < Ports; p++) begin : g_completion
    assign completion[p] = {write_valid[p], write_rd[p], write_address[p], write_data[p]};
  end
  for (genvar c = 0; c < RetirePorts; c++) begin : g_commit
    always_comb begin
      commits.slot[c] = '0;
      commits.slot[c].valid = commit_valid[c];
      commits.slot[c].rd = commit_rd[c];
      commits.slot[c].prd = commit_prd[c];
      commits.slot[c].prs = commit_prs[c];
    end
  end
  for (genvar r = 0; r < ReadPorts; r++) begin : g_read_address
    assign reads.pr1[r] = read_a[r];
    assign reads.pr2[r] = read_b[r];
  end
  assign broadcast.flush_pipe = flush;
  rapt_prf #(
      .ReadWidth(ReadPorts),
      .CommitWidth(RetirePorts),
      .NumCompletions(Ports),
      .CompletionT(CompletionT),
      .ExtraReadPorts(ExtraPorts),
      .RNUM(ArchRegs),
      .PNUM(Entries),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) dut (
      .completion,
      .extra_address,
      .extra_value,
      .extra_valid,
      .clock,
      .reset,
      .prf_rd(reads),
      .rou_cmu(commits),
      .cmu_bcast(broadcast),
      .map_snapshot(maps),
      .rat_snapshot(rat),
      .rf,
      .rf_map,
      .dbg_we_i(dbg_we),
      .dbg_addr_i(dbg_address),
      .dbg_wdata_i(dbg_data),
      .dbg_rdata_o(debug_value)
`ifdef RAPT_RVFI
      ,
      .rvfi_rd_data(rvfi_value)
`endif
  );

  logic legal_addresses, unique_writers, any_write, any_commit;
  logic reclaim, settle, observed_write;
  logic [7:0] incoming_byte;
  logic [WriterBits-1:0] incoming_port;
  always_comb begin
    legal_addresses = 1;
    unique_writers = 1;
    any_write = 0;
    any_commit = 0;
    reclaim = 0;
    settle = 0;
    observed_write = 0;
    incoming_byte = '0;
    incoming_port = '0;
    for (int p = 0; p < Ports; p++) begin
      if (write_valid[p] && write_rd[p] != 0) begin
        any_write = 1;
        legal_addresses &= int'(write_address[p]) < Entries;
        if (write_address[p] == watched_address) begin
          observed_write = 1;
          incoming_byte = write_data[p][int'(watched_byte)*8+:8];
          incoming_port = WriterBits'(p);
        end
        for (int other = 0; other < p; other++)
        if (write_valid[other] && write_rd[other] != 0 && write_address[other] == write_address[p])
          unique_writers = 0;
      end
    end
    for (int c = 0; c < RetirePorts; c++) begin
      if (commit_valid[c] && commit_rd[c] != 0) begin
        any_commit = 1;
        legal_addresses &= int'(commit_prd[c]) < Entries && int'(commit_prs[c]) < Entries;
        reclaim |= commit_prs[c] == watched_address;
        settle |= commit_prd[c] == watched_address;
      end
    end
    for (int r = 0; r < ReadPorts; r++)
    legal_addresses &= int'(read_a[r]) < Entries && int'(read_b[r]) < Entries;
    for (int r = 0; r < ExtraPorts; r++) legal_addresses &= int'(extra_address[r]) < Entries;
    for (int r = 0; r < ArchRegs; r++)
    legal_addresses &= int'(maps[r]) < Entries && int'(rat[r]) < Entries;
  end
  localparam int ArchBits = rapt_pkg::index_bits(ArchRegs);
  wire debug_write = dbg_we && dbg_address != 0 && int'(dbg_address) < ArchRegs
      && rat[ArchBits'(dbg_address)] == watched_address;
  logic past_valid = 0, known = 0, expected_valid, expected_transient;
  logic [7:0] expected_byte;
  logic [WriterBits-1:0] last_writer;
  logic extra_expected_valid;
  wire [7:0] extra_expected_byte = observed_write ? incoming_byte : expected_byte;
  wire extra_known = known || observed_write;
  always_comb extra_expected_valid = expected_valid || observed_write;
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    if (past_valid)
      assume ({watched_address, watched_byte} == $past({watched_address, watched_byte}));
    assume (int'(watched_address) < Entries);
    assume (legal_addresses);
    assume (unique_writers);
    assume (!dbg_we || (!reset && !flush && !any_write && !any_commit));
    past_valid <= 1;
    if (reset) begin
      known <= 0;
      expected_valid <= int'(watched_address) < ArchRegs;
      expected_transient <= 0;
    end else begin
      if (!flush && observed_write) begin
        known <= 1;
        expected_byte <= incoming_byte;
        last_writer <= incoming_port;
      end else if (debug_write) begin
        known <= 1;
        expected_byte <= dbg_data[int'(watched_byte)*8+:8];
        last_writer <= WriterBits'(Ports);
      end
      if (reclaim) expected_valid <= 0;
      else if (settle) expected_transient <= 0;
      else if (flush && expected_transient) begin
        expected_valid <= 0;
        expected_transient <= 0;
      end else if (!flush && observed_write) begin
        expected_valid <= 1;
        expected_transient <= 1;
      end
    end
    if (past_valid) begin
      observed_valid : assert (dut.prf_valid[watched_address] == expected_valid);
      observed_transient : assert (dut.prf_transient[watched_address] == expected_transient);
      architectural_zero : assert (rf[0] == 0 && rf_map[0] == 0);
      if (dbg_address == 0 || int'(dbg_address) >= ArchRegs)
        addressed_zero :
        assert (debug_value == 0);
        else if (known && rat[ArchBits'(dbg_address)] == watched_address)
          debug_data : assert (debug_value[int'(watched_byte)*8+:8] == expected_byte);
    end
    reset_activated : cover (past_valid && reset);
    reclaim_settle : cover (past_valid && known && reclaim && settle && !reset);
    settle_on_flush :
    cover (past_valid && known && expected_transient && settle && flush && !reset);
    flush_write : cover (past_valid && known && observed_write && flush && !reset);
    debug_nonzero : cover (past_valid && debug_write && dbg_data != 0 && !reset);
    debug_zero : cover (past_valid && dbg_address == 0 && !reset);
  end

  localparam int Copies = 2 * ReadPorts + 1 + ExtraPorts;
  for (genvar r = 0; r < (`RAPT_FPGA_LUTRAM ? Copies : 1); r++) begin : g_storage
    wire [7:0] actual_byte;
    if (`RAPT_FPGA_LUTRAM) begin : g_lutram
      wire [7:0] bank_byte[Ports];
      for (genvar p = 0; p < Ports; p++) begin : g_bank
        wire [Xlen-1:0] word_value = dut.g_lutram.g_bank[p].g_copy[r].words[watched_address];
        assign bank_byte[p] = word_value[int'(watched_byte)*8+:8];
      end
      assign actual_byte = bank_byte[dut.g_lutram.lvt[watched_address]];
      always_ff @(posedge clock)
        if (known)
          live_bank : assert (int'(dut.g_lutram.lvt[watched_address]) < Ports);
    end else begin : g_flop
      assign actual_byte = dut.prf_arr[watched_address][int'(watched_byte)*8+:8];
    end
    always_ff @(posedge clock) if (known) stored_byte : assert (actual_byte == expected_byte);
  end
  for (genvar r = 0; r < ReadPorts; r++) begin : g_read
    always_ff @(posedge clock) begin
      if (past_valid) begin
        if (read_a[r] == watched_address) begin
          assert (reads.pv1_valid[r] == expected_valid);
          if (known) assert (reads.pv1[r][int'(watched_byte)*8+:8] == expected_byte);
        end
        if (read_b[r] == watched_address) begin
          assert (reads.pv2_valid[r] == expected_valid);
          if (known) assert (reads.pv2[r][int'(watched_byte)*8+:8] == expected_byte);
        end
      end
      activated_a : cover (known && expected_valid && read_a[r] == watched_address && !reset);
      activated_b : cover (known && expected_valid && read_b[r] == watched_address && !reset);
    end
  end
  for (genvar r = 0; r < ExtraPorts; r++) begin : g_extra
    always_ff @(posedge clock) begin
      if (past_valid) begin
        if (extra_address[r] == 0) begin
          assert (extra_value[r] == 0 && extra_valid[r]);
        end else if (extra_address[r] == watched_address) begin
          assert (extra_valid[r] == extra_expected_valid);
          if (extra_known) assert (extra_value[r][int'(watched_byte)*8+:8] == extra_expected_byte);
        end
      end
      late_bypass :
      cover (known && !expected_valid && observed_write && watched_address != 0
          && incoming_byte != expected_byte && extra_address[r] == watched_address && !reset);
      bypass_during_flush :
      cover (observed_write && flush && watched_address != 0
          && extra_address[r] == watched_address && !reset);
      zero_operand : cover (extra_address[r] == 0 && !reset);
    end
  end
  for (genvar r = 1; r < ArchRegs; r++) begin : g_architectural
    always_ff @(posedge clock) begin
      if (!FullView) begin
        assert (rf[r] == 0 && rf_map[r] == 0);
      end else if (known) begin
        if (rat[r] == watched_address) assert (rf[r][int'(watched_byte)*8+:8] == expected_byte);
        if (maps[r] == watched_address)
          assert (rf_map[r][int'(watched_byte)*8+:8] == expected_byte);
      end
    end
  end
`ifdef RAPT_RVFI
  for (genvar c = 0; c < RetirePorts; c++) begin : g_rvfi
    always_ff @(posedge clock) begin
      if (commits.slot[c].rd == 0)
        assert (rvfi_value[c] == 0);
        else if (known && commits.slot[c].prd == watched_address)
          assert (rvfi_value[c][int'(watched_byte)*8+:8] == expected_byte);
    end
  end
`endif
  for (genvar p = 0; p < Ports; p++) begin : g_writer_cover
    always_ff @(posedge clock)
      activated :
      cover (known && expected_valid && last_writer == p && read_a[0] == watched_address && !reset);
  end
  for (genvar b = 0; b < Xlen / 8; b++) begin : g_byte_cover
    always_ff @(posedge clock)
      activated :
      cover (known && expected_valid && int'(watched_byte) == b && !reset);
  end
endmodule
`endif

`ifdef RAPT_FORMAL_PRF_VIEWS
// ---- formal_prf_views ----
`include "rapt.svh"
`include "rapt_if.svh"

// Combinational view identities over arbitrary current PRF state. The runner
// must verify a constant-true initial predicate and no environmental assumptions;
// one-frame success alone is insufficient for an all-state certificate.
module formal_prf_views #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int ArchRegs = rapt_pkg::CoreConfig.arch_regs,
    parameter int Entries = rapt_pkg::CoreConfig.phys_regs,
    parameter int ReadPorts = rapt_pkg::DispatchWidth,
    parameter int RetirePorts = rapt_pkg::CommitWidth,
    parameter int Ports = rapt_pkg::CompletionPorts,
    parameter int ExtraPorts = 3,
    parameter int Bits = rapt_pkg::index_bits(Entries),
    parameter int ExtraSlots = ExtraPorts > 0 ? ExtraPorts : 1
) (
    input logic clock,
    reset,
    flush,
    input logic write_valid[Ports],
    input logic [4:0] write_rd[Ports],
    input logic [Bits-1:0] write_address[Ports],
    input logic [Xlen-1:0] write_data[Ports],
    input logic commit_valid[RetirePorts],
    input logic [4:0] commit_rd[RetirePorts],
    input logic [Bits-1:0] commit_prd[RetirePorts],
    commit_prs[RetirePorts],
    input logic [Bits-1:0] read_a[ReadPorts],
    read_b[ReadPorts],
    extra_address[ExtraSlots],
    input logic [Bits-1:0] maps[ArchRegs],
    rat[ArchRegs],
    input logic [$clog2(Xlen/8)-1:0] view_byte,
    input logic dbg_we,
    input logic [4:0] dbg_address,
    input logic [Xlen-1:0] dbg_data
);
`ifdef SYNTHESIS
  localparam bit FullView = !`RAPT_FPGA_LUTRAM;
`else
  localparam bit FullView = 1;
`endif
  typedef struct packed {
    logic valid;
    logic [4:0] rd;
    logic [Bits-1:0] prd;
    logic [Xlen-1:0] result;
  } CompletionT;
  CompletionT completion[Ports];
  exu_prf_if #(
      .Width(ReadPorts),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) reads ();
  rou_cmu_if #(
      .Width(RetirePorts),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) commits ();
  cmu_bcast_if #(.XLEN(Xlen)) broadcast ();
  wire [Xlen-1:0] extra_value[ExtraSlots], rf[ArchRegs], rf_map[ArchRegs], debug_value;
  wire extra_valid[ExtraSlots];
`ifdef RAPT_RVFI
  wire [Xlen-1:0] rvfi_value[RetirePorts];
`endif
  for (genvar p = 0; p < Ports; p++) begin : g_completion
    assign completion[p] = {write_valid[p], write_rd[p], write_address[p], write_data[p]};
  end
  for (genvar c = 0; c < RetirePorts; c++) begin : g_commit
    always_comb begin
      commits.slot[c] = '0;
      commits.slot[c].valid = commit_valid[c];
      commits.slot[c].rd = commit_rd[c];
      commits.slot[c].prd = commit_prd[c];
      commits.slot[c].prs = commit_prs[c];
    end
  end
  for (genvar r = 0; r < ReadPorts; r++) begin : g_read_address
    assign reads.pr1[r] = read_a[r];
    assign reads.pr2[r] = read_b[r];
  end
  assign broadcast.flush_pipe = flush;
  rapt_prf #(
      .ReadWidth(ReadPorts),
      .CommitWidth(RetirePorts),
      .NumCompletions(Ports),
      .CompletionT(CompletionT),
      .ExtraReadPorts(ExtraPorts),
      .RNUM(ArchRegs),
      .PNUM(Entries),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) dut (
      .completion,
      .extra_address,
      .extra_value,
      .extra_valid,
      .clock,
      .reset,
      .prf_rd(reads),
      .rou_cmu(commits),
      .cmu_bcast(broadcast),
      .map_snapshot(maps),
      .rat_snapshot(rat),
      .rf,
      .rf_map,
      .dbg_we_i(dbg_we),
      .dbg_addr_i(dbg_address),
      .dbg_wdata_i(dbg_data),
      .dbg_rdata_o(debug_value)
`ifdef RAPT_RVFI
      ,
      .rvfi_rd_data(rvfi_value)
`endif
  );


  if (`RAPT_FPGA_LUTRAM && FullView) begin : g_shadow
    for (genvar i = 0; i < Entries; i++) begin : g_word
      wire [Xlen-1:0] bank_word[Ports];
      wire [7:0] bank_byte[Ports];
      for (genvar p = 0; p < Ports; p++) begin : g_bank
        assign bank_word[p] = dut.g_lutram.g_bank[p].g_copy[0].words[i];
        assign bank_byte[p] = bank_word[p][int'(view_byte)*8+:8];
      end
      always_comb begin
        if (int'(dut.g_lutram.lvt[i]) < Ports)
          shadow_identity :
          assert (dut.prf_arr[i][int'(view_byte)*8+:8] == bank_byte[dut.g_lutram.lvt[i]]);
        shadow_activated : cover (int'(dut.g_lutram.lvt[i]) < Ports);
      end
    end
  end
  for (genvar r = 0; r < ArchRegs; r++) begin : g_arch
    always_comb begin
      if (r == 0) begin
        assert (rf[r] == 0);
        assert (rf_map[r] == 0);
      end else begin
        if (int'(rat[r]) < Entries) begin
          if (FullView)
            assert (rf[r] == dut.prf_arr[rat[r]]);
            else assert (rf[r] == 0);
        end
        committed_activated : cover (int'(rat[r]) < Entries);
        if (int'(maps[r]) < Entries) begin
          if (FullView)
            assert (rf_map[r] == dut.prf_arr[maps[r]]);
            else assert (rf_map[r] == 0);
        end
        speculative_activated : cover (int'(maps[r]) < Entries);
      end
    end
  end
`ifdef RAPT_RVFI
  for (genvar c = 0; c < RetirePorts; c++) begin : g_rvfi
    always_comb begin
      if (commit_rd[c] == 0)
        assert (rvfi_value[c] == 0);
        else if (int'(commit_prd[c]) < Entries)
          assert (rvfi_value[c] == dut.prf_arr[commit_prd[c]]);
      rvfi_zero_activated : cover (commit_rd[c] == 0);
      rvfi_data_activated : cover (commit_rd[c] != 0 && int'(commit_prd[c]) < Entries);
    end
  end
`endif
  for (genvar b = 0; b < Xlen / 8; b++) begin : g_byte_activation
    always_comb activated : cover (int'(view_byte) == b);
  end
  always_comb sampled : cover (1'b1);
endmodule
`endif

`ifdef RAPT_FORMAL_PRF_ZERO
// ---- formal_prf_zero ----
`include "rapt.svh"
`include "rapt_if.svh"

// Idle legal reset state: architectural x0 must be zero even though physical
// register payload has no power-up/reset value. No producer writes are needed.
module formal_prf_zero (
    input logic clock,
    reset
);
  localparam int X = `RAPT_XLEN;
  localparam int P = rapt_pkg::PLENPkg;
  localparam int R = rapt_pkg::CoreConfig.arch_regs;
  localparam int C = rapt_pkg::CommitWidth;
  localparam int W = rapt_pkg::DispatchWidth;
  localparam int N = rapt_pkg::CompletionPorts;
  typedef struct packed {
    logic valid;
    logic [4:0] rd;
    logic [P-1:0] prd;
    logic [X-1:0] result;
  } CompletionT;
  CompletionT completion[N];
  logic [P-1:0] maps[R], rat[R];
  wire [X-1:0] rf[R], rf_map[R], debug_value;
  exu_prf_if #(
      .Width(W),
      .PLEN(P),
      .XLEN(X)
  ) reads ();
  rou_cmu_if #(
      .Width(C),
      .PLEN(P),
      .XLEN(X)
  ) commits ();
  cmu_bcast_if #(.XLEN(X)) broadcast ();
  for (genvar p = 0; p < N; p++) assign completion[p] = '0;
  for (genvar r = 0; r < R; r++) begin : g_reset_map
    assign maps[r] = P'(r);
    assign rat[r] = P'(r);
  end
  for (genvar s = 0; s < W; s++) begin : g_idle_read
    assign reads.pr1[s] = '0;
    assign reads.pr2[s] = '0;
  end
  for (genvar c = 0; c < C; c++) assign commits.slot[c] = '0;
  assign broadcast.flush_pipe = 0;
  rapt_prf #(
      .CompletionT(CompletionT),
      .ExtraReadPorts(3)
  ) dut (
      .completion,
      .clock,
      .reset,
      .prf_rd(reads),
      .rou_cmu(commits),
      .cmu_bcast(broadcast),
      .map_snapshot(maps),
      .rat_snapshot(rat),
      .rf,
      .rf_map,
      .dbg_we_i(1'b0),
      .dbg_addr_i(5'b0),
      .dbg_wdata_i('0),
      .dbg_rdata_o(debug_value)
  );
  logic past_valid = 0;
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    past_valid <= 1;
    if (past_valid && !reset) begin
      architectural_debug_zero : assert (debug_value == 0);
      committed_zero : assert (rf[0] == 0);
      speculative_zero : assert (rf_map[0] == 0);
    end
    activated : cover (past_valid && !reset);
  end
endmodule
`endif
