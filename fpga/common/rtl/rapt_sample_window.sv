// JTAG-controlled architectural replay and bounded retirement observation.
// Register addresses are byte offsets; accesses are aligned 64-bit words.
module rapt_sample_window #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int Width = rapt_pkg::CommitWidth,
    parameter int Band = 64,
    parameter int Rows = 2 * (Band + 1) + 1
) (
    input logic clk,
    reset,
    input logic cfg_wr,
    input logic [15:0] cfg_waddr,
    cfg_raddr,
    input logic [63:0] cfg_wdata,
    output logic [63:0] cfg_rdata,
    input logic bus_idle,
    input logic writeback_error,
    input logic device_activity = 1'b0,
    output logic cpu_reset,
    rapt_sample_if sample
);
  typedef enum logic [2:0] {
    Held,
    Restore,
    AwaitPc,
    Count,
    Drain,
    Done
  } state_t;
  state_t state;
  logic failed, restored, reset_requested;
  logic [31:0] error_code;
  logic [63:0] warmup, length, target_pc, restore_pc;
  logic [63:0] saved_mepc, saved_cycle, saved_instret, saved_time, saved_cmp, saved_status;
  logic saved_msip;
  logic [63:0] deadline, elapsed, drain_elapsed, retired, signature;
  logic [7:0] row_count;
  logic [2:0] idle_count;
  logic [4:0] gpr_addr;
  (* ram_style = "block" *) logic [255:0] rows[Rows];
  logic [255:0] read_row;
  logic [255:0] row_wdata;
  logic [7:0] row_waddr;
  logic row_we, initialize_row;
  logic [15:0] table_offset;
  logic [63:0] next_retired, next_signature, last_pc;
  logic [63:0] measurement_pc;
  logic user_only, thread_only;
  logic [63:0] user_satp_root, user_thread_pointer;
  logic [$clog2(Width+1)-1:0] eligible_count;
  logic starting, observing, record_row;
  integer first_slot;

  // rotate-xor-pc-v1: a cheap ordered PC digest; this is NOT NEMU's FNV hash.
  function automatic logic [63:0] pc_digest(input logic [63:0] old, pc);
    return {old[56:0], old[63:57]} ^ pc ^ 64'h9e37_79b9_7f4a_7c15;
  endfunction

  assign sample.halt_req = state == Drain || state == Done;
  assign sample.restore_armed = state == Restore;
  assign sample.restore_pc = XLEN'(restore_pc);
  assign sample.saved_mepc = XLEN'(saved_mepc);
  assign sample.saved_status = XLEN'(saved_status);
  assign sample.saved_cycle = saved_cycle;
  assign sample.saved_instret = saved_instret;
  assign sample.saved_time = saved_time;
  assign sample.saved_timecmp = saved_cmp;
  assign sample.saved_msip = saved_msip;
  assign sample.gpr_addr = gpr_addr;
  assign cpu_reset = state == Held;
  assign eligible_count = !user_only || (sample.privilege == 0 &&
      64'(sample.satp_root) == user_satp_root &&
      (!thread_only || 64'(sample.thread_pointer) == user_thread_pointer)) ? sample.count : '0;

  always_comb begin
    first_slot = 0;
    starting = 1'b0;
    for (int c = Width - 1; c >= 0; c--) begin
      if (c < int'(eligible_count) && 64'(sample.pc[c]) == target_pc) begin
        first_slot = c;
        starting = 1'b1;
      end
    end
    observing = state == Count || (state == AwaitPc && starting);
    next_retired = state == AwaitPc ? '0 : retired;
    next_signature = state == AwaitPc ? '0 : signature;
    last_pc = '0;
    for (int c = 0; c < Width; c++) begin
      if (observing && c < int'(eligible_count) && (state == Count || c >= first_slot)) begin
        next_retired = next_retired + 1'b1;
        next_signature = pc_digest(next_signature, 64'(sample.pc[c]));
        last_pc = 64'(sample.pc[c]);
      end
    end
    record_row = observing && eligible_count != 0 &&
        ((next_retired >= warmup && next_retired <= warmup + Band) ||
         (next_retired >= warmup + length && next_retired <= warmup + length + Band));
  end

  // Synchronous observation RAM read, allowing block RAM inference.
  assign table_offset = cfg_raddr - 16'h1000;
  assign initialize_row = state == Restore && sample.mret &&
      64'(sample.pc[0]) == restore_pc && warmup == 0;
  assign row_we = initialize_row || (record_row && int'(row_count) < Rows);
  assign row_waddr = initialize_row ? 8'b0 : row_count;
  assign row_wdata = initialize_row ? {128'b0, elapsed + 1'b1, 64'b0} :
      {next_signature, last_pc, elapsed + 1'b1, next_retired};
  always_ff @(posedge clk) begin
    if (int'(table_offset[12:5]) < Rows) read_row <= rows[table_offset[12:5]];
    if (row_we && !reset) rows[row_waddr] <= row_wdata;
  end
  always_comb begin
    cfg_rdata = '0;
    if (cfg_raddr >= 16'h1000 && cfg_raddr < 16'h1000 + Rows * 32) begin
      // The address within the table, rather than its aperture base, indexes RAM.
      case (cfg_raddr[4:3])
        0: cfg_rdata = read_row[63:0];
        1: cfg_rdata = read_row[127:64];
        2: cfg_rdata = read_row[191:128];
        3: cfg_rdata = read_row[255:192];
      endcase
    end else begin
      case (cfg_raddr)
        16'h0000: cfg_rdata = 64'h5250_5453_0001_0001;
        16'h0008: cfg_rdata = {55'b0, state, sample.quiescent, restored, failed,
                             state == Done, cpu_reset, reset_requested};
        16'h0010: cfg_rdata = warmup;
        16'h0018: cfg_rdata = length;
        16'h0020: cfg_rdata = target_pc;
        16'h0028: cfg_rdata = restore_pc;
        16'h0030: cfg_rdata = saved_mepc;
        16'h0038: cfg_rdata = saved_cycle;
        16'h0040: cfg_rdata = saved_instret;
        16'h0048: cfg_rdata = saved_time;
        16'h0050: cfg_rdata = saved_cmp;
        16'h0058: cfg_rdata = {63'b0, saved_msip};
        16'h0060: cfg_rdata = deadline;
        16'h0068: cfg_rdata = elapsed;
        16'h0070: cfg_rdata = retired;
        16'h0078: cfg_rdata = {56'b0, row_count};
        16'h0080: cfg_rdata = 64'(sample.gpr_data);
        16'h0088: cfg_rdata = signature;
        16'h0090: cfg_rdata = {32'b0, error_code};
        16'h0098: cfg_rdata = saved_status;
        16'h00c0: cfg_rdata = measurement_pc;
        16'h00c8: cfg_rdata = {63'b0, user_only};
        16'h00d0: cfg_rdata = user_satp_root;
        16'h00d8: cfg_rdata = {63'b0, thread_only};
        16'h00e0: cfg_rdata = user_thread_pointer;
        16'h00e8: cfg_rdata = drain_elapsed;
        16'h00f0: cfg_rdata = {60'b0, sample.drain_ready};
        default: cfg_rdata = '0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= Held;
      warmup <= 0;
      length <= 0;
      target_pc <= 0;
      restore_pc <= 0;
      saved_mepc <= 0;
      saved_cycle <= 0;
      saved_instret <= 0;
      saved_time <= 0;
      saved_cmp <= '1;
      saved_msip <= 0;
      saved_status <= 0;
      measurement_pc <= 0;
      user_only <= 0;
      thread_only <= 0;
      user_thread_pointer <= 0;
      user_satp_root <= 0;
      deadline <= 64'd1_000_000_000;
      elapsed <= 0;
      drain_elapsed <= 0;
      retired <= 0;
      signature <= 0;
      row_count <= 0;
      idle_count <= 0;
      failed <= 0;
      error_code <= 0;
      restored <= 0;
      reset_requested <= 0;
      gpr_addr <= 0;
    end else begin
      if (state == Drain) drain_elapsed <= drain_elapsed + 1'b1;
      else drain_elapsed <= 0;
      if (state == Restore || state == AwaitPc || state == Count) begin
        elapsed <= elapsed + 1'b1;
      end
      if (state == Restore && sample.mret) begin
        // Only the programmed trampoline mret is accepted by restore_fire.
        if (64'(sample.pc[0]) != restore_pc) begin
          failed <= 1'b1;
          error_code <= 2;
          state <= Drain;
        end else begin
          restored <= 1'b1;
          state <= AwaitPc;
          if (warmup == 0) begin
            row_count <= 1;
          end
        end
      end
      if (observing) begin
        state <= Count;
        retired <= next_retired;
        signature <= next_signature;
        for (int c = 0; c < Width; c++) begin
          if (c < int'(eligible_count) && (state == Count || c >= first_slot) &&
              next_retired - 64'(eligible_count) + 64'(c) == warmup)
            measurement_pc <= 64'(sample.pc[c]);
        end
        if (record_row) begin
          if (int'(row_count) >= Rows) begin
            failed <= 1'b1;
            error_code <= 3;
            state <= Drain;
          end else begin
            row_count <= row_count + 1'b1;
          end
        end
        if (next_retired >= warmup + length + Band) state <= Drain;
      end
      if (state == AwaitPc && eligible_count != 0 && !starting) begin
        failed <= 1'b1;
        error_code <= 6;
        state <= Drain;
      end
      if (state == Drain || state == Done) begin
        retired <= retired + 64'(eligible_count);
        if (sample.quiescent && bus_idle) begin
          if (idle_count != 7) idle_count <= idle_count + 1'b1;
          if (idle_count >= 3) state <= reset_requested ? Held : Done;
        end else idle_count <= 0;
      end
      if (cfg_wr) begin
        if (cfg_waddr == 16'h0080) gpr_addr <= cfg_wdata[4:0];
        if (cfg_waddr == 16'h0008) begin
          if (cfg_wdata == 1 && state == Held) begin
            failed <= 0;
            error_code <= 0;
            restored <= 0;
            reset_requested <= 0;
            elapsed <= 0;
            retired <= 0;
            signature <= 0;
            measurement_pc <= 0;
            row_count <= 0;
            idle_count <= 0;
            if (length == 0 || length[63] || warmup[63] ||
                warmup + length < warmup || warmup + length + Band < warmup + length) begin
              failed <= 1;
              error_code <= 5;
            end else state <= Restore;
          end else if (cfg_wdata == 2 || cfg_wdata == 3) begin
            reset_requested <= cfg_wdata == 3;
            if (state != Held) state <= Drain;
          end
        end else if (state == Held) begin
          case (cfg_waddr)
            16'h0010: warmup <= cfg_wdata;
            16'h0018: length <= cfg_wdata;
            16'h0020: target_pc <= cfg_wdata;
            16'h0028: restore_pc <= cfg_wdata;
            16'h0030: saved_mepc <= cfg_wdata;
            16'h0038: saved_cycle <= cfg_wdata;
            16'h0040: saved_instret <= cfg_wdata;
            16'h0048: saved_time <= cfg_wdata;
            16'h0050: saved_cmp <= cfg_wdata;
            16'h0058: saved_msip <= cfg_wdata[0];
            16'h0060: deadline <= cfg_wdata;
            16'h0098: saved_status <= cfg_wdata;
            16'h00c8: user_only <= cfg_wdata[0];
            16'h00d0: user_satp_root <= cfg_wdata;
            16'h00d8: thread_only <= cfg_wdata[0];
            16'h00e0: user_thread_pointer <= cfg_wdata;
            default: ;
          endcase
        end
      end
      // Deadline/fatal handling wins a coincident final retirement or mret.
      if ((state == Restore || state == AwaitPc || state == Count) &&
          (elapsed >= deadline || writeback_error)) begin
        failed <= 1'b1;
        error_code <= writeback_error ? 4 : 1;
        state <= Drain;
      end
      if ((state == AwaitPc || state == Count) && device_activity) begin
        failed <= 1'b1;
        error_code <= 7;
        state <= Drain;
      end
      // A drain failure must be observable without releasing halt or forcing
      // reset across outstanding stores. Preserve any earlier failure cause.
      if (state == Drain && !failed && (drain_elapsed >= deadline || writeback_error)) begin
        failed <= 1'b1;
        error_code <= writeback_error ? 4 : 8;
      end
    end
  end
endmodule
