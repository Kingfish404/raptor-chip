# Link pins are sampled as data, not clocks. Reserve 10 ns pad/routing delay
# per direction; board clock is 100 MHz, core clock 20 MHz. The shortest link
# half period is 100 ns, leaving room for the target's three-clock launch.
# Clock startpoints preserve register setup/hold timing. Register Q startpoints
# would segment those paths and invalidate internal timing analysis.
set all_clocks [get_clocks -include_generated_clocks *]
set async_inputs [get_ports {btn[*] boot_switch uart_rx jtag_tck jtag_tms jtag_tdi}]
set_max_delay -datapath_only 10.0 -from $async_inputs
set_false_path -hold -from $async_inputs
set_max_delay -datapath_only 10.0 -from [get_ports {flash_dq[*] flash_dqs}]
set_false_path -hold -from [get_ports {flash_dq[*] flash_dqs}]
set_false_path -hold -to [get_ports {led[*] uart_tx jtag_tdo}]
set_false_path -hold -to [get_ports {flash_ck flash_cs_n flash_reset_n flash_dq[*]}]
# Human indicators, 115200-baud UART and 500 kHz TDO have a 20 ns route budget.
set_max_delay -datapath_only 20.0 -from $all_clocks \
    -to [get_ports {led[*] uart_tx jtag_tdo}]
set_max_delay -datapath_only 10.0 -from $all_clocks \
    -to [get_ports {flash_ck flash_cs_n flash_reset_n flash_dq[*]}]
if {$join eq "pins"} {
    set core_clk [get_clocks -of_objects [get_pins u_clocks/u_core_clock/O]]
    set board_clk [get_clocks -of_objects [get_pins u_clocks/u_board_clock/O]]
    set_input_delay -clock $board_clk -max 0.0 \
        [get_ports {board_sclk board_cs_n board_dq[*]}]
    set_input_delay -clock $board_clk -min 0.0 \
        [get_ports {board_sclk board_cs_n board_dq[*]}]
    set_input_delay -clock $core_clk -max 0.0 [get_ports {chip_dq[*]}]
    set_input_delay -clock $core_clk -min 0.0 [get_ports {chip_dq[*]}]
    set_output_delay -clock $core_clk -max 0.0 \
        [get_ports {chip_sclk chip_cs_n chip_dq[*]}]
    set_output_delay -clock $core_clk -min 0.0 \
        [get_ports {chip_sclk chip_cs_n chip_dq[*]}]
    set_output_delay -clock $board_clk -max 0.0 [get_ports {board_dq[*]}]
    set_output_delay -clock $board_clk -min 0.0 [get_ports {board_dq[*]}]
    set_max_delay -datapath_only 10.0 \
        -from [get_ports {board_sclk board_cs_n board_dq[*] chip_dq[*]}]
    set_max_delay -datapath_only 10.0 -from $all_clocks \
        -to [get_ports {chip_sclk chip_cs_n chip_dq[*] board_dq[*]}]
    # External edge phase is arbitrary. Hold is established by SDR protocol
    # (stable throughout the high phase), not a same-cycle core/board edge.
    set_false_path -hold \
        -from [get_ports {board_sclk board_cs_n board_dq[*] chip_dq[*]}]
    set_false_path -hold \
        -to [get_ports {chip_sclk chip_cs_n chip_dq[*] board_dq[*]}]
}
