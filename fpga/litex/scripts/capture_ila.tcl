# ============================================================================
# capture_ila.tcl -- program the ILA bitstream and capture the dual-commit
# hang.  Two modes (4th tclarg):
#
#   derail (default) -- TRANSITION capture.  Trigger on the first derailment
#       (dbg_commit_pc == 0 while dbg_commit_fire == 1); the reset vector is
#       the ROM at 0x20000000, so a committed PC of 0 is unambiguously a jump
#       to null.  Trigger position is late so the window holds ~1.6 ms of
#       history *before* the derailment (the corrupting dual-commit + the
#       instruction that jumped to 0).  Requires arm-before-boot: hold the J23
#       button (CPU-only reset, --with-ila builds) during programming/arming,
#       then release when the script prints "ARMED".
#
#   hang -- DEADLOCK capture.  Trigger on dbg_hang == 1 (ROB non-empty with
#       no commit for >3000 cycles).  Late trigger position keeps the commit
#       stream leading into the deadlock.  Use when the failure is a pipeline
#       stall rather than a jump-to-0 runaway.
#
#   now -- snapshot the current (already hung) steady state with trigger_now.
#
# Usage:
#   vivado -mode batch -source capture_ila.tcl -tclargs <bit> <ltx> <csv> [mode]
#
# The .ltx (debug probes file) is emitted by write_bitstream next to the .bit.
# ============================================================================
if {$argc < 3} {
    puts "ERROR: usage: capture_ila.tcl <bitstream.bit> <probes.ltx> <out.csv> \[derail|hang|now\]"
    exit 1
}
set bitstream [file normalize [lindex $argv 0]]
set ltx       [file normalize [lindex $argv 1]]
set outcsv    [lindex $argv 2]
set mode      "derail"
if {$argc >= 4} { set mode [lindex $argv 3] }
puts "INFO: \[capture_ila\] bit=$bitstream"
puts "INFO: \[capture_ila\] ltx=$ltx"
puts "INFO: \[capture_ila\] mode=$mode"

open_hw_manager
connect_hw_server
open_hw_target

# sys_clk is only 10 MHz; the ILA sample clock must be faster than JTAG TCK or
# Vivado reports "Slow clock or no clock connected" [27-2215]. Drop TCK well
# below 10 MHz.
catch {set_property PARAM.FREQUENCY 2000000 [current_hw_target]}

set dev ""
foreach d [get_hw_devices] {
    if {[string match -nocase "*ku15p*" $d] || [string match -nocase "xcku15p*" $d]} {
        set dev $d
        break
    }
}
if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
puts "INFO: \[capture_ila\] device: $dev"
current_hw_device $dev

# Program first WITHOUT a probes file so the device signature comes purely from
# the bitstream, then attach the matching .ltx and refresh.  Programming can be
# skipped (env CAPTURE_NOPROG=1) for the re-armable transition capture, where
# the device is already configured and we only re-arm between button presses.
if {[info exists ::env(CAPTURE_NOPROG)] && $::env(CAPTURE_NOPROG) eq "1"} {
    puts "INFO: \[capture_ila\] skipping programming (device already configured)"
} else {
    set_property PROGRAM.FILE $bitstream $dev
    program_hw_devices $dev
    after 500
}

set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev
after 500

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
if {$ila eq ""} {
    puts "ERROR: \[capture_ila\] no hw_ila found after refresh"
    close_hw_target
    exit 1
}
puts "INFO: \[capture_ila\] ila: $ila"
puts "INFO: \[capture_ila\] probes: [get_hw_probes -of_objects $ila]"

