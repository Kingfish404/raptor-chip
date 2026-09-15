# CU08 CM005 FMC_C / ETHA integration

This guide describes the board connection and implementation contract, not a
record of a particular bitstream passing timing or board tests. Use matching
firmware, device tree and gateware from the same configuration.

## Connection

MLK-CU08 defaults to the short-edge FMC_C connector, ETHA, with **1.8 V I/O**.
Check the adjustable-bank supply before connecting the module. The PHY reset
gate affects both Ethernet ports. CU07 defaults to FMC_A instead.

| Signal (ascending bit order) | FMC contact | FPGA pin |
| --- | --- | --- |
| RX_CLK | C22 | L19 |
| TX_CLK | D20 | F18 |
| RX_CTL | C18 | D14 |
| RXD[0:3] | C15 C14 C11 C10 | B16 B17 A18 A19 |
| TX_CTL | D21 | F17 |
| TXD[0:3] | D18 D17 C23 C19 | D15 E15 L18 C14 |
| MDC / MDIO | D14 / D15 | B15 / A15 |
| Reset gate (active high) | G16 | E8 |

The source of the pin mapping is `PINOUTS` in [cm005.py](cm005.py).
Select it with `FMC_SLOT=c ETH_PORT=a`. Ethernet must be explicitly enabled
with `WITH_ETHERNET=1`; the default enabled-link speed is 1000 Mb/s.
`ETH_SPEED=100` selects a separate fixed-speed build. The same bitstream does
not switch between 100/1000 Mb/s or connector pin mappings at runtime.

## Receive and transmit paths

L19 is not a global-clock input. [cm005_oversample.py](cm005_oversample.py)
samples RX_CLK, RX_CTL and RXD as data using six ISERDESE3 lanes at 625 MHz
DDR (1.25 GS/s), processing eight samples per 156.25 MHz cycle. RX_CLK has
460 ps of extra input delay. Edge detection selects the preceding data sample;
the control edges recover RX_DV and RX_ER. L19 is not routed as a fabric clock,
and the implementation does not use `CLOCK_DEDICATED_ROUTE FALSE`.

Gigabit transmit uses related 250/125 MHz clocks, native 125 MHz DDR data and
a forwarded clock aligned between data transitions. PHY initialization
advertises only the configured full-duplex speed and restarts negotiation
after reset. The peer must support that negotiation.

Asynchronous receive inputs use bounded path-delay constraints and a separate
[sampling-aperture check](scripts/check_cm005_aperture.tcl). This is not a
claim of conventional synchronous input setup/hold closure or analog MTBF.
The current digital check requires the routed relative delay to remain within
0.025–0.775 ns. Re-run it after routing changes; do not inherit an old report.

## Build and validation

Use the [paired RV32/RV64 build/load flow](README.md#cu08-rv32rv64-netboot-build-and-load)
and [netboot bundle guide](NETBOOT.md). These keep configuration/output paths
consistent; loading is a separate board operation.

The [test guide](tests/README.md) documents peripheral elaboration, receive/
transmit primitive simulations and standalone aperture/STA tests. Peripheral
success does not establish full-SoC timing or working Linux networking.

For each final candidate check routed timing, clock/CDC diagnostics, the
sampling aperture, PHY negotiation, Linux interrupts, DHCP, bidirectional data
integrity and packet/error counters. Neither a link LED nor a single ping is
enough to certify continuous traffic, error rate or performance.
