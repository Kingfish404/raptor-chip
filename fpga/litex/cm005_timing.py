"""Board RGMII constraints shared by the SoC and the standalone CM005 bridge."""
import os

_here = os.path.dirname(os.path.abspath(__file__))


def constrain_cm005(platform, crg, phy, clocks, pads, eth_speed=1000,
                    oversampled_rx=False, tuned_ethernet=False,
                    tx_serial=None, name="cm005", tx_local_clock=True,
                    tx_word_net="cm005_tx_clk", tx_mac_clock=None):
    if tx_mac_clock is None:
        tx_mac_clock = crg.cd_cm005_tx.clk
    if tx_serial is None:
        tx_serial = oversampled_rx and eth_speed == 1000
    if tx_serial:
        # At 125 MHz DDR, use fast output edges on data/control and
        # forwarded clock together; keep the PHY setup/hold budget.
        platform.add_platform_command(
            "set_property SLEW FAST [get_ports {{{txclk} {txdata}[*] {txctl}}}]",
            txclk=clocks.tx, txdata=pads.tx_data, txctl=pads.tx_ctl)
    if oversampled_rx:
        # These inputs are intentionally asynchronous to the 1.25 GS/s
        # sampler. Bound the first-stage data paths; aperture/relative
        # lane delay is a separate sampling-window verification item.
        platform.add_platform_command(
            "set_max_delay 2.0 -datapath_only "
            "-from [get_ports {{{rxclk} {rxdata}[*] {rxctl}}}] "
            "-to [get_pins -of_objects [get_cells -hier -filter "
            "{{REF_NAME == ISERDESE3 && NAME =~ *cm005_sample_*}}] "
            "-filter {{REF_PIN_NAME == D}}]",
            rxclk=clocks.rx, rxdata=pads.rx_data, rxctl=pads.rx_ctl)
        platform.add_platform_command(
            "set_property LOC MMCM_X0Y8 [get_cells cm005_sample_pll]")
        # This auto-inserted BUFG exists after synthesis/optimization,
        # not during the synthesis-stage XDC read.
        platform.toolchain.pre_placement_commands += [
            "set_property CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN "
            "[get_nets -of_objects [get_pins clk100_IBUF_BUFG_inst/O]]"]
        tx_clock_net = "cm005_tx_serial_clk" if eth_speed == 1000 else "cm005_tx_shifted_clk"
        # Synthesis merges cm005_sample_div_clk into eth_rx_clk.
        # Buffer output pins survive that alias merge, unlike the
        # original net name used by the physical clock constraints.
        sampling_clock_nets = (
            "[get_nets -of_objects [get_pins "
            "{{cm005_sample_fast_buf/O cm005_sample_word_buf/O}}]]")
        platform.add_platform_command(
            "set_property USER_CLOCK_ROOT X2Y8 " + sampling_clock_nets)
        platform.add_platform_command(
            "set_property USER_CLOCK_ROOT X2Y8 "
            "[get_nets {{" + tx_word_net + " " + tx_clock_net + "}}]")
        if eth_speed == 1000:
            platform.add_platform_command(
                "set_property CLOCK_DELAY_GROUP cm005_transmit "
                "[get_nets {{" + tx_word_net + " cm005_tx_serial_clk}}]")
            # The complete MAC spreads TX clock loads farther than
            # a PHY-only test. Keep this small clock domain local to
            # the I/O region so its clock tree does not consume the
            # RGMII setup/hold window (UG912 CLOCK_LOW_FANOUT).
            if tx_local_clock:
                platform.add_platform_command(
                    "set_property CLOCK_LOW_FANOUT TRUE "
                    "[get_nets {{" + tx_word_net + " cm005_tx_serial_clk}}]")
        platform.add_platform_command(
            "set_property CLOCK_DELAY_GROUP cm005_sampling "
            + sampling_clock_nets)
        platform.toolchain.bitstream_commands += [
            "source {{" + os.path.join(_here, "scripts", "check_cm005_aperture.tcl") + "}}",
            "cm005_check_sampling_aperture cm005_aperture.rpt",
        ]
    else:
        # Platform period constraints are emitted after user commands.
        # Define this clock before the following I/O delays reference it.
        platform.add_platform_command(
            f"create_clock -name {name}_rxclk -period {40.0 if eth_speed == 100 else 8.0} [get_ports {{rxclk}}]",
            rxclk=clocks.rx)
    platform.add_false_path_constraints(crg.cd_sys.clk, phy.crg.cd_eth_rx.clk)
    platform.add_false_path_constraints(tx_mac_clock, phy.crg.cd_eth_rx.clk)
    # LiteEth's TX CDC is an AsyncFIFO (gray-coded pointers) written on
    # sys_clk and read on the 125 MHz cm005_tx_clk. Without this group
    # the FIFO's dual-clock LUTRAM path is timed as a synchronous
    # 4 ns path and becomes the reported SoC WNS.
    platform.add_false_path_constraints(crg.cd_sys.clk, tx_mac_clock)
    # YT8531 datasheet table 95: delayed RX clock guarantees 1 ns
    # setup/hold. Constrain both DDR edges, including 0.2 ns PCB margin.
    # Describe the NEXT transition after each sampling edge. STA then
    # checks setup at the next half-cycle and hold at the current edge.
    # IDDRE1 retains setup checks on C and CB even when Q2 is unused.
    # Keep both sampling edges constrained in 100M mode too: the PHY
    # repeats the nibble, so allowing an independent transition in
    # each half-cycle is conservative. Preserve the same 1 ns PHY
    # setup/hold guarantee and 0.2 ns PCB margin at both edges.
    rx_max = 19.2 if eth_speed == 100 else 3.2
    for edge in (() if oversampled_rx else ("", "-clock_fall -add_delay")):
        platform.add_platform_command(
            "set_input_delay -clock [get_clocks -of_objects [get_ports {rxclk}]] "
            f"-max {rx_max} {edge} [get_ports {{{{ {{rxdata}}[*] {{rxctl}} }}}}]",
            rxclk=clocks.rx, rxdata=pads.rx_data, rxctl=pads.rx_ctl)
        platform.add_platform_command(
            "set_input_delay -clock [get_clocks -of_objects [get_ports {rxclk}]] "
            f"-min 0.8 {edge} [get_ports {{{{ {{rxdata}}[*] {{rxctl}} }}}}]",
            rxclk=clocks.rx, rxdata=pads.rx_data, rxctl=pads.rx_ctl)
    # UltraScale+ defaults to LATENCY phase-shift modeling. RGMII
    # samples at the forwarded quarter-cycle edge, so model that
    # edge explicitly (UG906 MMCM/PLL Phase Shift Modes).
    if not tx_serial:
        platform.add_platform_command(
            "set_property PHASESHIFT_MODE WAVEFORM "
            "[get_cells -hier -filter {{REF_NAME == MMCME4_ADV && CLKOUT1_PHASE == 90.000}}]")
    if tuned_ethernet:
        # CU08 FMCA/ETHA DDR IO is in X2Y8. Keep its MMCM and clock
        # roots nearby; otherwise the RX clock insertion can exceed
        # the external hold window. Use only dedicated clock routing
        # for the shared 100 MHz input's remote MMCM load.
        platform.add_platform_command(
            "set_property LOC MMCM_X0Y8 [get_cells -hier -filter "
            "{{REF_NAME == MMCME4_ADV && CLKOUT1_PHASE == 90.000}}]")
        platform.add_platform_command(
            "set_property CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN "
            "[get_nets -of_objects [get_pins clk100_IBUF_BUFG_inst/O]]")
        platform.add_platform_command(
            "set_property USER_CLOCK_ROOT X2Y8 "
            "[get_nets {{eth_rx_clk cm005_tx_clk cm005_tx_shifted_clk}}]")
    if tx_serial:
        # The DDR pattern divides 250 MHz by two and places the output
        # transition 2 ns after each selected rising edge. Use an explicit
        # phase shift: selecting falling master edges with {2 4 6} loses
        # source latency after Vivado 2026.1 maps ODDRE1 to OSERDESE3
        # (TIMING-5/36), despite describing the same {2 6} ns waveform.
        platform.add_platform_command(
            "create_generated_clock -name " + name + "_txclk -source "
            "[get_pins -of_objects [get_cells " + name + "_tx_clock_ddr] "
            "-filter {{REF_PIN_NAME == C || REF_PIN_NAME == CLK}}] "
            "-edges {{1 3 5}} -edge_shift {{2 2 2}} [get_ports {txclk}]", txclk=clocks.tx)
    else:
        platform.add_platform_command(
            "create_generated_clock -name " + name + "_txclk -source "
            "[get_pins -of_objects [get_cells -hier -filter {{NAME =~ *cm005_txclk_ddr}}] "
            "-filter {{REF_PIN_NAME == C || REF_PIN_NAME == CLK}}] "
            "-divide_by 1 [get_ports {txclk}]", txclk=clocks.tx)
    for edge in ("", "-clock_fall -add_delay"):
        for bound, delay in (("max", 1.2), ("min", -1.2)):
            platform.add_platform_command(
                f"set_output_delay -clock {name}_txclk -{bound} {delay} {edge} "
                "[get_ports {{ {txdata}[*] {txctl} }}]",
                txdata=pads.tx_data, txctl=pads.tx_ctl)
