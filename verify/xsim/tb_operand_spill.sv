module tb_operand_spill;
  localparam int Entries = 5;
  localparam int AllocateWidth = 2;
  localparam int ReleaseWidth = 2;
  localparam int ReadPorts = 2;
  localparam int IndexBits = $clog2(Entries);
  typedef logic [31:0] payload_t;

  logic clock, reset, flush;
  logic allocate_valid[AllocateWidth], allocate_ready[AllocateWidth];
  payload_t allocate_payload[AllocateWidth];
  logic [IndexBits-1:0] allocate_index[AllocateWidth];
  logic release_valid[ReleaseWidth];
  logic [IndexBits-1:0] release_index[ReleaseWidth];
  logic [IndexBits-1:0] read_index[ReadPorts];
  logic read_valid[ReadPorts];
  payload_t read_payload[ReadPorts];
  logic update_valid[Entries], entry_valid[Entries];
  payload_t update_payload[Entries], entry_payload[Entries];

  logic model_valid[Entries];
  payload_t model_payload[Entries];
  logic pending_release[Entries];

  always #5 clock = ~clock;

  rapt_operand_spill #(
      .PayloadT(payload_t),
      .Entries(Entries),
      .AllocateWidth(AllocateWidth),
      .ReleaseWidth(ReleaseWidth),
      .ReadPorts(ReadPorts)
  ) dut (
      .*
  );

  task automatic clear_inputs;
    allocate_valid = '{default:1'b0};
    allocate_payload = '{default:'0};
    release_valid = '{default:1'b0};
    release_index = '{default:'0};
    read_index = '{default:'0};
    update_valid = '{default:1'b0};
    update_payload = '{default:'0};
  endtask

  task automatic check_comb;
    bit free[Entries];
    bit expected_ready;
    int expected_index;
    begin
      #1;
      for (int e = 0; e < Entries; e++) free[e] = !model_valid[e] || pending_release[e];
      for (int a = 0; a < AllocateWidth; a++) begin
        expected_ready = 1'b0;
        expected_index = 0;
        for (int e = 0; e < Entries; e++) begin
          if (!expected_ready && free[e]) begin
            expected_ready = 1'b1;
            expected_index = e;
          end
        end
        assert (allocate_ready[a] == expected_ready)
        else $fatal(1, "ready mismatch lane=%0d", a);
        if (expected_ready)
          assert (allocate_index[a] == IndexBits'(expected_index))
          else
            $fatal(
                1,
                "index mismatch lane=%0d got=%0d expected=%0d",
                a,
                allocate_index[a],
                expected_index
            );
        if (expected_ready) free[expected_index] = 1'b0;
      end
      for (int p = 0; p < ReadPorts; p++) begin
        automatic int index = int'(read_index[p]);
        assert (read_valid[p] == (model_valid[index] && !pending_release[index]))
        else $fatal(1, "read validity mismatch port=%0d index=%0d", p, index);
        if (read_valid[p])
          assert (read_payload[p] == model_payload[index])
          else $fatal(1, "read payload mismatch port=%0d index=%0d", p, index);
      end
    end
  endtask

  task automatic apply_edge;
    logic next_pending[Entries];
    begin
      next_pending = '{default: 1'b0};
      for (int r = 0; r < ReleaseWidth; r++)
      if (release_valid[r]) next_pending[release_index[r]] = 1'b1;
      for (int e = 0; e < Entries; e++) if (pending_release[e]) model_valid[e] = 1'b0;
      for (int a = 0; a < AllocateWidth; a++) begin
        if (allocate_valid[a] && allocate_ready[a]) begin
          model_valid[allocate_index[a]] = 1'b1;
          model_payload[allocate_index[a]] = allocate_payload[a];
        end
      end
      pending_release = next_pending;
      @(posedge clock);
      #1;
    end
  endtask

  initial begin
    clock = 1'b0;
    reset = 1'b1;
    flush = 1'b0;
    model_valid = '{default:1'b0};
    model_payload = '{default:'0};
    pending_release = '{default:1'b0};
    clear_inputs();
    repeat (2) @(posedge clock);
    reset = 1'b0;
    #1;

    // Fill four slots in two ordered allocations.
    for (int batch = 0; batch < 2; batch++) begin
      allocate_valid = '{1'b1, 1'b1};
      allocate_payload[0] = 32'(batch * 2 + 10);
      allocate_payload[1] = 32'(batch * 2 + 11);
      check_comb();
      apply_edge();
    end
    allocate_valid = '{1'b1, 1'b0};
    allocate_payload[0] = 32'h55;
    check_comb();
    assert (allocate_ready[0] && !allocate_ready[1] && allocate_index[0] == 4)
    else $fatal(1, "partial-capacity case failed");
    apply_edge();

    // Endpoint releases are intentionally not reusable until registered.
    allocate_valid = '{default:1'b0};
    release_valid = '{1'b1, 1'b1};
    release_index = '{IndexBits'(1), IndexBits'(3)};
    check_comb();
    assert (!allocate_ready[0])
    else $fatal(1, "unregistered release leaked into ready");
    apply_edge();
    release_valid = '{default:1'b0};
    allocate_valid = '{1'b1, 1'b1};
    allocate_payload = '{32'h1111, 32'h3333};
    check_comb();
    assert (allocate_index[0] == 1 && allocate_index[1] == 3)
    else $fatal(1, "registered release reuse mismatch");
    apply_edge();

    // Randomized cycle-accurate oracle, including release/allocation overlap.
    for (int iteration = 0; iteration < 10000; iteration++) begin
      automatic int release_count = 0;
      clear_inputs();
      for (int e = 0; e < Entries && release_count < ReleaseWidth; e++) begin
        if (model_valid[e] && !pending_release[e] && $urandom_range(0, 3) == 0) begin
          release_valid[release_count] = 1'b1;
          release_index[release_count] = IndexBits'(e);
          release_count++;
        end
      end
      allocate_valid[0] = 1'($urandom_range(0, 1));
      allocate_valid[1] = allocate_valid[0] && 1'($urandom_range(0, 1));
      allocate_payload[0] = $urandom;
      allocate_payload[1] = $urandom;
      read_index[0] = IndexBits'($urandom_range(0, Entries - 1));
      read_index[1] = IndexBits'($urandom_range(0, Entries - 1));
      check_comb();
      apply_edge();
    end

    flush = 1'b1;
    @(posedge clock);
    #1;
    flush = 1'b0;
    model_valid = '{default:1'b0};
    pending_release = '{default:1'b0};
    clear_inputs();
    check_comb();
    $display("PASS: compact operand spill allocation, registered release reuse, reads, and flush");
    $finish;
  end
endmodule
