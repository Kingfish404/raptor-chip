# Small reproduction before committing to a whole-board implementation.
set_param general.maxThreads 4
read_verilog loader.v
synth_design -top rapt_arty_loader -part xc7a100tcsg324-1 -no_iobuf
write_verilog -force -mode funcsim loader-mapped.v
report_utilization -file loader-utilization.rpt
puts "RAPT_LOADER_SYNTH_PASS"
