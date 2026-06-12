task automatic fail(input string msg);
  begin
    $error("FAIL: %s", msg);
    $finish;
  end
endtask

task automatic check(input bit condition, input string msg);
  begin
    if (!condition) fail(msg);
  end
endtask

task automatic tick(input int cycles);
  begin
    repeat (cycles) @(posedge clock);
    #1;
  end
endtask