module tb_operand_value_spill;
  localparam int Xlen = 64;
  localparam int PhysBits = 6;
  localparam int SpillEntries = 8;
  localparam int AllocateWidth = 2;
  localparam int CompletionPorts = 3;
  localparam int SpillBits = $clog2(SpillEntries);
  typedef logic [31:0] test_uop_t;

  logic clock, reset, flush;
  logic allocate_valid[AllocateWidth], allocate_ready[AllocateWidth];
  test_uop_t allocate_uop[AllocateWidth], read_uop[AllocateWidth];
  logic [Xlen-1:0] allocate_op1[AllocateWidth], allocate_op2[AllocateWidth];
  logic [PhysBits-1:0] allocate_pr1[AllocateWidth], allocate_pr2[AllocateWidth];
  logic [SpillBits-1:0] allocate_index[AllocateWidth];
  logic release_valid[AllocateWidth];
  logic [SpillBits-1:0] release_index[AllocateWidth];
  logic [SpillBits-1:0] read_index[AllocateWidth];
  logic read_valid[AllocateWidth];
  logic [Xlen-1:0] read_op1[AllocateWidth], read_op2[AllocateWidth];
  logic [PhysBits-1:0] read_pr1[AllocateWidth], read_pr2[AllocateWidth];
  logic completion_valid[CompletionPorts];
  logic [PhysBits-1:0] completion_prd[CompletionPorts];
  logic [Xlen-1:0] completion_result[CompletionPorts];

  always #5 clock = ~clock;

  rapt_operand_value_spill #(
      .Xlen(Xlen),
      .UopT(test_uop_t),
      .PhysBits(PhysBits),
      .SpillEntries(SpillEntries),
      .AllocateWidth(AllocateWidth),
      .ReleaseWidth(AllocateWidth),
      .ReadPorts(AllocateWidth),
      .CompletionPorts(CompletionPorts)
  ) dut (
      .*
  );

  task automatic clear_inputs;
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
  endtask

  initial begin
    clock = 1'b0;
    reset = 1'b1;
    flush = 1'b0;
    clear_inputs();
    repeat (2) @(posedge clock);
    reset = 1'b0;

    // Allocate two blocked owners whose first and second operands depend on
    // the same completion. Both compact entries must capture the value.
    allocate_valid = '{1'b1, 1'b1};
    allocate_uop = '{32'h3333_0003, 32'h7777_0007};
    allocate_op1 = '{64'h30, 64'h70};
    allocate_op2 = '{64'h31, 64'h71};
    allocate_pr1 = '{6'd9, 6'd11};
    allocate_pr2 = '{6'd10, 6'd9};
    #1;
    assert (allocate_ready[0] && allocate_ready[1]);
    @(posedge clock);
    #1;
    read_index = '{SpillBits'(0), SpillBits'(1)};
    allocate_valid = '{default:1'b0};
    completion_valid[0] = 1'b1;
    completion_prd[0] = 6'd9;
    completion_result[0] = 64'h9999;
    #1;
    // Stored values change on the completion edge; dispatch muxes remain
    // responsible for merging completion in the cycle before this edge.
    assert (read_op1[0] == 64'h30 && read_op2[1] == 64'h71);
    @(posedge clock);
    #1;
    assert (read_valid[0] && read_valid[1]);
    assert (read_uop[0] == 32'h3333_0003 && read_uop[1] == 32'h7777_0007)
    else $fatal(1, "resident uop payload changed during completion capture");
    assert (read_op1[0] == 64'h9999 && read_op2[1] == 64'h9999)
    else $fatal(1, "multi-consumer completion capture failed");
    assert (read_pr1[0] == '0 && read_pr2[1] == '0 && read_pr2[0] == 6'd10 && read_pr1[1] == 6'd11)
    else $fatal(1, "spill-local waiting tags did not update with values");

    // Two independent completion ports update opposite operands together.
    completion_valid = '{1'b1, 1'b1, 1'b0};
    completion_prd = '{6'd10, 6'd11, 6'd0};
    completion_result = '{64'haaaa, 64'hbbbb, 64'h0};
    @(posedge clock);
    #1;
    assert (read_op2[0] == 64'haaaa && read_op1[1] == 64'hbbbb)
    else $fatal(1, "multi-port completion capture failed");
    assert (read_pr2[0] == '0 && read_pr1[1] == '0)
    else $fatal(1, "completed local tags remained live");

    // A released slot ignores an old-owner completion and is atomically
    // overwritten by the new owner when registered reclaim becomes visible.
    clear_inputs();
    release_valid[0] = 1'b1;
    release_index[0] = SpillBits'(0);
    @(posedge clock);
    #1;
    release_valid[0] = 1'b0;
    allocate_valid[0] = 1'b1;
    allocate_uop[0] = 32'h9999_0009;
    allocate_op1[0] = 64'h9000;
    allocate_op2[0] = 64'h9001;
    allocate_pr1[0] = 6'd12;
    completion_valid[0] = 1'b1;
    completion_prd[0] = 6'd9;
    completion_result[0] = 64'hdead;
    #1;
    assert (allocate_ready[0] && allocate_index[0] == 0);
    @(posedge clock);
    #1;
    completion_valid = '{default:1'b0};
    allocate_valid = '{default:1'b0};
    assert (read_op1[0] == 64'h9000 && read_op2[0] == 64'h9001)
    else $fatal(1, "allocation did not win release/update overlap");
    assert (read_uop[0] == 32'h9999_0009)
    else $fatal(1, "reclaimed spill slot retained the previous uop");
    assert (read_pr1[0] == 6'd12 && read_pr2[0] == '0)
    else $fatal(1, "reclaimed spill slot retained an old waiting tag");

    flush = 1'b1;
    @(posedge clock);
    #1;
    assert (!read_valid[0] && !read_valid[1])
    else $fatal(1, "flush did not clear spill");
    $display("PASS: operand value spill local tags, broadcast capture, priority, and flush");
    $finish;
  end
endmodule
