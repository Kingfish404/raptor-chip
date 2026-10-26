module tb_dispatch_compact;

  import rapt_pkg::*;
  localparam int NumCandidates = 7;
  localparam int CandidateBits = index_bits(NumCandidates);
  localparam int NumSlots = DispatchWidth;
  localparam int NumDomains = ExecutionDomains;

  logic clock = 0;
  logic reset = 1;
  always #5 clock = ~clock;

  execution_domain_t candidate_domain[NumCandidates];
  logic candidate_valid[NumCandidates];
  logic candidate_ready[NumCandidates];
  logic selected_valid[NumSlots];
  logic [index_bits(NumCandidates)-1:0] selected_candidate[NumSlots];
  dispatch_capacity_t capacity[NumDomains];
  dispatch_grant_t grant[NumDomains];

  rapt_dpu #(.NumCandidates(NumCandidates)) dut (.*);

  task automatic check_case;
    int expected_candidate[NumSlots];
    int expected_domain_rank[NumSlots];
    int used[NumDomains];
    int selected;
    begin
      expected_candidate = '{default:-1};
      expected_domain_rank = '{default:0};
      used = '{default:0};
      selected = 0;
      for (int c = 0; c < NumCandidates; c++) begin
        automatic int domain = int'(candidate_domain[c]);
        automatic bit accept = candidate_valid[c] && domain < NumDomains
            && selected < NumSlots && capacity[domain].ready[used[domain]];
        assert (candidate_ready[c] == accept)
        else
          $fatal(
              1,
              "candidate ready mismatch c=%0d got=%0b expected=%0b",
              c,
              candidate_ready[c],
              accept
          );
        if (accept) begin
          expected_candidate[selected] = c;
          expected_domain_rank[selected] = used[domain];
          used[domain]++;
          selected++;
        end
      end
      for (int s = 0; s < NumSlots; s++) begin
        assert (selected_valid[s] == (s < selected))
        else $fatal(1, "compacted validity mismatch slot=%0d", s);
        if (s < selected) begin
          automatic int c = expected_candidate[s];
          automatic int domain = int'(candidate_domain[c]);
          assert (selected_candidate[s] == CandidateBits'(c))
          else $fatal(1, "age/order mismatch slot=%0d candidate=%0d", s, c);
          for (int d = 0; d < NumDomains; d++) begin
            assert (grant[d].accept[s] == (d == domain))
            else $fatal(1, "grant target mismatch slot=%0d domain=%0d", s, d);
          end
          assert (grant[domain].index[s] == capacity[domain].free_index[expected_domain_rank[s]])
          else $fatal(1, "free-index rank mismatch slot=%0d", s);
        end else begin
          for (int d = 0; d < NumDomains; d++)
          assert (!grant[d].accept[s])
          else $fatal(1, "grant asserted for empty compacted slot=%0d domain=%0d", s, d);
        end
      end
    end
  endtask

  initial begin
    candidate_domain = '{default:execution_domain_t'(0)};
    candidate_valid = '{default:1'b0};
    capacity = '{default:'0};
    #11;
    reset = 0;

    // The two oldest owners target a full branch queue. The wider candidate
    // window must expose and accept the younger integer owner in the same
    // cycle instead of reproducing a two-entry head-of-line window.
    candidate_valid[0] = 1'b1;
    candidate_valid[1] = 1'b1;
    candidate_valid[2] = 1'b1;
    candidate_domain[0] = execution_domain_t'(DOMAIN_BRANCH);
    candidate_domain[1] = execution_domain_t'(DOMAIN_BRANCH);
    candidate_domain[2] = execution_domain_t'(DOMAIN_INTEGER);
    capacity[DOMAIN_INTEGER].ready[0] = 1'b1;
    capacity[DOMAIN_INTEGER].free_index[0] = queue_index_t'(3);
    #1;
    check_case();
    assert (!candidate_ready[0] && !candidate_ready[1] && candidate_ready[2]
            && selected_valid[0] && selected_candidate[0] == 2)
    else $fatal(1, "directed blocked-domain bypass failed");

    for (int iteration = 0; iteration < 20000; iteration++) begin
      for (int d = 0; d < NumDomains; d++) begin
        automatic int free_count = $urandom_range(0, NumSlots);
        for (int r = 0; r < NumSlots; r++) begin
          capacity[d].ready[r] = r < free_count;
          capacity[d].free_index[r] = queue_index_t'(d * NumSlots + r);
        end
      end
      for (int c = 0; c < NumCandidates; c++) begin
        candidate_domain[c] = execution_domain_t'($urandom_range(0, NumDomains-1));
        candidate_valid[c] = $urandom_range(0, 1);
      end
      #1;
      check_case();
    end
    $display(
        "PASS: capacity-aware dispatch compaction, blocked-domain bypass, age, rank and grants");
    $finish;
  end
endmodule
