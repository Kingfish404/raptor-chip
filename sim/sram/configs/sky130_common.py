# Common OpenRAM settings for raptor-chip cache SRAMs on sky130.
# Sourced by the per-shape configs in this directory.

tech_name = "sky130"
nominal_corner_only = True

# Power-grid routing strategy. "ring" wraps the macro in a power ring;
# safer for placement into a chip-level power grid than "left".
route_supplies = "ring"

# LVS/DRC sign-off on each generated macro. Set False to skip for faster
# iteration when only timing/area numbers are needed.
check_lvsdrc = True
uniquify     = True

# Output naming so OpenRAM-generated artefacts land under
#   build/sky130/macro/<output_name>/
# Matches the alias declared in wrappers/rapt_sram_blackbox.v.
human_byte_size = "{:.0f}b".format((word_size * num_words) / 8)
output_name = "rapt_openram_{ports_human}_{num_words}x{word_size}".format(**locals())
output_path = "macro/{output_name}".format(**locals())
