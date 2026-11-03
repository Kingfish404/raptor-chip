# Focused synthesis before another whole-board run; all output stays in cwd.
set_param general.maxThreads 4
read_verilog probe.v
set top [lindex $argv 0]
if {$top eq ""} {set top rapt_arty_operand_probe}
synth_design -top $top -part xc7a100tcsg324-1 -no_iobuf
write_verilog -force -mode funcsim probe-mapped.v
report_utilization -file probe-utilization.rpt
puts RAPT_OPERAND_SYNTH_PASS
