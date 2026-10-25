// Module-local rising-edge step, with post-edge settling.
task automatic tick;
  @(posedge clock);
  #1;
endtask
