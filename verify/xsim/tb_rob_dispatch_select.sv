module tb_rob_dispatch_select;
  localparam int Entries = 7;
  localparam int Width = 3;
  localparam int ScanEntries = 5;
  localparam int IndexBits = $clog2(Entries);

  logic [Entries-1:0] pending;
  logic [IndexBits-1:0] head;
  logic endpoint_ready[ScanEntries];
  logic incoming_valid[Width];
  logic [IndexBits-1:0] incoming_index[Width];
  logic candidate_valid[ScanEntries], accepted[ScanEntries];
  logic candidate_incoming[ScanEntries];
  logic [$clog2(Width)-1:0] candidate_source_slot[ScanEntries];
  logic [IndexBits-1:0] candidate_index[ScanEntries];
  int unsigned candidate_count, accepted_count, bypass_count;
  logic oldest_blocked;

  rapt_rob_dispatch_select #(
      .Entries(Entries),
      .Width(Width),
      .ScanEntries(ScanEntries),
      .IndexBits(IndexBits)
  ) dut (
      .*
  );

  task automatic check_case;
    int expected_index[ScanEntries], expected_source[ScanEntries];
    bit expected_incoming[ScanEntries];
    int expected_count, expected_accepted, expected_bypass;
    bit blocked;
    begin
      expected_index = '{default:0};
      expected_source = '{default:0};
      expected_incoming = '{default:0};
      expected_count = 0;
      for (int offset = 0; offset < Entries; offset++) begin
        automatic int index = (int'(head) + offset) % Entries;
        if (pending[index] && expected_count < ScanEntries) begin
          expected_index[expected_count] = index;
          expected_count++;
        end
      end
      for (int incoming = 0; incoming < Width; incoming++) begin
        if (incoming_valid[incoming] && expected_count < ScanEntries) begin
          expected_index[expected_count] = incoming_index[incoming];
          expected_source[expected_count] = incoming;
          expected_incoming[expected_count] = 1'b1;
          expected_count++;
        end
      end
      expected_accepted = 0;
      expected_bypass = 0;
      blocked = 0;
      for (int s = 0; s < ScanEntries; s++) begin
        assert (candidate_valid[s] == (s < expected_count))
        else $fatal(1, "candidate validity mismatch slot=%0d", s);
        if (s < expected_count)
          assert (candidate_index[s] == IndexBits'(expected_index[s]))
          else
            $fatal(
                1,
                "candidate age mismatch slot=%0d got=%0d expected=%0d",
                s,
                candidate_index[s],
                expected_index[s]
            );
        assert (candidate_incoming[s] == expected_incoming[s])
        else $fatal(1, "candidate source kind mismatch slot=%0d", s);
        if (expected_incoming[s])
          assert (candidate_source_slot[s] == $clog2(Width)'(expected_source[s]))
          else $fatal(1, "candidate incoming slot mismatch slot=%0d", s);
        assert (accepted[s] == (s < expected_count && endpoint_ready[s]))
        else $fatal(1, "independent acceptance mismatch slot=%0d", s);
        if (s < expected_count && endpoint_ready[s]) begin
          expected_accepted++;
          if (blocked) expected_bypass++;
        end
        blocked |= s < expected_count && !endpoint_ready[s];
      end
      assert (candidate_count == expected_count
              && accepted_count == expected_accepted
              && bypass_count == expected_bypass)
      else
        $fatal(
            1,
            "count mismatch candidate=%0d/%0d accepted=%0d/%0d bypass=%0d/%0d",
            candidate_count,
            expected_count,
            accepted_count,
            expected_accepted,
            bypass_count,
            expected_bypass
        );
      assert (oldest_blocked == (expected_count != 0 && !endpoint_ready[0]))
      else $fatal(1, "oldest-blocked mismatch");
    end
  endtask

  initial begin
    pending = '0;
    incoming_valid = '{default:1'b0};
    incoming_index = '{default:'0};
    head = 3'd5;
    pending[6] = 1'b1;
    pending[0] = 1'b1;
    pending[2] = 1'b1;
    endpoint_ready = '{1'b0, 1'b1, 1'b1, 1'b0, 1'b1};
    #1;
    check_case();
    assert (candidate_index[0] == 6 && candidate_index[1] == 0
            && candidate_index[2] == 2 && bypass_count == 2 && oldest_blocked)
    else $fatal(1, "directed wrap/bypass case failed");

    pending = '0;
    incoming_valid = '{1'b1, 1'b1, 1'b1};
    incoming_index = '{3'd4, 3'd5, 3'd6};
    endpoint_ready = '{default:1'b1};
    #1;
    check_case();
    assert (candidate_incoming[0] && candidate_source_slot[0] == 0
            && candidate_index[0] == 4 && accepted_count == Width)
    else $fatal(1, "directed allocation fall-through case failed");

    for (int iteration = 0; iteration < 10000; iteration++) begin
      pending = Entries'($urandom);
      head = IndexBits'($urandom_range(0, Entries-1));
      for (int s = 0; s < Width; s++) begin
        incoming_index[s] = IndexBits'(s);
        incoming_valid[s] = $urandom_range(0, 1) && !pending[s];
      end
      for (int s = 0; s < ScanEntries; s++) begin
        endpoint_ready[s] = $urandom_range(0, 1);
      end
      #1;
      check_case();
    end
    $display(
        "PASS: ROB dispatch selection age, wrap, allocation fall-through, independent acceptance, and bypass");
    $finish;
  end
endmodule
