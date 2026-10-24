# RK-XCKU5P-F V1.2 RTL8211F-CG RGMII pin assignments.
set_property PACKAGE_PIN K22 [get_ports {eth_rxc}]
set_property PACKAGE_PIN K23 [get_ports {eth_rx_ctl}]
set_property PACKAGE_PIN L24 [get_ports {eth_rxd[0]}]
set_property PACKAGE_PIN L25 [get_ports {eth_rxd[1]}]
set_property PACKAGE_PIN K25 [get_ports {eth_rxd[2]}]
set_property PACKAGE_PIN K26 [get_ports {eth_rxd[3]}]
set_property PACKAGE_PIN M25 [get_ports {eth_txc}]
set_property PACKAGE_PIN M26 [get_ports {eth_tx_ctl}]
set_property PACKAGE_PIN L23 [get_ports {eth_txd[0]}]
set_property PACKAGE_PIN L22 [get_ports {eth_txd[1]}]
set_property PACKAGE_PIN L20 [get_ports {eth_txd[2]}]
set_property PACKAGE_PIN K20 [get_ports {eth_txd[3]}]
set_property PACKAGE_PIN L19 [get_ports {eth_mdc}]
set_property PACKAGE_PIN M19 [get_ports {eth_mdio}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_*}]
set_property PULLTYPE PULLUP [get_ports eth_mdio]
# This package pin is shared with the adjacent MIG bank's BISC calibration.
# Software enables the MAC only after DDR initialization releases the CPU.
set_property UNAVAILABLE_DURING_CALIBRATION TRUE [get_ports {eth_txd[1]}]
create_clock -name rk_eth_rxc -period 8.000 [get_ports eth_rxc]
# PHY RXDLY is OFF. +/-0.5 ns PHY skew plus 0.5 ns package/board budget.
set_input_delay -clock rk_eth_rxc -max 1.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rk_eth_rxc -min -1.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rk_eth_rxc -clock_fall -add_delay -max 1.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rk_eth_rxc -clock_fall -add_delay -min -1.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
create_generated_clock -name rk_eth_txc -source [get_pins ethernet/send_clock/C] -divide_by 1 [get_ports eth_txc]
# PHY TXDLY is ON: represent its delayed sample edge, preserving clock timing.
create_generated_clock -name rk_eth_phy_sample -source [get_pins ethernet/send_clock/C] \
    -edges {1 2 3} -edge_shift {2.000 2.000 2.000} -add [get_ports eth_txc] \
    -master_clock [get_clocks -of_objects [get_pins ethernet/send_clock/C]]
set_output_delay -clock rk_eth_phy_sample -max 1.000 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rk_eth_phy_sample -min -1.000 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rk_eth_phy_sample -clock_fall -add_delay -max 1.000 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rk_eth_phy_sample -clock_fall -add_delay -min -1.000 [get_ports {eth_txd[*] eth_tx_ctl}]
# Software bitbangs MDIO slowly; its input is sampled after protocol delays.
set_false_path -from [get_ports eth_mdio]
set_false_path -to [get_ports {eth_mdio eth_mdc}]
