`include "rapt.svh"
`include "rapt_if.svh"

// Actual generic FP issue queue, all arithmetic pipelines, result queues and
// completion arbitration. Values are checked by owner, independent of order.
module tb_feu_ooo;
  import rapt_pkg::*;
  localparam int XLEN   = `RAPT_XLEN;
  localparam int Owners = CoreConfig.rob_entries;
  logic clock = 0, reset = 1, cancel_valid = 0;
  logic [ROBIndexBits-1:0] cancel_head = 0, cancel_owner = 0;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  load_fast_if load_fast ();
  dpu_iq_if #(.RS_SIZE(8)) disp_fpq ();
  dispatch_slot_t dispatch[DispatchWidth];
  completion_t completion[CompletionPorts], external_wake, wb_fpu;
  logic completion_ready = 1, issue_enable;
  logic wb_accept;
  assign wb_accept = wb_fpu.valid && completion_ready;
  for (genvar p = 0; p < CompletionPorts; p++) begin
    if (p == 0)
      always_comb begin
        completion[p] = wb_fpu;
        completion[p].valid = wb_accept;
      end
    else if (p == 1) assign completion[p] = external_wake;
    else assign completion[p] = '0;
  end
  for (genvar s = 0; s < DispatchWidth; s++) assign disp_fpq.rs_idx[s] = disp_fpq.free_idx[s];
  rapt_feu #(.FPQ_SIZE(8)) dut (.*);
  `include "tb_core_bcast_defaults.svh"
  bit expected_valid[Owners], expected_trap[Owners], expected_fp[Owners];
  logic [63:0] expected_value[Owners];
  logic [4:0] expected_flags[Owners];
  dispatch_slot_t expected_packet[Owners];
  int expected_generation[Owners], issued_at[Owners], finished_at[Owners];
  int cycle = 0, outstanding = 0, finished = 0, max_active = 0, active = 0;
  int consecutive = 0, max_consecutive = 0, last_issue = -2;
  completion_t stalled_packet;
  bit was_stalled = 0;
  always @(posedge clock) begin
    cycle = cycle + 1;
    if (was_stalled && !reset && !cmu_bcast.flush_pipe && !cancel_valid
        && wb_fpu !== stalled_packet)
      $fatal(1, "stalled completion payload changed");
    was_stalled = !reset && !cmu_bcast.flush_pipe && !cancel_valid
        && wb_fpu.valid && !completion_ready;
    stalled_packet = wb_fpu;
    if (!reset && !cmu_bcast.flush_pipe) begin
      if (dut.iss.valid) begin
        if (issued_at[dut.iss.dest] >= 0) $fatal(1, "owner issued twice %0d", dut.iss.dest);
        issued_at[dut.iss.dest] = cycle;
        if (random_stalls && (dut.iss.op1 != (rapt_pkg::fp_from_integer(
                expected_packet[dut.iss.dest].uop.execute.fp.op, 0
            ) ? 64'(expected_packet[dut.iss.dest].op1) : expected_packet[dut.iss.dest].fp_value[0])
                || dut.iss.op2 != expected_packet[dut.iss.dest].fp_value[1] ||
                dut.iss.op3 != expected_packet[dut.iss.dest].fp_value[2]))
          $fatal(1, "random stream operands changed in IQ owner=%0d", dut.iss.dest);
        active++;
        if (active > max_active) max_active = active;
        consecutive = cycle == last_issue + 1 ? consecutive + 1 : 1;
        if (consecutive > max_consecutive) max_consecutive = consecutive;
        last_issue = cycle;
      end
      if (wb_accept) begin
        if (!expected_valid[wb_fpu.dest]) $fatal(1, "unexpected completion owner=%0d", wb_fpu.dest);
        if (wb_fpu.generation != expected_generation[wb_fpu.dest]
            || wb_fpu.trap != expected_trap[wb_fpu.dest]
            || wb_fpu.fp_wen != expected_fp[wb_fpu.dest])
          $fatal(1, "completion metadata mismatch owner=%0d", wb_fpu.dest);
        if (!wb_fpu.trap && (wb_fpu.fp_wen ? wb_fpu.fp_result != expected_value[wb_fpu.dest]
            : wb_fpu.result != XLEN'(expected_value[wb_fpu.dest])))
          $fatal(
              1,
              "owner=%0d op=%0d a=%h b=%h c=%h value=%h integer=%h expected=%h",
              wb_fpu.dest,
              expected_packet[wb_fpu.dest].uop.execute.fp.op,
              expected_packet[wb_fpu.dest].fp_value[0],
              expected_packet[wb_fpu.dest].fp_value[1],
              expected_packet[wb_fpu.dest].fp_value[2],
              wb_fpu.fp_result,
              wb_fpu.result,
              expected_value[wb_fpu.dest]
          );
        if (!wb_fpu.trap && wb_fpu.fp_flags != expected_flags[wb_fpu.dest])
          $fatal(
              1,
              "owner=%0d flags=%h expected=%h",
              wb_fpu.dest,
              wb_fpu.fp_flags,
              expected_flags[wb_fpu.dest]
          );
        if (wb_fpu.trap && wb_fpu.cause != `RAPT_CAUSE_ILLEGAL_INST)
          $fatal(1, "illegal rounding mode lost exception cause");
        expected_valid[wb_fpu.dest] = 0;
        finished_at[wb_fpu.dest] = cycle;
        outstanding--;
        active--;
        finished++;
      end
    end
  end
  task automatic tick(input int count = 1);
    repeat (count) begin
      @(posedge clock);
      #1;
      @(negedge clock);
    end
  endtask
  task automatic clear_scoreboard;
    outstanding = 0;
    active = 0;
    last_issue = -2;
    max_consecutive = 0;
    for (int e = 0; e < Owners; e++) begin
      expected_valid[e] = 0;
      issued_at[e] = -1;
      finished_at[e] = -1;
    end
  endtask
  function automatic dispatch_slot_t operation(input int owner, op, input logic [63:0] a, b = 0,
                                               c = 0, input int generation = 1);
    dispatch_slot_t packet;
    packet = '0;
    packet.dest = ROBIndexBits'(owner);
    packet.generation = $bits(packet.generation)'(generation);
    packet.uop.pc = XLEN'('h80000000 + 4 * owner);
    packet.uop.execute.fp.valid = 1;
    packet.uop.execute.fp.op = $bits(packet.uop.execute.fp.op)'(op);
    packet.uop.execute.fp.rd = 5'(owner);
    packet.uop.execute.fp.rm = 0;
    packet.fp_value = {c, b, a};
    packet.op1 = XLEN'(a);
    packet.uop.rd = rapt_pkg::fp_writes_register(1, packet.uop.execute.fp.op, 0) ? 0 : 7;
    packet.prd = packet.uop.rd == 0 ? 0 : 41;
    return packet;
  endfunction
  task automatic enqueue(input dispatch_slot_t packet, input logic [63:0] expected,
                         input logic [4:0] flags = 0, input bit trap = 0);
    int timeout;
    timeout = 0;
    while (!disp_fpq.free_found[0]) begin
      tick();
      if (timeout++ > 400) $fatal(1, "enqueue timeout");
    end
    if (expected_valid[packet.dest]) $fatal(1, "test reused live owner");
    expected_valid[packet.dest] = 1;
    expected_packet[packet.dest] = packet;
    expected_value[packet.dest] = expected;
    expected_flags[packet.dest] = flags;
    expected_trap[packet.dest] = trap;
    expected_fp[packet.dest] = !trap && rapt_pkg::fp_writes_register(1,
        packet.uop.execute.fp.op, packet.uop.inst);
    expected_generation[packet.dest] = int'(packet.generation);
    issued_at[packet.dest] = -1;
    finished_at[packet.dest] = -1;
    outstanding++;
    dispatch[0] = packet;
    disp_fpq.accept[0] = 1;
    tick();
    disp_fpq.accept[0] = 0;
    dispatch[0] = '0;
  endtask
  task automatic drain;
    int timeout;
    timeout = 0;
    while (outstanding != 0) begin
      tick();
      if (timeout++ > 600) $fatal(1, "completion timeout outstanding=%0d", outstanding);
    end
    tick(3);
  endtask
  logic random_stalls = 0;
  logic [31:0] random_state = 32'hb16b00b5;
  function automatic int random_number;
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return int'(random_state & 32'h7fffffff);
  endfunction
  function automatic logic [63:0] single_integer(input int number);
    logic [31:0] bits;
    int magnitude, leading;
    bits = number < 0 ? 32'h80000000 : 0;
    magnitude = number < 0 ? -number : number;
    leading = 0;
    for (int bit_index = 0; bit_index < 24; bit_index++)
    if ((magnitude >> bit_index) != 0) leading = bit_index;
    if (magnitude != 0)
      bits |= (32'(127 + leading) << 23) | (32'(magnitude - (1 << leading)) << (23 - leading));
    return {32'hffffffff, bits};
  endfunction
  task automatic random_stream;
    for (int sample = 0; sample < 1200; sample ++) begin
      dispatch_slot_t packet;
      logic [63:0] a, b, c, expected;
      int x, y, z, answer, op, kind, owner;
      bit single_format;
      owner = sample % Owners;
      while (expected_valid[owner]) tick();
      x = random_number() % 31 + 1;
      y = random_number() % 31 + 1;
      z = random_number() % 31 + 1;
      kind = random_number() % 12;
      single_format = (random_number() % 2) != 0;
      case (kind)
        0: begin
          op = single_format ? `RAPT_FP_OP_FADD_S : `RAPT_FP_OP_FADD_D;
          answer = x+y;
        end
        1: begin
          op = single_format ? `RAPT_FP_OP_FSUB_S : `RAPT_FP_OP_FSUB_D;
          answer = x-y;
        end
        2: begin
          op = single_format ? `RAPT_FP_OP_FMUL_S : `RAPT_FP_OP_FMUL_D;
          answer = x*y;
        end
        3: begin
          op = single_format ? `RAPT_FP_OP_FMADD_S : `RAPT_FP_OP_FMADD_D;
          answer = x*y+z;
        end
        4: begin
          op = single_format ? `RAPT_FP_OP_FMSUB_S : `RAPT_FP_OP_FMSUB_D;
          answer = x*y-z;
        end
        5: begin
          op = single_format ? `RAPT_FP_OP_FMIN_S : `RAPT_FP_OP_FMIN_D;
          answer = x<y ? x : y;
        end
        6: begin
          op = single_format ? `RAPT_FP_OP_FMAX_S : `RAPT_FP_OP_FMAX_D;
          answer = x>y ? x : y;
        end
        7: begin
          op = single_format ? `RAPT_FP_OP_FCVT_S_W : `RAPT_FP_OP_FCVT_D_W;
          answer = x;
        end
        8: begin
          op = single_format ? `RAPT_FP_OP_FCVT_W_S : `RAPT_FP_OP_FCVT_W_D;
          answer = x;
        end
        9: begin
          op = single_format ? `RAPT_FP_OP_FCVT_S_D : `RAPT_FP_OP_FCVT_D_S;
          answer = x;
        end
        10: begin
          op = single_format ? `RAPT_FP_OP_FDIV_S : `RAPT_FP_OP_FDIV_D;
          answer = x;
          x=x*y;
        end
        default: begin
          op = single_format ? `RAPT_FP_OP_FSQRT_S : `RAPT_FP_OP_FSQRT_D;
          answer = x;
          x=x*x;
        end
      endcase
      a = single_format ? single_integer(x) : $realtobits(real'(x));
      b = single_format ? single_integer(y) : $realtobits(real'(y));
      c = single_format ? single_integer(z) : $realtobits(real'(z));
      expected = single_format ? single_integer(answer) : $realtobits(real'(answer));
      if (kind == 7) a = 64'(x);
      if (kind == 8) expected = 64'(answer);
      if (kind == 9) a = single_format ? $realtobits(real'(x)) : single_integer(x);
      packet = operation(owner, op, a, b, c, 4 + sample / Owners);
      // Exact operations still change rm every cycle, stressing ownership of
      // pipeline controls and values as different units finish together.
      packet.uop.execute.fp.rm = 3'(random_number() % 5);
      if ((kind == 1 && x == y) || (kind == 4 && x * y == z)) packet.uop.execute.fp.rm = 0;
      enqueue(packet, expected);
    end
    drain();
  endtask
  always @(negedge clock) if (random_stalls) completion_ready = (random_number() % 4) != 0;
  initial begin
    dispatch = '{default:'0};
    disp_fpq.accept = '{default:0};
    external_wake = '0;
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, 0, 0);
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    clear_scoreboard();
    tick(3);
    reset = 0;
    enqueue(operation(0, `RAPT_FP_OP_FDIV_D, 64'h401c000000000000, 64'h4008000000000000),
            64'h4002aaaaaaaaaaab, 1);
    enqueue(operation(1, `RAPT_FP_OP_FDIV_D, 64'h4018000000000000, 64'h4008000000000000),
            64'h4000000000000000);
    enqueue(operation(2, `RAPT_FP_OP_FADD_D, 64'h3ff0000000000000, 64'h4000000000000000),
            64'h4008000000000000);
    drain();
    if (!(finished_at[2] < finished_at[0] && issued_at[2] < issued_at[1]))
      $fatal(1, "busy DIV blocked younger ready ADD");
    if (max_active < 2) $fatal(1, "FP execution never overlapped");

    clear_scoreboard();
    for (int n = 0; n < 12; n++)
    enqueue(operation(n, `RAPT_FP_OP_FADD_S, 64'hffffffff3f800000, 64'hffffffff40000000),
            64'hffffffff40400000);
    drain();
    if (max_consecutive < 8)
      $fatal(1, "fixed pipeline did not sustain a launch per cycle: %0d", max_consecutive);

    clear_scoreboard();
    completion_ready = 0;
    enqueue(operation(0, `RAPT_FP_OP_FMUL_D, 64'h4000000000000000, 64'h4008000000000000),
            64'h4018000000000000);
    enqueue(operation(
            1, `RAPT_FP_OP_FMADD_D, 64'h4000000000000000, 64'h4008000000000000, 64'h3ff0000000000000
            ), 64'h401c000000000000);
    enqueue(operation(2, `RAPT_FP_OP_FMUL_S, 64'hffffffff40000000, 64'hffffffff40400000),
            64'hffffffff40c00000);
    enqueue(operation(
            3, `RAPT_FP_OP_FMADD_S, 64'hffffffff40000000, 64'hffffffff40400000, 64'hffffffff3f800000
            ), 64'hffffffff40e00000);
    enqueue(operation(4, `RAPT_FP_OP_FCVT_D_S, 64'hffffffff3fc00000), 64'h3ff8000000000000);
    enqueue(operation(5, `RAPT_FP_OP_FCVT_S_D, 64'h3ff8000000000000), 64'hffffffff3fc00000);
    enqueue(operation(6, `RAPT_FP_OP_FCVT_D_W, 64'hfffffff9), 64'hc01c000000000000);
    enqueue(operation(7, `RAPT_FP_OP_FCVT_S_WU, 7), 64'hffffffff40e00000);
    enqueue(operation(8, `RAPT_FP_OP_FCVT_W_D, 64'h401c000000000000), 7);
    enqueue(operation(9, `RAPT_FP_OP_FCVT_W_S, 64'hffffffff40e00000), 7);
    enqueue(operation(10, `RAPT_FP_OP_FSQRT_D, 64'h4022000000000000), 64'h4008000000000000);
    enqueue(operation(11, `RAPT_FP_OP_FEQ_D, 64'h7ff0000000000001, 64'h3ff0000000000000), 0, 16);
    enqueue(operation(12, `RAPT_FP_OP_FCLASS_S, 64'hffffffff7f800000), 128);
    enqueue(operation(13, `RAPT_FP_OP_FMV_W_X, 64'h12345678), 64'hffffffff12345678);
    enqueue(operation(14, `RAPT_FP_OP_FMV_X_W, 64'hffffffff87654321), 64'hffffffff87654321);
    tick(100);
    if (outstanding != 15) $fatal(1, "completion escaped backpressure");
    completion_ready = 1;
    drain();

    clear_scoreboard();
    enqueue(operation(0, `RAPT_FP_OP_FCVT_S_W, 64'hfffffff9), 64'hffffffffc0e00000);
    enqueue(operation(1, `RAPT_FP_OP_FCVT_D_WU, 7), 64'h401c000000000000);
    if (XLEN == 64) begin
      enqueue(operation(2, `RAPT_FP_OP_FCVT_D_L, 64'hfffffffffffffff9), 64'hc01c000000000000);
      enqueue(operation(3, `RAPT_FP_OP_FCVT_S_L, 64'hfffffffffffffff9), 64'hffffffffc0e00000);
      enqueue(operation(4, `RAPT_FP_OP_FMV_D_X, 64'h0123456789abcdef), 64'h0123456789abcdef);
      enqueue(operation(5, `RAPT_FP_OP_FMV_X_D, 64'hfedcba9876543210), 64'hfedcba9876543210);
    end
    begin
      dispatch_slot_t packet;
      packet = operation(6, `RAPT_FP_OP_ZFHMIN, 64'hffffffffffff3c00);
      packet.uop.inst = 32'h40200053;  // FCVT.S.H
      enqueue(packet, 64'hffffffff3f800000);
      packet = operation(7, `RAPT_FP_OP_ZFHMIN, 64'h3ff0000000000000);
      packet.uop.inst = 32'h44100053;  // FCVT.H.D
      enqueue(packet, 64'hffffffffffff3c00);
      packet = operation(8, `RAPT_FP_OP_FCVT_W_D, 64'h3ff8000000000000);
      packet.uop.execute.fp.rm = 7;
      csr_bcast.frm = 1;
      enqueue(packet, 1, 1);
      drain();
      csr_bcast.frm = 0;
    end

    // A dependent FMA waits for its third FP producer; a GPR dependency with
    // the same numeric tag belongs to a separate namespace.
    clear_scoreboard();
    begin
      dispatch_slot_t packet;
      packet = operation(0, `RAPT_FP_OP_FMADD_D, 64'h4000000000000000, 64'h4008000000000000);
      packet.fp_tag[2] = 8;
      enqueue(packet, 64'h401c000000000000);
      packet = operation(1, `RAPT_FP_OP_FCVT_D_W, 0);
      packet.pr1 = 8;
      enqueue(packet, 64'h4020000000000000);
      tick(3);
      if (issued_at[0] >= 0 || issued_at[1] >= 0) $fatal(1, "unready dependency issued");
      external_wake = '0;
      external_wake.valid = 1;
      external_wake.dest = 7;
      external_wake.fp_wen = 1;
      external_wake.fp_result = 64'h3ff0000000000000;
      tick();
      external_wake = '0;
      tick(3);
      if (issued_at[0] < 0 || issued_at[1] >= 0) $fatal(1, "FP/GPR namespace or third wake failed");
      external_wake.valid = 1;
      external_wake.prd = 8;
      external_wake.rd = 3;
      external_wake.result = 8;
      tick();
      external_wake = '0;
      drain();
      packet = operation(2, `RAPT_FP_OP_FADD_D, 0, 64'h4000000000000000);
      packet.fp_tag[0] = 8;
      external_wake.valid = 1;
      external_wake.dest = 7;
      external_wake.fp_wen = 1;
      external_wake.fp_result = 64'h3ff0000000000000;
      enqueue(packet, 64'h4008000000000000);
      external_wake = '0;
      drain();
      packet = operation(3, `RAPT_FP_OP_FADD_D, 0, 0);
      packet.uop.execute.fp.rm = 5;
      enqueue(packet, 0, 0, 1);
      drain();
    end

    // Cancel completed and still-running younger owners without canceling an
    // older iterative operation. Flush then reuses the same ROB identities.
    clear_scoreboard();
    completion_ready = 0;
    enqueue(operation(0, `RAPT_FP_OP_FDIV_D, 64'h401c000000000000, 64'h4008000000000000),
            64'h4002aaaaaaaaaaab, 1);
    enqueue(operation(
            1, `RAPT_FP_OP_FMADD_D, 64'h4000000000000000, 64'h4008000000000000, 64'h3ff0000000000000
            ), 64'h401c000000000000);
    enqueue(operation(2, `RAPT_FP_OP_FADD_D, 64'h3ff0000000000000, 64'h4000000000000000),
            64'h4008000000000000);
    tick(3);
    cancel_valid = 1;
    cancel_owner = 0;
    tick();
    cancel_valid = 0;
    expected_valid[1] = 0;
    expected_valid[2] = 0;
    outstanding = 1;
    completion_ready = 1;
    drain();
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    clear_scoreboard();
    enqueue(operation(0, `RAPT_FP_OP_FMUL_D, 64'h4000000000000000, 64'h4008000000000000, 0, 2),
            64'h4018000000000000);
    tick(2);
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    clear_scoreboard();
    enqueue(operation(0, `RAPT_FP_OP_FADD_D, 64'h3ff0000000000000, 64'h4000000000000000, 0, 3),
            64'h4008000000000000);
    drain();
    tick(20);
    clear_scoreboard();
    random_stalls = 1;
    random_stream();
    random_stalls = 0;
    completion_ready = 1;
    $display(
        "PASS: FEU out-of-order, II=1, all result units, FMA/GPR dependencies, stalls, cancel/flush/reuse XLEN=%0d completions=%0d",
        XLEN, finished);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "FEU test timeout");
  end
endmodule