# Clear any stale per-probe trigger compares from a previous run so only the
# terms we set below constrain the trigger (unset probes are don't-care).
foreach pr [get_hw_probes -of_objects $ila] {
    catch {set_property TRIGGER_COMPARE_VALUE {eq1'hX} $pr}
}

if {$mode eq "now"} {
    # --- Steady-state snapshot of the already-hung core --------------------
    set hangprobe [get_hw_probes -of_objects $ila -filter {NAME =~ "*dbg_hang*"}]
    if {$hangprobe ne ""} {
        set_property TRIGGER_COMPARE_VALUE eq1'b1 $hangprobe
    }
    set_property CONTROL.TRIGGER_POSITION 8192 $ila
    puts "INFO: \[capture_ila\] letting BIOS run into the hang (3s)"
    after 3000
    puts "INFO: \[capture_ila\] trigger_now snapshot of hung state"
    run_hw_ila $ila -trigger_now
} elseif {$mode eq "hang"} {
    # --- Deadlock capture: trigger on dbg_hang == 1 -------------------------
    # dbg_hang asserts when the ROB is non-empty yet no commit fired for
    # >3000 cycles (pipeline deadlock).  Late trigger position keeps ~16000
    # pre-trigger samples: the commit stream leading INTO the deadlock.
    set hangprobe [get_hw_probes -of_objects $ila -filter {NAME =~ "*dbg_hang*"}]
    if {$hangprobe eq ""} {
        puts "ERROR: \[capture_ila\] could not find dbg_hang probe"
        close_hw_target
        exit 1
    }
    set_property TRIGGER_COMPARE_VALUE {eq1'b1} $hangprobe
    set_property CONTROL.TRIGGER_POSITION 16000 $ila
    puts "INFO: \[capture_ila\] trigger = (dbg_hang == 1), pos=16000"
    run_hw_ila $ila
    puts "==================================================================="
    puts "ARMED: ILA armed, waiting for the deadlock trigger."
    puts "  The CPU is held in reset by the auto-release counter and will"
    puts "  boot on its own after configuration; a commit stall >3000 cycles"
    puts "  with a non-empty ROB will fire the trigger."
    puts "==================================================================="
    flush stdout
} else {
    # --- Transition capture: trigger on the first jump-to-null -------------
    # commit_pc == 0 while commit_fire == 1.  All other probes stay don't-care,
    # so Vivado ANDs exactly these two terms.
    set pcprobe   [get_hw_probes -of_objects $ila -filter {NAME =~ "*dbg_commit_pc*" && NAME !~ "*dbg_commit_pc_b*"}]
    set fireprobe [get_hw_probes -of_objects $ila -filter {NAME =~ "*dbg_commit_fire*"}]
    if {$pcprobe eq "" || $fireprobe eq ""} {
        puts "ERROR: \[capture_ila\] could not find commit_pc / commit_fire probes"
        close_hw_target
        exit 1
    }
    set_property TRIGGER_COMPARE_VALUE {eq32'h00000000} $pcprobe
    set_property TRIGGER_COMPARE_VALUE {eq1'b1} $fireprobe
    # Late trigger position -> keep ~16000 pre-trigger samples (history before
    # the derailment) and a few hundred after.
    set_property CONTROL.TRIGGER_POSITION 16000 $ila
    puts "INFO: \[capture_ila\] trigger = (commit_pc == 0 && commit_fire == 1), pos=16000"
    run_hw_ila $ila
    puts "==================================================================="
    puts "ARMED: ILA armed, waiting for the derailment trigger."
    puts "  The CPU is held in reset by the auto-release counter and will"
    puts "  boot on its own ~54 s after configuration; the boot -> jump-to-0"
    puts "  will then fire the trigger.  No user action required."
    puts "==================================================================="
    flush stdout
}

# Robust wait: poll STATUS.CORE_STATUS until the ILA is Full (triggered + captured)
# rather than relying on wait_on_hw_ila's default timeout (the CPU boots only
# ~54 s after config, which can exceed that default).
if {$mode eq "now"} {
    if {[catch {wait_on_hw_ila $ila} err]} {
        puts "WARNING: \[capture_ila\] wait_on_hw_ila: $err"
    }
} else {
    set done 0
    for {set t 0} {$t < 150} {incr t} {
        after 2000
        if {[catch {refresh_hw_device -quiet $dev} e]} {}
        set st ""
        catch {set st [get_property STATUS.CORE_STATUS $ila]}
        if {[expr {$t % 5 == 0}]} { puts "INFO: \[capture_ila\] t=[expr {$t*2}]s CORE_STATUS=$st" ; flush stdout }
        if {[string match -nocase "*FULL*" $st] || [string match -nocase "*IDLE*" $st]} {
            set done 1
            break
        }
    }
    if {!$done} {
        puts "WARNING: \[capture_ila\] timed out waiting for trigger; uploading whatever is captured"
    }
}
upload_hw_ila_data $ila
set data [current_hw_ila_data]
write_hw_ila_data -csv_file -force $outcsv $data
puts "INFO: \[capture_ila\] wrote $outcsv"

close_hw_target
close_hw_manager
