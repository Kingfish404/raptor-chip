set top $::env(YS_TOP)
set out $::env(YS_OUT)
set FOUNDRY_PATH $::env(YS_FOUNDRY_PATH)
set platform_config_dir $::env(YS_PLATFORM_DIR)
set period_ns $::env(YS_PERIOD_NS)

yosys -import

file mkdir $out
source "$platform_config_dir/yosys_config.tcl"

set liberty_args {}
set stat_liberty_args {}
foreach lib $LIB_FILES {
    read_liberty -lib -ignore_miss_func $lib
    lappend liberty_args -liberty $lib
    lappend stat_liberty_args -liberty $lib
}
foreach lib $::env(YS_SRAM_LIB_FILES) {
    read_liberty -lib -ignore_miss_func $lib
    lappend stat_liberty_args -liberty $lib
}

set slang_cmd [concat read_slang $::env(YS_SLANG_FLAGS) --top $top $::env(YS_SV_FILES)]
read_slang {*}[lrange $slang_cmd 1 end]
hierarchy -check -top $top
synth -top $top
opt -purge

set dont_use_args {}
if {[info exists DONT_USE_CELLS]} {
    foreach cell $DONT_USE_CELLS {
        lappend dont_use_args -dont_use $cell
    }
}

if {[info exists ADDER_MAP_FILE] && $ADDER_MAP_FILE ne ""} {
    extract_fa
    techmap -map $ADDER_MAP_FILE
    techmap
    opt -fast -purge
}
if {[info exists LATCH_MAP_FILE] && $LATCH_MAP_FILE ne ""} {
    techmap -map $LATCH_MAP_FILE
}

dfflibmap {*}$liberty_args {*}$dont_use_args
opt -undriven
abc -D [expr {$period_ns * 1000.0}] {*}$liberty_args {*}$dont_use_args
setundef -zero
splitnets
hilomap -singleton -hicell {*}$TIEHI_CELL_AND_PORT -locell {*}$TIELO_CELL_AND_PORT
insbuf -buf {*}$MIN_BUF_CELL_AND_PORTS
opt_clean -purge

check
tee -o $out/$top.stat.rpt stat {*}$stat_liberty_args
write_json $out/$top.json
write_verilog -noattr -noexpr -nohex -nodec $out/$top.netlist.v