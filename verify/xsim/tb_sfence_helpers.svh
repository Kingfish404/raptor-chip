// Shared VPN conversion and full-flush driver for L1/L2 selective tests.
function automatic logic [XLEN-1:12] tag(input int unsigned vpn);
  return XLEN == 64 ? (XLEN - 12)'($signed(27'(vpn))) : (XLEN - 12)'(vpn);
endfunction
task automatic clear_all;
  @(negedge clock);
  flush = 1;
  tick();
  @(negedge clock);
  flush = 0;
endtask
