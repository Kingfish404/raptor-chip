module tb_operand_value_spill_banked #(
    parameter int Xlen = 64
);
  localparam int Entries = 32;
  localparam int Width = 4;
  localparam int Bits = $clog2(Entries);
  typedef logic [127:0] test_uop_t;
  logic clock = 0;
  logic reset = 1;
  logic flush = 0;
  logic allocate_valid[Width], allocate_ready[Width];
  test_uop_t allocate_uop[Width], read_uop[Width];
  logic [Xlen-1:0] allocate_op1[Width], allocate_op2[Width];
  logic [6:0] allocate_pr1[Width], allocate_pr2[Width];
  logic [Bits-1:0] allocate_index[Width];
  logic release_valid[Width];
  logic [Bits-1:0] release_index[Width];
  logic [Bits-1:0] read_index[Width];
  logic read_valid[Width];
  logic [Xlen-1:0] read_op1[Width], read_op2[Width];
  logic [6:0] read_pr1[Width], read_pr2[Width];
  logic completion_valid[2];
  logic [6:0] completion_prd[2];
  logic [Xlen-1:0] completion_result[2];
  test_uop_t expected[Entries];
  bit expected_valid[Entries];
  int stage;

  always #5 clock = ~clock;

  rapt_operand_value_spill #(
      .Xlen(Xlen),
      .UopT(test_uop_t),
      .PhysBits(7),
      .SpillEntries(Entries),
      .AllocateWidth(Width),
      .ReleaseWidth(Width),
      .ReadPorts(Width),
      .CompletionPorts(2)
  ) dut (.*);

  task automatic check_all;
    for (int group = 0; group < Entries / Width; group++) begin
      for (int p = 0; p < Width; p++) read_index[p] = Bits'(group * Width + p);
      #1;
      for (int p = 0; p < Width; p++) begin
        int e = group * Width + p;
        assert (read_valid[p] == expected_valid[e])
        else $fatal(1, "read validity stage=%0d entry=%0d got=%0d expected=%0d", stage, e,
                    read_valid[p], expected_valid[e]);
        if (expected_valid[e])
          assert (read_uop[p] == expected[e])
          else $fatal(1, "uop mismatch entry=%0d got=%h expected=%h", e, read_uop[p], expected[e]);
      end
    end
  endtask

  task automatic allocate_four(input int token);
    @(negedge clock);
    for (int a = 0; a < Width; a++) begin
      allocate_valid[a] = 1'b1;
      allocate_uop[a] = 128'((token << 8) | a);
    end
    #1;
    for (int a = 0; a < Width; a++) begin
      assert (allocate_ready[a]) else $fatal(1, "allocation lane %0d blocked", a);
      expected_valid[allocate_index[a]] = 1'b1;
      expected[allocate_index[a]] = allocate_uop[a];
    end
    @(posedge clock);
    #1;
    allocate_valid = '{default:1'b0};
  endtask

  task automatic recycle_four(input int a0, a1, a2, a3, token);
    int slots[Width] = '{a0, a1, a2, a3};
    @(negedge clock);
    for (int r = 0; r < Width; r++) begin
      release_valid[r] = 1'b1;
      release_index[r] = Bits'(slots[r]);
    end
    @(posedge clock);
    #1;
    release_valid = '{default:1'b0};
    for (int r = 0; r < Width; r++) expected_valid[slots[r]] = 1'b0;
    check_all();
    allocate_four(token);
    check_all();
  endtask

  initial begin
    allocate_valid = '{default:1'b0};
    allocate_uop = '{default:'0};
    allocate_op1 = '{default:'0};
    allocate_op2 = '{default:'0};
    allocate_pr1 = '{default:'0};
    allocate_pr2 = '{default:'0};
    release_valid = '{default:1'b0};
    release_index = '{default:'0};
    read_index = '{default:'0};
    completion_valid = '{default:1'b0};
    completion_prd = '{default:'0};
    completion_result = '{default:'0};
    expected_valid = '{default:1'b0};
    expected = '{default:'0};
    repeat (2) @(posedge clock);
    #1;
    reset = 0;
    for (int group = 0; group < Entries / Width; group++) allocate_four(group + 1);
    stage = 1;
    check_all();
    stage = 2;
    recycle_four(1, 6, 10, 15, 100);
    stage = 3;
    recycle_four(0, 2, 4, 7, 101);
    @(negedge clock);
    flush = 1;
    @(posedge clock);
    #1;
    flush = 0;
    expected_valid = '{default:1'b0};
    stage = 4;
    check_all();
    stage = 5;
    allocate_four(200);
    check_all();
    $display("PASS: four-lane spill uop bank selection, reuse, and flush");
    $finish;
  end
endmodule
