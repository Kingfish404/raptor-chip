# CU08 DDR4 1600 MT/s / 200 MHz UI overrides. LiteX inlines this before the shared script.
# Keep CU07 at its 2400 MT/s defaults.
# Use the matched 100 MHz reference and CL=12/CWL=9 for the 1250 ps memory period.
# The selected Micron MIG part is a vendor-demo proxy until the fitted part
# has been checked; Vivado IP validation and on-board calibration are required.
set raptor_ddr4_time_period 1250
set raptor_ddr4_input_clock_period 10000
set raptor_ddr4_cas_latency 12
set raptor_ddr4_cas_write_latency 9
