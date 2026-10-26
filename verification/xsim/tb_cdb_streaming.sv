`include "rapt.svh"
`include "rapt_if.svh"

module tb_cdb_streaming;
  typedef rapt_pkg::completion_t PacketT;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  PacketT integer_raw, fp_raw, shared_result, executing, packet;
  PacketT integer_expected[$], fp_expected[$];
  logic integer_accept, fp_accept, integer_enable, fp_ready;
  logic pipe_enable = 1, fp_issue_enable = 1;
  logic [31:0] random_state = 32'h4e231799;
  int serial = 1, emitted = 0, consecutive = 0, collisions = 0, fp_age = 0;
  bit previous_integer = 0, bypass = 0;
  rapt_cdb_arb dut (
      .clock,
      .reset,
      .flush,
      .integer_system_pipe_enable(pipe_enable),
      .fpu_issue_enable(fp_issue_enable),
      .wb_integer_system_raw(integer_raw),
      .wb_fpu(fp_raw),
      .wb_integer_system_accept(integer_accept),
      .wb_fpu_accept(fp_accept),
      .wb_shared(shared_result),
      .integer_system_issue_enable(integer_enable),
      .fpu_completion_ready(fp_ready)
  );
  task automatic random_next;
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
  endtask
  task automatic make_packet(output PacketT p);
    p = '0;
    p.valid = 1;
    p.result = `RAPT_XLEN'(serial);
    p.dest = $bits(p.dest)'(serial);
    p.generation = $bits(p.generation)'(serial >> 3);
    p.prd = $bits(p.prd)'(serial + 7);
    p.rd = $bits(p.rd)'(serial + 9);
    p.fp_flags_valid = (serial % 2) != 0;
    p.fp_flags = 5'(serial);
    serial++;
  endtask
  initial begin
    integer_raw = '0;
    fp_raw = '0;
    executing = '0;
    integer_accept = 0;
    fp_accept = 0;
    for (int cycle = 0; cycle < 10010; cycle++) begin
      @(negedge clock);
      random_next();
      reset = cycle < 2 || (cycle < 10000 && cycle % 1009 == 0);
      flush = cycle < 10000 && cycle % 137 == 0;
      pipe_enable = random_state[0] || random_state[1];
      fp_issue_enable = random_state[2] || random_state[3];
      integer_raw = executing;
      integer_accept = random_state[4] || random_state[5];
      fp_accept = random_state[6] || random_state[7];
      fp_raw = '0;
      #1;
      if (!reset && !flush && cycle < 10000 && fp_ready && random_state[15:13] == 0)
        make_packet(fp_raw);
      #1;
      if (reset || flush) begin
        integer_expected.delete();
        fp_expected.delete();
        executing = '0;
        fp_age = 0;
        previous_integer = 0;
        assert (!shared_result.valid && !integer_enable && !fp_ready)
        else $fatal(1, "reset/flush leaked a transfer");
      end else begin
        bypass = integer_raw.valid && integer_accept && fp_expected.size() == 0;
        assert (shared_result.valid == (bypass || integer_expected.size() + fp_expected.size() > 0))
        else $fatal(1, "lost or duplicated result at cycle %0d", cycle);
        if (shared_result.valid) begin
          if (bypass) begin
            packet = integer_raw;
            if (previous_integer) consecutive++;
            previous_integer = 1;
          end else if (integer_expected.size() != 0) begin
            packet = integer_expected.pop_front();
            if (previous_integer) consecutive++;
            previous_integer = 1;
          end else begin
            packet = fp_expected.pop_front();
            previous_integer = 0;
          end
          assert (shared_result === packet)
          else $fatal(1, "completion payload/identity corruption at cycle %0d", cycle);
          emitted++;
        end else previous_integer = 0;
        if (fp_expected.size() != 0) fp_age++;
        else fp_age = 0;
        assert (fp_age <= 2)
        else $fatal(1, "FP starvation");
        if (integer_raw.valid && integer_accept && !bypass) integer_expected.push_back(integer_raw);
        if (fp_raw.valid && fp_accept) fp_expected.push_back(fp_raw);
        if (bypass && fp_raw.valid && fp_accept) collisions++;
        if (integer_expected.size() != 0 && fp_expected.size() != 0) collisions++;
        assert (integer_expected.size() <= 1 && fp_expected.size() <= 1)
        else $fatal(1, "completion buffer overflow");
        executing = '0;
        if (integer_enable && cycle < 10000 && random_state[9:8] != 0) make_packet(executing);
      end
      @(posedge clock);
      #1;
    end
    assert (integer_expected.size() == 0 && fp_expected.size() == 0);
    assert (consecutive > 500 && collisions > 50 && emitted > 1000)
    else
      $fatal(
          1,
          "insufficient coverage: consecutive=%0d collisions=%0d emitted=%0d",
          consecutive,
          collisions,
          emitted
      );
    $display("PASS: CDB streaming XLEN=%0d emitted=%0d consecutive=%0d collisions=%0d", `RAPT_XLEN,
             emitted, consecutive, collisions);
    $finish;
  end
endmodule
