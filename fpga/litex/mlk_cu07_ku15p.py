#!/usr/bin/env python3
"""Raptor LiteX SoC target for the MiLianKe MLK-CU07-KU15P board."""

from litex_boards.platforms import mlk_cu07_ku15p as platform
from ku15p_soc import KU15PBoard, RaptorKU15PSoC, main as run_target

BOARD = KU15PBoard(
    name="mlk_cu07_ku15p",
    ident="Raptor LiteX SoC on MLK-CU07-KU15P",
    platform=platform.Platform,
)


class RaptorMLKCU07SoC(RaptorKU15PSoC):
    def __init__(self, *args, **kwargs):
        super().__init__(BOARD, *args, **kwargs)


def main():
    run_target(BOARD)


if __name__ == "__main__":
    main()
