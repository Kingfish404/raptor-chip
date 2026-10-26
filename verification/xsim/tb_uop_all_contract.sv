// ---- tb_completion_packets ----
`include "rapt.svh"

// Native completion stages must preserve owner identity and live effects while
// dropping poisoned sidebands that their physical producer cannot generate.
module tb_completion_packets;
  import rapt_pkg::*;
  localparam int Kinds = 6;
  localparam int PacketBits = $bits(completion_t);
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  completion_t source[Kinds], actual[Kinds], expected[Kinds], allowed[Kinds];
  logic [PacketBits-1:0] pattern;
  int unsigned rng = 32'hcdf01234;
  int accepted_count = 0;
  `include "tb_completion_helpers.svh"
  `TB_COMPLETION_STAGE(alu, 0)
  `TB_COMPLETION_STAGE(branch, 1)
  `TB_COMPLETION_STAGE(mdu, 2)
  `TB_COMPLETION_STAGE(system, 3)
  `TB_COMPLETION_STAGE(fpu, 4)
  `TB_COMPLETION_STAGE(lsu, 5)
  `undef TB_COMPLETION_STAGE

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  initial begin
    for (int k = 0; k < Kinds; k++) begin
      source[k] = '0;
      allowed[k] = '0;
      allowed[k].updates = '1;
      allowed[k].pc = '1;
      allowed[k].npc = '1;
      allowed[k].dest = '1;
      allowed[k].generation = '1;
      allowed[k].valid = 1'b1;
      if (k != 1) begin
        allowed[k].result = '1;
        allowed[k].prd = '1;
        allowed[k].rd = '1;
      end
      if (k >= 3) begin
        allowed[k].trap = 1'b1;
        allowed[k].tval = '1;
        allowed[k].cause = '1;
      end
    end
    allowed[1].btaken = 1'b1;
    allowed[3].csr_wen = 1'b1;
    allowed[3].csr_wdata = '1;
    allowed[3].difftest_skip = 1'b1;
    allowed[4].fp_wen = 1'b1;
    allowed[4].fp_result = '1;
    allowed[4].fp_flags = '1;
    allowed[4].fp_flags_valid = 1'b1;
    allowed[5].fp_wen = 1'b1;
    allowed[5].fp_result = '1;
    allowed[5].wen = 1'b1;
    allowed[5].alu = '1;
    allowed[5].sq_waddr = '1;
    allowed[5].sq_wdata = '1;
    allowed[5].sq_wdata64 = '1;
    allowed[5].sq_fp64 = 1'b1;
    allowed[5].difftest_skip = 1'b1;
    repeat (2) @(negedge clock);
    for (int cycle = 0; cycle < 1024; cycle++) begin
      reset = cycle % 127 == 0;
      flush = cycle % 19 < 2;
      for (int k = 0; k < Kinds; k++) begin
        for (int bit_id = 0; bit_id < PacketBits; bit_id++) begin
          if (bit_id % 32 == 0) void'(random_word());
          pattern[bit_id] = rng[bit_id%32];
        end
        source[k] = completion_t'(pattern);
        source[k].valid = (cycle + k) % 4 != 0;
        expected[k] = source[k] & allowed[k];
        expected[k].valid = source[k].valid && !reset && !flush;
      end
      @(posedge clock);
      #1;
      for (int k = 0; k < Kinds; k++) begin
        assert (actual[k].valid == expected[k].valid)
        else $fatal(1, "native valid mismatch kind=%0d cycle=%0d", k, cycle);
        if (expected[k].valid) begin
          assert (actual[k] == expected[k])
          else $fatal(1, "native payload mismatch kind=%0d cycle=%0d", k, cycle);
          accepted_count++;
        end
      end
      @(negedge clock);
    end
    assert (accepted_count > 4000)
    else $fatal(1, "insufficient native packet coverage");
    $display("BITS RV%0d generic=%0d alu=%0d branch=%0d mdu=%0d system=%0d fpu=%0d lsu=%0d",
             `RAPT_XLEN, $bits(completion_t), $bits(alu_completion_t), $bits(branch_completion_t),
             $bits(mdu_completion_t), $bits(system_completion_t), $bits(fpu_completion_t),
             $bits(lsu_completion_t));
    $display("PASS: native completion packets RV%0d kinds=6 cycles=1024 accepted=%0d", `RAPT_XLEN,
             accepted_count);
    $finish;
  end
endmodule


// ---- tb_uop_instruction_metadata ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_uop_instruction_metadata;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  rapt_pkg::issue_packet_t issued;
  rapt_pkg::completion_t completed;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  cmu_bcast_if #(.XLEN(X)) cmu_bcast ();
  exu_csr_if #(.XLEN(X)) exu_csr ();
  rapt_decode_slot #(
      .XLEN(X),
      .DerivedConstants(1)
  ) decode (
      .*
  );
  rapt_ieu_pipe_alu_csr #(
      .XLEN(X)
  ) execute (
      .iss(issued),
      .csr_read_addr(12'b0),
      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),
      .exu_csr(exu_csr),
      .wb_alu_csr(completed)
  );
  int checks = 0;
  logic [31:0] encoding;
  task automatic load_instruction(input logic [31:0] instruction);
    fetched.inst = instruction;
    #1;
    issued = '0;
    issued.valid = 1;
    issued.uop = decoded.uop;
    issued.op1 = rapt_pkg::derive_op1(decoded.op1, decoded.uop.pc,
        decoded.uop.imm, decoded.uop.imm[16:12]);
    #1;
  endtask
  initial begin
    fetched = '0;
    fetched.pc = rapt_pkg::pc_t'('h80004000);
    fetched.pnpc = fetched.pc + 4;
    issued = '0;
    csr_bcast.priv = 3;
    csr_bcast.fs = 3;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    csr_bcast.menvcfg_cbie = 3;
    csr_bcast.senvcfg_cbie = 3;
    csr_bcast.menvcfg_cbcfe = 1;
    csr_bcast.senvcfg_cbcfe = 1;
    csr_bcast.menvcfg_cbze = 1;
    csr_bcast.senvcfg_cbze = 1;
    exu_csr.rdata = 0;
    exu_csr.rmw_data = 0;
    // CSR address and encoded source survive independently, including x0/uimm0.
    for (int funct3 = 1; funct3 < 8; funct3++) begin
      if (funct3 == 4) continue;
      for (int source = 0; source < 32; source++) begin
        load_instruction(32'h340000f3 | (32'(funct3) << 12) | (32'(source) << 15));
        if (decoded.uop.trap || exu_csr.raddr != 12'h340
            || completed.csr_wen != (funct3 == 1 || funct3 == 5 || source != 0)
            || (funct3 >= 5 && issued.op1 != X'(source)))
          $fatal(1, "CSR metadata source=%0d funct3=%0d", source, funct3);
        checks++;
      end
    end
    // The immediate equals the CSR address here; selector derivation must not
    // confuse the packed payload with the operand immediate.
    load_instruction(32'h0010d0f3);
    if (decoded.uop.trap || issued.op1 != X'(1) || exu_csr.raddr != 12'h001)
      $fatal(1, "CSR uimm/address selector alias");
    checks++;
    for (int kind = 0; kind < 2; kind++)
    for (int rs1 = 0; rs1 < 32; rs1++)
    for (int rs2 = 0; rs2 < 32; rs2++) begin
      load_instruction(
          (kind == 0 ? 32'h12000073 : 32'h16000073) | (32'(rs1) << 15) | (32'(rs2) << 20));
      if (decoded.uop.trap || decoded.uop.execute.sys.kind != rapt_pkg::SYS_TRANSLATION
          || decoded.uop.imm[1:0] != {1'(rs2 == 0), 1'(rs1 == 0)})
        $fatal(1, "translation metadata kind=%0d rs1=%0d rs2=%0d", kind, rs1, rs2);
      checks++;
    end
    for (int flags = 0; flags < 4; flags++) begin
      load_instruction(32'h000322af | (32'(flags) << 25));
      if ({decoded.uop.execute.memory.aq, decoded.uop.execute.memory.rl} != 2'(flags))
        $fatal(1, "atomic metadata flags=%0d", flags);
      checks++;
    end
    for (int rd = 0; rd < 32; rd++)
    for (int rs1 = 0; rs1 < 32; rs1++) begin
      load_instruction(32'h00000067 | (32'(rd) << 7) | (32'(rs1) << 15));
      if (decoded.uop.execute.branch.ras != rapt_pkg::ras_action(fetched.inst))
        $fatal(1, "JALR metadata rd=%0d rs1=%0d", rd, rs1);
      checks++;
    end
    // The immediate union preserves FP subencodings and dynamic-rm trap bits;
    // half loads/stores retain their displacement instead.
    for (int form = 0; form < 11; form++) begin
      case (form)
        0: encoding = 32'h003170d3;
        1: encoding = 32'he40000d3;
        2: encoding = 32'hf40000d3;
        3: encoding = 32'h402000d3;
        4: encoding = 32'h422000d3;
        5: encoding = 32'h440000d3;
        6: encoding = 32'h441000d3;
        7: encoding = 32'hfc001087;
        8: encoding = 32'hfc101027;
        9: encoding = 32'hfc002087;
        default: encoding = 32'hfc102027;
      endcase
      load_instruction(encoding);
      if (decoded.uop.trap) $fatal(1, "unexpected FP trap inst=%h", encoding);
      if (!decoded.uop.execute.memory.load && !decoded.uop.execute.memory.store
          && decoded.uop.imm != encoding)
        $fatal(1, "FP instruction loss");
      if (rapt_pkg::fp_sources(
              decoded.uop.execute.fp.valid,
              decoded.uop.execute.fp.op,
              rapt_pkg::fp_instruction(
                  decoded.uop.execute.memory.load,
                  decoded.uop.execute.memory.store,
                  decoded.uop.imm)
          ) != rapt_pkg::fp_sources(
              decoded.uop.execute.fp.valid, decoded.uop.execute.fp.op, encoding
          ) || rapt_pkg::fp_writes_register(
              decoded.uop.execute.fp.valid,
              decoded.uop.execute.fp.op,
              rapt_pkg::fp_instruction(
                  decoded.uop.execute.memory.load,
                  decoded.uop.execute.memory.store,
                  decoded.uop.imm)
          ) != rapt_pkg::fp_writes_register(
              decoded.uop.execute.fp.valid, decoded.uop.execute.fp.op, encoding
          ))
        $fatal(1, "FP dependency metadata inst=%h", encoding);
      checks++;
    end
    for (int kind = 0; kind < 6; kind++) begin
      case (kind)
        0: encoding = 32'h0000000f;
        1: encoding = 32'h0000100f;
        2: encoding = 32'h0010200f;
        3: encoding = 32'h0000200f;
        4: encoding = 32'h0020200f;
        default: encoding = 32'h0040200f;
      endcase
      load_instruction(encoding);
      if (decoded.uop.trap || decoded.uop.execute.sys.kind !=
          (kind == 0 ? rapt_pkg::SYS_FENCE : kind == 1 ? rapt_pkg::SYS_FENCE_I
          : kind == 2 ? rapt_pkg::SYS_CBO_CLEAN : kind == 5 ? rapt_pkg::SYS_CBO_ZERO
          : rapt_pkg::SYS_CBO_INVAL))
        $fatal(1, "fence/CBO metadata");
      checks++;
    end
    $display("PASS: uop instruction metadata RV%0d checks=%0d uop_bits=%0d", X, checks,
             $bits(rapt_pkg::uop_t));
    $finish;
  end
endmodule


// ---- tb_uop_payload ----
`include "rapt.svh"
`include "rapt_if.svh"

// Compare packed constant operands against the generated decoder's full values.
// Check xtval reconstruction independently at both halves of a fetch boundary.
module tb_uop_payload;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t values, packed_values;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(
      .XLEN(X),
      .DerivedConstants(1'b0)
  ) value_decoder (
      .fetched,
      .csr_bcast,
      .decoded(values)
  );
  rapt_decode_slot #(
      .XLEN(X),
      .DerivedConstants(1'b1)
  ) packed_decoder (
      .fetched,
      .csr_bcast,
      .decoded(packed_values)
  );
  int checks = 0;
  logic [31:0] instruction;
  logic [X-1:0] expected, fetch_address;
  task automatic check(input logic condition, input string message);
    if (!condition) $fatal(1, "%s RV%0d inst=%h", message, X, fetched.inst);
    checks++;
  endtask
  task automatic operands(input logic [31:0] insn);
    fetched.inst = insn;
    #1;
    check(values.uop.trap == packed_values.uop.trap, "legality changed");
    if (!values.uop.trap) begin
      check(rapt_pkg::derive_op1(
            packed_values.op1,
            packed_values.uop.pc,
            packed_values.uop.imm,
            packed_values.uop.imm[16:12]
            ) == values.op1, "packed op1 differs from generated value");
      check(rapt_pkg::derive_op2(packed_values.op2, packed_values.uop.imm) == values.op2,
            "packed op2 differs from generated value");
    end else begin
      check(rapt_pkg::uop_tval(packed_values.uop
            ) == X'(insn[1:0] == 3 ? insn : {16'b0, insn[15:0]}),
            "illegal instruction raw bits lost");
    end
  endtask
  initial begin
    fetched = '0;
    csr_bcast.priv = `RAPT_PRIV_M;
    csr_bcast.fs = 2'b11;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    csr_bcast.menvcfg_cbie = 2'b11;
    csr_bcast.menvcfg_cbcfe = 1;
    csr_bcast.menvcfg_cbze = 1;
    fetched.pc = rapt_pkg::pc_t'(64'hffff_ffff_8000_1000);
    // Full signed 12-bit range: I/load/store, including both extreme offsets.
    for (int i = 0; i < 4096; i++) begin
      operands({12'(i), 5'd1, 3'b000, 5'd2, 7'h13});
      check(packed_values.uop.imm == 32'($signed(12'(i))), "I sign extension");
      operands({7'(i >> 5), 5'd2, 5'd1, 3'b010, 5'(i), 7'h23});
      check(packed_values.uop.imm == 32'($signed(12'(i))), "S sign extension");
      operands({12'(i), 5'd1, 3'b010, 5'd2, 7'h03});
    end
    for (int i = 0; i < 64; i++) begin
      operands({6'b0, 6'(i), 5'd1, 3'b001, 5'd2, 7'h13});
      operands({6'b010000, 6'(i), 5'd1, 3'b101, 5'd2, 7'h13});
    end
    // U/J/B extremes and negative offsets that would fail zero extension on RV64.
    operands(32'h8000_00b7);
    check(rapt_pkg::derive_op1(
          packed_values.op1, fetched.pc, packed_values.uop.imm, packed_values.uop.imm[16:12]
          ) == X'($signed(32'h8000_0000)), "LUI upper sign");
    operands(32'h8000_0097);
    check(X'($signed(packed_values.uop.imm)) == X'($signed(32'h8000_0000)), "AUIPC upper sign");
    operands(32'hffdff0ef);
    check(X'($signed(packed_values.uop.imm)) == X'(-4), "JAL negative offset");
    operands(32'hfe208ee3);
    check(X'($signed(packed_values.uop.imm)) == X'(-4), "branch negative offset");
    // Every compressed encoding, including raw illegal values and C.LUI.
    for (int i = 0; i < 65536; i++) if ((i & 3) != 3) operands({16'b0, 16'(i)});
    // Fetch faults win over illegal decode and reconstruct either halfword.
    for (int high = 0; high < 2; high++) begin
      fetch_address = high != 0 ? X'(64'hffff_ffff_ffff_fffe) : X'(64'h0000_0000_3fff_fffe);
      fetched.pc = rapt_pkg::pc_t'(fetch_address);
      fetched.inst = 32'hffff_ffff;
      fetched.trap = 1;
      for (int page_fault = 0; page_fault < 2; page_fault++) begin
        fetched.cause = page_fault != 0 ? 6'd12 : 6'd1;
        for (int halfword = 0; halfword < 2; halfword++) begin
          fetched.fetch_tval_plus2 = 1'(halfword);
          expected = fetch_address + X'(2 * halfword);
          #1;
          check(packed_values.uop.cause == fetched.cause, "fetch cause priority");
          check(rapt_pkg::uop_tval(packed_values.uop) == expected, "fetch xtval halfword");
        end
      end
    end
    $display("PASS: compact uop payload RV%0d checks=%0d", X, checks);
    $finish;
  end
endmodule
