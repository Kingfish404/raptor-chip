# CU08 DDR4 2133 MT/s overrides. LiteX inlines this before the shared script.
# Keep CU07 at its 2400 MT/s defaults.
# For the board-manual Hynix -VK speed bin, 938 ps permits CL=15/CWL=11.
# The selected Micron MIG part is a vendor-demo proxy until the fitted part
# has been checked; Vivado IP validation and on-board calibration are required.
set raptor_ddr4_time_period 938
set raptor_ddr4_input_clock_period 10005
set raptor_ddr4_cas_latency 15
set raptor_ddr4_cas_write_latency 11
