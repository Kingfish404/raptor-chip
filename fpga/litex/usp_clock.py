"""UltraScale+ delay controller with an explicit Vivado 2026.1 architecture."""
from migen import Instance
from litex.soc.cores.clock import USPIDELAYCTRL as LiteXUSPIDELAYCTRL


class USPIDELAYCTRL(LiteXUSPIDELAYCTRL):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Older LiteX uses ULTRASCALE for this primitive. Vivado 2026.1
        # upgrades it during initialization, then rejects bitgen (ADEF-911).
        # Describe the real architecture at source; do not waive the DRC.
        cells = [cell for cell in self._fragment.specials
                 if isinstance(cell, Instance) and cell.of == "IDELAYCTRL"]
        if len(cells) != 1:
            raise ValueError("Expected exactly one LiteX IDELAYCTRL")
        params = [item for item in cells[0].items
                  if isinstance(item, Instance.Parameter) and item.name == "SIM_DEVICE"]
        if len(params) != 1:
            raise ValueError("Expected an explicit IDELAYCTRL SIM_DEVICE")
        params[0].value = "ULTRASCALE_PLUS"
