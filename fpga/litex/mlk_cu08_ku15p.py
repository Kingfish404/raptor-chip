#!/usr/bin/env python3
"""Raptor LiteX SoC target for the MiLianKe MLK-CU08-KU15P board."""

import mlk_cu08_ku15p_platform as mlk_cu08_ku15p

import mlk_cu07_ku15p as _ku15p


_ku15p.mlk_cu07_ku15p = mlk_cu08_ku15p
_ku15p.BOARD_NAME = "mlk_cu08_ku15p"
_ku15p.BOARD_IDENT = "Raptor LiteX SoC on MLK-CU08-KU15P"


if __name__ == "__main__":
    _ku15p.main()
