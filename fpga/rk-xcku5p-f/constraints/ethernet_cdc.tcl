# Apply after linking, before placement. Bound Gray bus flight time and skew;
# do not hide these paths behind a blanket asynchronous clock-group exception.
set rk_rx_net [get_nets -quiet ethernet/rx_clk]
if {[llength $rk_rx_net] != 1} {error "Native Ethernet RX clock unresolved"}
set_property USER_CLOCK_ROOT X1Y1 $rk_rx_net
foreach stem {rx_write rx_read good error drop crc} {
    set first [get_cells -quiet -hier -filter "NAME =~ ethernet/packets/${stem}_sync1_reg*"]
    if {![llength $first]} {error "Native Ethernet Gray synchronizer missing: $stem"}
    set launch [all_fanin -flat -startpoints_only -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]]
    set_max_delay -datapath_only 8.000 -from $launch -to $first
    set_bus_skew 4.000 -from $launch -to $first
}
# Toggle handshakes and stable bundled data. Descriptor/length data is held
# until the acknowledged transaction completes and crosses ahead of its use.
foreach pattern {tx_done_sync1_reg* tx_request_sync1_reg*} {
    set first [get_cells -hier -filter "NAME =~ ethernet/packets/$pattern"]
    set_false_path -to $first
}
set bundled [get_cells -hier -filter {NAME =~ ethernet/packets/rx_length_reg* || NAME =~ ethernet/packets/tx_length_reg*}]
set consumers [all_fanout -flat -endpoints_only -from [get_pins -of_objects $bundled -filter {REF_PIN_NAME == Q}]]
set_max_delay -datapath_only 8.000 -from $bundled -to $consumers
# Packet RAM uses independent clocks and explicit ownership. Constrain only
# the crossing port addresses/control via their Gray/toggle handshakes above.
# Async reset assertion is intentional; release is synchronized in each domain.
set_false_path -to [get_pins -hier -filter {NAME =~ ethernet/* && (REF_PIN_NAME == CLR || REF_PIN_NAME == PRE)}]
