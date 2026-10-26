`include "rapt.svh"

module tb_l2_put_list_buffer;
  localparam int Xlen = `RAPT_XLEN;
  localparam int NumLists = 40;
  localparam int NumBeats = 40;
  localparam int ListBits = $clog2(NumLists);

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic push_valid = 1'b0;
  logic push_ready;
  logic [ListBits-1:0] push_list = '0;
  logic [Xlen-1:0] push_data = '0;
  logic [Xlen/8-1:0] push_mask = '0;
  logic push_last = 1'b0;
  logic pop_valid = 1'b0;
  logic [ListBits-1:0] pop_list = '0;
  logic [Xlen-1:0] pop_data;
  logic [Xlen/8-1:0] pop_mask;
  logic pop_last;
  logic [NumLists-1:0] list_valid;

  rapt_l2_put_buffer #(.Xlen(Xlen)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic push(input int list, input logic [Xlen-1:0] value, input logic [Xlen/8-1:0] mask,
                      input logic last);
    push_list  = ListBits'(list);
    push_data  = value;
    push_mask  = mask;
    push_last  = last;
    push_valid = 1'b1;
    #1;
    check(push_ready, "put beat pool unexpectedly full");
    tick(1);
    push_valid = 1'b0;
  endtask

  task automatic pop(input int list, input logic [Xlen-1:0] value, input logic [Xlen/8-1:0] mask,
                     input logic last);
    pop_list  = ListBits'(list);
    pop_valid = 1'b1;
    #1;
    check(list_valid[list] && pop_data == value && pop_mask == mask && pop_last == last, $sformatf(
          "put list %0d returned wrong beat", list));
    tick(1);
    pop_valid = 1'b0;
  endtask

  initial begin
    tick(3);
    reset = 1'b0;
    check(list_valid == '0 && push_ready, "put buffer did not reset empty");

    push(0, Xlen'('h10), '1, 1'b0);
    push(1, Xlen'('h20), '1, 1'b1);
    push(0, Xlen'('h11), (Xlen / 8)'(3), 1'b0);
    push(0, Xlen'('h12), '1, 1'b1);
    pop(0, Xlen'('h10), '1, 1'b0);
    pop(1, Xlen'('h20), '1, 1'b1);
    pop(0, Xlen'('h11), (Xlen / 8)'(3), 1'b0);
    pop(0, Xlen'('h12), '1, 1'b1);
    check(list_valid == '0, "multi-beat lists did not drain");

    push(3, Xlen'('h30), '1, 1'b1);
    pop_list   = ListBits'(3);
    pop_valid  = 1'b1;
    push_list  = ListBits'(3);
    push_data  = Xlen'('h31);
    push_mask  = '1;
    push_last  = 1'b1;
    push_valid = 1'b1;
    #1;
    check(push_ready && pop_data == Xlen'('h30), "singleton replacement was not ready");
    tick(1);
    pop_valid  = 1'b0;
    push_valid = 1'b0;
    pop(3, Xlen'('h31), '1, 1'b1);

    for (int entry = 0; entry < NumBeats - 1; entry++)
    push(0, Xlen'(entry), '1, entry == NumBeats - 2);
    push(1, Xlen'('h100), '1, 1'b1);
    check(!push_ready && list_valid[0] && list_valid[1], "40 shared beat entries did not fill");
    pop_list   = '0;
    pop_valid  = 1'b1;
    push_list  = ListBits'(2);
    push_data  = Xlen'('h200);
    push_mask  = '1;
    push_last  = 1'b1;
    push_valid = 1'b1;
    #1;
    check(!push_ready && pop_data == '0, "full pool reused an entry on the same edge as pop");
    tick(1);
    pop_valid  = 1'b0;
    push_valid = 1'b0;
    check(push_ready, "pop did not release a beat entry");
    push(2, Xlen'('h200), '1, 1'b1);
    for (int entry = 1; entry < NumBeats - 1; entry++)
    pop(0, Xlen'(entry), '1, entry == NumBeats - 2);
    pop(1, Xlen'('h100), '1, 1'b1);
    pop(2, Xlen'('h200), '1, 1'b1);
    check(list_valid == '0 && push_ready, "put beat pool did not finish empty");

    $display("PASS: BOOM 40-list/40-beat shared put buffer, XLEN=%0d", Xlen);
    $finish;
  end
endmodule
