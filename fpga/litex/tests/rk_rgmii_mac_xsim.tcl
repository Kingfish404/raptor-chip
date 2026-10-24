# Run in the directory emitted by rk_rgmii_rx_xsim.py --with-mac.
# Functional gate simulation avoids event-simulator delta loops through the
# behavioral MAC's combinational default assignments. Native DDR primitives
# remain in the netlist; this is not routed timing simulation.
set_param general.maxThreads 2
read_verilog rk_rgmii_mac.v
synth_design -top rk_rgmii_mac -part xcku5p-ffvb676-2-i -mode out_of_context
write_verilog -force -mode funcsim rk_rgmii_mac_funcsim.v
report_utilization -file mac-utilization.rpt
exit
