`include "rapt.svh"
module tb_pmp_reset_napot;
  localparam int XLEN = `RAPT_XLEN;
  localparam int N = `RAPT_PMP_NUM;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  pmp_update_if update ();
  pmp_state_if state ();
  rapt_pmp_state state_dut (
      .clock(clock),
      .reset(reset),
      .update(update),
      .state(state)
  );
  logic [XLEN-1:0] addr;
  logic [3:0] size_m1;
  logic [1:0] priv;
  logic op_r, op_w, fault, fault_lo;
  rapt_pmp #(
      .XLEN(XLEN)
  ) check_dut (
      .addr(addr),
      .size_m1(size_m1),
      .priv(priv),
      .op_r(op_r),
      .op_w(op_w),
      .op_x(1'b0),
      .pmp_raw_addr(state.pmp_raw_addr),
      .pmp_napot_mask(state.pmp_napot_mask),
      .pmp_cfg_r(state.pmp_cfg_r),
      .pmp_cfg_w(state.pmp_cfg_w),
      .pmp_cfg_x(state.pmp_cfg_x),
      .pmp_cfg_l(state.pmp_cfg_l),
      .pmp_mode_off(state.pmp_mode_off),
      .pmp_mode_tor(state.pmp_mode_tor),
      .pmp_mode_na4(state.pmp_mode_na4),
      .pmp_mode_napot(state.pmp_mode_napot),
      .fault(fault),
      .fault_lo_o(fault_lo)
  );
  int checks = 0;
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic run_case(input int entry, mode, locked, writable);
    int limit, high_byte;
    bit expected_lo, expected_hi, expected_fault;
    @(negedge clock);
    reset = 1;
    update.cfg_we = '0;
    tick();
    @(negedge clock);
    reset = 0;
    // Only a configuration update: pmpaddr remains its reset value of zero.
    update.cfg_we = '0;
    update.cfg_we[entry] = 1;
    update.cfg_r = '1;
    update.cfg_w = (writable != 0) ? '1 : '0;
    update.cfg_l = (locked != 0) ? '1 : '0;
    update.mode_off = mode == 2 ? '1 : '0;
    update.mode_na4 = mode == 1 ? '1 : '0;
    update.mode_napot = mode == 0 ? '1 : '0;
    tick();
    @(negedge clock);
    update.cfg_we = '0;
    limit = mode == 0 ? 7 : (mode == 1 ? 3 : -1);
    for (int p = 0; p < 3; p++) begin
      priv = p == 2 ? 2'd3 : 2'(p);
      for (int w = 0; w < 2; w++) begin
        op_w = 1'(w);
        op_r = !op_w;
        for (int bytes_log2 = 0; bytes_log2 < 4; bytes_log2++) begin
          size_m1 = 4'((1 << bytes_log2) - 1);
          for (int a = 0; a < 10; a++) begin
            addr = XLEN'(a);
            high_byte = a + int'(size_m1);
            expected_lo = a <= limit ? ((p != 2 || locked != 0) && w != 0 && writable == 0) : p != 2;
            expected_hi = high_byte <= limit ? ((p != 2 || locked != 0) && w != 0 && writable == 0) : p != 2;
            expected_fault = expected_lo || expected_hi || (a <= limit && high_byte > limit);
            #1;
            if (fault !== expected_fault || fault_lo !== expected_lo)
              $fatal(
                  1,
                  "reset PMP entry=%0d mode=%0d L=%0d W=%0d priv=%0d write=%0d addr=%0d size=%0d fault=%0b expected=%0b lo=%0b expected_lo=%0b",
                  entry,
                  mode,
                  locked,
                  writable,
                  priv,
                  w,
                  a,
                  int'(size_m1) + 1,
                  fault,
                  expected_fault,
                  fault_lo,
                  expected_lo
              );
            checks++;
          end
        end
      end
    end
    for (int i = 0; i < N; i++) begin
      assert (state.pmp_raw_addr[i] == '0)
      else $fatal(1, "address changed without write");
      assert (state.pmp_napot_mask[i] == 1)
      else $fatal(1, "reset NAPOT derived mask");
    end
  endtask
  initial begin
    update.addr_we = 0;
    update.addr_idx = '0;
    update.raw_addr = '0;
    update.napot_mask = '0;
    update.cfg_we = '0;
    update.cfg_r = '0;
    update.cfg_w = '0;
    update.cfg_x = '0;
    update.cfg_l = '0;
    update.mode_off = '1;
    update.mode_tor = '0;
    update.mode_na4 = '0;
    update.mode_napot = '0;
    addr = '0;
    size_m1 = 0;
    priv = 0;
    op_r = 1;
    op_w = 0;
    for (int i = 0; i < N; i++)
    for (int mode = 0; mode < 3; mode++)
    for (int locked = 0; locked < 2; locked++)
    for (int writable = 0; writable < 2; writable++) run_case(i, mode, locked, writable);
    assert (checks == N * 3 * 2 * 2 * 3 * 2 * 4 * 10)
    else $fatal(1, "coverage count");
    $display("PASS: PMP reset NAPOT XLEN=%0d checks=%0d", XLEN, checks);
    $finish;
  end
endmodule
