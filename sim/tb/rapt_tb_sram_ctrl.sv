`timescale 1ns / 1ps

package sram_ctrl_test_pkg;
  int instances = 0;
  int reset_checks = 0;
  int write_checks = 0;
  int setting_checks = 0;
  int restore_checks = 0;
endpackage

// Bound to the module types so the census automatically includes every elaborated SRAM.
module rapt_tb_sram_ctrl_probe (
    input logic clock,
    input rapt_pkg::sram_ctrl_t ctrl
);
  import sram_ctrl_test_pkg::*;
  initial begin
    instances++;
    repeat (10) @(negedge clock);
    if (ctrl !== rapt_pkg::SramCtrlReset) $fatal(1, "SRAM reset control %m = %h", ctrl);
    reset_checks++;
    $display("SRAM_CTRL_RESET %m = %h", ctrl);
    wait (ctrl == 16'h7fff);
    @(negedge clock);
    if (ctrl !== 16'h7fff) $fatal(1, "SRAM write control %m = %h", ctrl);
    write_checks++;
    wait (ctrl == 16'h1234);
    @(negedge clock);
    if (ctrl !== 16'h1234) $fatal(1, "SRAM setting control %m = %h", ctrl);
    setting_checks++;
    wait (ctrl == rapt_pkg::SramCtrlReset);
    @(negedge clock);
    if (ctrl !== rapt_pkg::SramCtrlReset) $fatal(1, "SRAM restored control %m = %h", ctrl);
    restore_checks++;
  end
endmodule

bind rapt_sram_1rw rapt_tb_sram_ctrl_probe u_ctrl_probe (
    .clock(clock),
    .ctrl (sram_ctrl_i)
);
bind rapt_sram_2rw rapt_tb_sram_ctrl_probe u_ctrl_probe (
    .clock(clock),
    .ctrl (sram_ctrl_i)
);

module rapt_tb_sram_ctrl;
  import sram_ctrl_test_pkg::*;
  // Real core loads/stores reach the local MMIO window through the cluster fabric.
  rapt_tb_chip chip ();
  initial begin
    repeat (15) @(negedge chip.clock);
    if (rapt_pkg::SramCtrlReset !== 16'h0608) $fatal(1, "Wrong chip preset reset");
    if (instances != 12 || reset_checks != instances)
      $fatal(
          1, "SRAM reset census: instances=%0d checked=%0d expected=12", instances, reset_checks
      );
    $display("PASS: SRAM reset census, all %0d instances = 0608", instances);
    wait (write_checks == instances);
    $display("PASS: SRAM control write reaches all %0d instances", write_checks);
    wait (restore_checks == instances);
    $display("PASS: SRAM control settings and restore reach all %0d instances", restore_checks);
  end
  final begin
    if (instances != 12 || reset_checks != instances || write_checks != instances
        || setting_checks != instances || restore_checks != instances || chip.sim_exit_code != 0)
      $error("Incomplete SRAM census or failing core payload");
  end
endmodule
