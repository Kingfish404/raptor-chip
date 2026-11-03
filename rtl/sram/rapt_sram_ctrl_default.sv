// Expose the selected preset's constant to integrations in other HDL languages.
module rapt_sram_ctrl_default (
    output rapt_pkg::sram_ctrl_t sram_ctrl_o
);
  assign sram_ctrl_o = rapt_pkg::SramCtrlReset;
endmodule
