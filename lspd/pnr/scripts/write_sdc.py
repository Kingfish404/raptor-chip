#!/usr/bin/env python3

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Write LSPD physical-design constraints")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--clock-port", required=True)
    parser.add_argument("--period-ns", type=float, required=True)
    args = parser.parse_args()

    io_delay = args.period_ns * 0.20
    content = f"""create_clock -name core_clock -period {args.period_ns:.6f} [get_ports {args.clock_port}]
set data_inputs {{}}
foreach port [get_ports -quiet *] {{
  if {{[get_property $port direction] eq "input" && [get_property $port name] ne "{args.clock_port}"}} {{
    lappend data_inputs $port
  }}
}}
if {{[llength $data_inputs] > 0}} {{
  set_input_delay {io_delay:.6f} -clock core_clock $data_inputs
}}
set outputs [get_ports -quiet -filter "direction == output"]
if {{[llength $outputs] > 0}} {{
  set_output_delay {io_delay:.6f} -clock core_clock $outputs
}}
set reset_ports [get_ports -quiet -regexp {{(^|.*_)(reset|rst)(_n)?$}}]
if {{[llength $reset_ports] > 0}} {{
  set_false_path -from $reset_ports
}}
"""
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding="ascii")


if __name__ == "__main__":
    main()