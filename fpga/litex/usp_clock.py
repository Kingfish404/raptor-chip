"""UltraScale+ delay controller with the selected Vivado's primitive attributes."""
import re
import shutil
import subprocess

from migen import Instance
from litex.soc.cores.clock import USPIDELAYCTRL as LiteXUSPIDELAYCTRL


def idelayctrl_sim_device():
    # LiteX invokes vivado from PATH; the Make wrapper prepends the selected
    # VIVADO executable's directory before starting the generator.
    tool = shutil.which("vivado")
    if tool is None:
        # Permit source-only elaboration without the proprietary tools.
        return "ULTRASCALE"
    version = subprocess.check_output([tool, "-version"], text=True)
    match = re.search(r"\bVivado\s+v(\d+)\.(\d+)", version, re.IGNORECASE)
    if match is None:
        raise RuntimeError("Cannot determine Vivado's IDELAYCTRL simulation architecture")
    release = tuple(map(int, match.groups()))
    # UG571 uses ULTRASCALE for this controller on UltraScale+ too. Vivado
    # 2026.1 introduced a separate ULTRASCALE_PLUS value and requires it.
    return "ULTRASCALE_PLUS" if release >= (2026, 1) else "ULTRASCALE"


class USPIDELAYCTRL(LiteXUSPIDELAYCTRL):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # An attribute from the other tool generation is silently corrected
        # during netlist initialization, then rejected by bitgen (ADEF-911).
        cells = [cell for cell in self._fragment.specials
                 if isinstance(cell, Instance) and cell.of == "IDELAYCTRL"]
        if len(cells) != 1:
            raise ValueError("Expected exactly one LiteX IDELAYCTRL")
        params = [item for item in cells[0].items
                  if isinstance(item, Instance.Parameter) and item.name == "SIM_DEVICE"]
        if len(params) != 1:
            raise ValueError("Expected an explicit IDELAYCTRL SIM_DEVICE")
        params[0].value = idelayctrl_sim_device()
