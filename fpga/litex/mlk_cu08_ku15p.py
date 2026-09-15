#!/usr/bin/env python3
"""Raptor LiteX SoC target for the MiLianKe MLK-CU08-KU15P board."""

import mlk_cu08_ku15p_platform as platform
from ku15p_soc import KU15PBoard, RaptorKU15PSoC, main as run_target

BOARD = KU15PBoard(
    name="mlk_cu08_ku15p",
    ident="Raptor LiteX SoC on MLK-CU08-KU15P",
    platform=platform.Platform,
    cm005_rx_tuned=True,
    bare_hold_uncertainty=0.050,
    default_fmc_slot="c",
)


class RaptorMLKCU08SoC(RaptorKU15PSoC):
    def __init__(self, *args, **kwargs):
        super().__init__(BOARD, *args, **kwargs)


def main():
    run_target(BOARD)


if __name__ == "__main__":
    main()
