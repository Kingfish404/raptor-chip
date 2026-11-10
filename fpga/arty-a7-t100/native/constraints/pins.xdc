# Native MT35X fixture; every location below is an FPGA-side 3.3 V signal.
# Flash/JTAG/UART0 wiring agrees with the reference-tested ChipKIT connector.
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk100]
create_clock -name ref100 -period 10.000 [get_ports clk100]
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports jtag_tck]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports jtag_tms]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports jtag_tdi]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports jtag_tdo]
set_property PULLDOWN true [get_ports jtag_tck]
set_property PULLUP true [get_ports {jtag_tms jtag_tdi}]

set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports flash_ck]
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS33} [get_ports flash_cs_n]
set_property -dict {PACKAGE_PIN U11 IOSTANDARD LVCMOS33} [get_ports flash_reset_n]
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports flash_dqs]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {flash_dq[0]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {flash_dq[1]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {flash_dq[2]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports {flash_dq[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {flash_dq[4]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {flash_dq[5]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {flash_dq[6]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {flash_dq[7]}]
set_property PULLUP true [get_ports {flash_cs_n flash_reset_n}]
# M13 retains the real DS/DIAG bidirectional pad, including its data/OE paths.
set_property PULLDOWN true [get_ports flash_dqs]

# UART0 retains the external reference connector; UART1 uses onboard USB-UART.
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports uart0_rx]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports uart0_tx]
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports uart1_rx]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart1_tx]
# Free ChipKIT IO0..2; neither Flash nor external JTAG uses these signals.
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {gpio[0]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {gpio[1]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {gpio[2]}]

set_property DRIVE 4 [get_ports -filter {DIRECTION != IN}]
set_property SLEW SLOW [get_ports -filter {DIRECTION != IN}]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
