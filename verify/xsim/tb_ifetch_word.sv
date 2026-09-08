`include "rapt.svh"
module tb_ifetch_word;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1, kill = 0;
  always #5 clock = ~clock;
  logic request_valid, request_ready, io_authorized, io_start;
  logic busy;
  logic [XLEN-1:0] request_pc, owner_pc;
  logic translate_valid, translate_ready, translation_valid, translation_fault;
  logic [XLEN-1:0] translate_vaddr, translation_paddr, translation_cause;
  logic [1:0] translation_pbmt, read_pbmt;
  logic read_valid, read_ready, response_valid, response_error;
  logic [XLEN-1:0] read_paddr;
  logic [31:0] response_word, result_inst;
  logic result_valid, result_ready, result_fault;
  logic [XLEN-1:0] result_cause, result_tval;
  int io_starts;
  always @(posedge clock) begin
    if (reset || (request_valid && request_ready)) io_starts <= 0;
    else if (io_start) io_starts <= io_starts + 1;
  end
  rapt_ifetch_word dut (.*);
  `include "tb_common.svh"
  task automatic start(input logic [XLEN-1:0] pc);
    check(request_ready, "controller did not drain previous owner");
    request_pc=pc;
    request_valid=1;
    tick(1);
    request_valid = 0;
  endtask
  task automatic translate(input logic [XLEN-1:0] va, input int attr, input bit fault);
    check(translate_valid && translate_vaddr == va, "wrong independently translated word");
    translate_ready = 1;
    tick(1);
    translate_ready = 0;
    tick(3);
    translation_paddr=va[12] ? 'h82000000 : 'h81000ffc;
    translation_pbmt=2'(attr);
    translation_fault=fault;
    translation_cause=12;
    translation_valid=1;
    tick(1);
    translation_valid=0;
    translation_fault=0;
  endtask
  task automatic data(input int attr, input logic [31:0] value);
    if (attr == 2 && !io_authorized && io_starts == 0) begin
      repeat (4) begin
        check(!read_valid, "speculative IO request escaped");
        tick(1);
      end
      io_authorized = 1;
    end
    #1;
    check(read_valid && read_pbmt == 2'(attr), "read type lost");
    repeat (3) begin
      tick(1);
      check(read_valid, "held read disappeared");
    end
    read_ready = 1;
    tick(1);
    read_ready=0;
    io_authorized=0;
    tick(3);
    response_word=value;
    response_valid=1;
    tick(1);
    response_valid = 0;
  endtask
  initial begin
    request_valid=0;
    request_pc=0;
    io_authorized=0;
    translate_ready=0;
    translation_valid=0;
    translation_fault=0;
    translation_paddr=0;
    translation_pbmt=0;
    translation_cause=0;
    read_ready=0;
    response_valid=0;
    response_error=0;
    response_word=0;
    result_ready=0;
    tick(3);
    reset = 0;
    tick(1);
    for (int a = 0; a < 3; a++)
    for (int b = 0; b < 3; b++) begin
      start('h40000ffe);
      translate('h40000ffc, a, 0);
      data(a, 32'h00930001);
      check(!result_valid, "straddling instruction completed after one word");
      translate('h40001000, b, 0);
      data(b, 32'h00010010);
      check(result_valid && !result_fault && result_inst == 32'h00100093,
            "cross-page instruction assembled wrong");
      check(io_starts == int'(a == 2 || b == 2),
            "IO authorization consumed more than once per instruction");
      repeat (3) begin
        tick(1);
        check(result_valid && result_inst == 32'h00100093, "result not held");
      end
      result_ready = 1;
      tick(1);
      result_ready = 0;
    end
    start('h40000ffe);
    translate('h40000ffc, 2, 0);
    data(2, 32'h00010001);
    check(result_valid && !translate_valid && result_inst == 1,
          "compressed instruction read next page");
    result_ready = 1;
    tick(1);
    result_ready = 0;
    start('h40000ffe);
    translate('h40000ffc, 1, 0);
    data(1, 32'h00930001);
    translate('h40001000, 0, 1);
    check(result_valid && result_fault && result_cause == 12 && result_tval == 'h40001000,
          "second page fault lost VA");
    result_ready = 1;
    tick(1);
    result_ready = 0;
    // Cancellation after an accepted external read must retain ownership until
    // that response arrives; a new owner cannot consume the old response.
    start('h40000ffe);
    translate('h40000ffc, 1, 0);
    read_ready = 1;
    tick(1);
    read_ready=0;
    kill=1;
    tick(1);
    kill = 0;
    repeat (4) begin
      check(!request_ready && !result_valid, "cancelled read did not drain");
      tick(1);
    end
    response_valid=1;
    response_word='1;
    tick(1);
    response_valid = 0;
    check(request_ready && !result_valid, "cancelled response leaked");
    // Cancel an IO request waiting for authorization, before any side effect.
    start('h40000ffe);
    translate('h40000ffc, 2, 0);
    check(!read_valid, "unauthorized IO became valid");
    kill = 1;
    tick(1);
    kill = 0;
    #1;
    check(request_ready && !result_valid, "unissued IO cancel failed");
    // An accepted translation has the same drain obligation as accepted data.
    start('h40000ffe);
    translate_ready = 1;
    tick(1);
    translate_ready=0;
    kill=1;
    tick(1);
    kill = 0;
    #1;
    repeat (4) begin
      check(!request_ready && !read_valid && !result_valid, "cancelled translation lost ownership");
      tick(1);
    end
    translation_valid=1;
    translation_fault=1;
    tick(1);
    translation_valid=0;
    translation_fault=0;
    check(request_ready && !result_valid && !read_valid, "cancelled translation fault escaped");
    // First-piece faults report the original halfword PC, not aligned word VA.
    start('h40000ffe);
    translate('h40000ffc, 0, 1);
    check(result_valid && result_fault && result_cause == 12 && result_tval == 'h40000ffe,
          "first translation fault lost original PC");
    result_ready = 1;
    tick(1);
    result_ready = 0;
    start('h40000ffe);
    translate('h40000ffc, 3, 0);
    check(result_valid && result_fault && result_cause == 12 && !read_valid,
          "reserved PBMT escaped as memory request");
    result_ready = 1;
    tick(1);
    result_ready = 0;
    for (int piece = 0; piece < 2; piece++) begin
      start('h40000ffe);
      translate('h40000ffc, 1, 0);
      if (piece == 1) begin
        data(1, 32'h00930001);
        translate('h40001000, 1, 0);
      end
      response_error = 1;
      data(1, 32'hffffffff);
      response_error = 0;
      check(
          result_valid && result_fault && result_cause==1
          && result_tval==(piece==0 ? XLEN'('h40000ffe) : XLEN'('h40001000)),
          "data access fault lost piece VA");
      result_ready = 1;
      tick(1);
      result_ready = 0;
    end
    // Kill wins over a simultaneous response; it must not launch piece two.
    start('h40000ffe);
    translate('h40000ffc, 1, 0);
    read_ready = 1;
    tick(1);
    read_ready=0;
    response_valid=1;
    response_word=32'h00930001;
    kill=1;
    tick(1);
    response_valid=0;
    kill=0;
    #1;
    check(request_ready && !result_valid && !translate_valid,
          "kill/response race launched another piece");
    $display(
        "PASS: per-word translation, mixed PBMT, IO authorization, straddle, fault VA and kill/drain");
    $finish;
  end
endmodule
