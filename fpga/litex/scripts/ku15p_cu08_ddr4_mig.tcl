# CU08 DDR4-2666 / 333.333 MHz UI. LiteX inlines this before the shared script.
# Keep this explicit board profile aligned with the shared KU15P defaults.
# The core manual specifies H5AN8G6NCJR-VKI; use an 8 Gb x16, 2666 timing proxy
# from Vivado's catalog. Validate calibration and memory traffic on the board.
set raptor_ddr4_memory_part MT40A512M16LY-075
set raptor_ddr4_time_period 750
set raptor_ddr4_input_clock_period 10000
set raptor_ddr4_cas_latency 19
set raptor_ddr4_cas_write_latency 14
