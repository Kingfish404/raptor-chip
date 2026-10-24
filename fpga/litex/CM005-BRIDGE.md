# CU08 CM005 A/B bridge

`cm005_bridge.py` builds a standalone two-port gigabit Ethernet bridge for
MLK-CU08-KU15P, FMC_C, CM005 ports A and B. It contains no Raptor CPU or DDR
controller. Programming it replaces the currently running KU15P design until
another bitstream is loaded; it does not write configuration flash.

Connect the server's dedicated shared-network interface to A and the
RK-XCKU5P-F Ethernet port to B. The CM005 has independent PHYs, so this FPGA
forwarding logic is required for the two connectors to communicate. The host
still supplies DHCP, DNS and NAT. The bridge does not configure host networking.

## LiteX CPU and forwarding

CU08 `mlk_cu08_ku15p.py` and Make builds enable `WITH_CM005_BRIDGE=1` by
default, including CPU builds without `WITH_ETHERNET`. The two physical PHYs,
MACs and frame queues coexist with Raptor, MIG DDR, SD and UART. Forwarding
starts in hardware and does not require Linux or BIOS to configure a bridge.
It shares the SoC reset; FPGA reprogramming or a whole-SoC reset briefly
interrupts the link.

With `WITH_ETHERNET=1`, the CPU becomes a third Ethernet endpoint. Each ingress
frame is copied to the other two ports, with no MAC learning. Each directed
path has an independent eight-slot frame queue, and each egress arbitrates
whole packets. A stopped CPU receiver or congested output drops only its own
copies. The CPU NIC retains the LiteEth SRAM/IRQ/CSR interface and sees shared
segment traffic; its receive-drop counter can increase while BIOS is idle.
The virtual `ethphy_crg_reset` compatibility register does not reset either
physical link. Physical reset/MDIO diagnostics remain under `phy_a`/`phy_b`.
The CPU MAC also exports the `preamble_crc` capability CSR so BIOS leaves
Ethernet preamble/FCS handling to the physical MACs. Its presence is part of
the LiteEth software ABI, even though this CPU port has no separate wire PHY.

The bridge requires FMC_C A/B at 1000 Mb/s and supports MIG or integrated SRAM.
Other FMC wiring, 100 Mb/s and LiteDRAM require explicit
`WITH_CM005_BRIDGE=0` (Python: `--without-cm005-bridge`), which removes the
KU5P transit path. The fixed CU08 netboot profiles keep forwarding enabled;
the RK profile continues to use its own onboard NIC.

At system clocks below 50 MHz, an extra 2 KiB packet buffer in each 125 MHz
TX domain waits for a complete frame before transmission and retains the
inter-frame gap. This prevents mid-frame starvation with the existing
10/30 MHz defaults. Sustained throughput remains limited by the system clock;
this is not a line-rate claim for those configurations. At 50 MHz the established
PHY/MAC pipeline is retained. Every frequency/configuration still requires its
own routed timing pass before loading.

Example CPU/DDR/forwarding build with a manual BIOS prompt and CPU NIC:

```sh
make -C fpga/litex fpga-build FPGA_BOARD=mlk_cu08_ku15p FPGA_AUTO_DETECT=0 \
    VARIANT=linux64 RAPT_CONFIG=small SYS_CLK=50000000 BOOT_MODE=bios \
    LINUX_FPGA_PROFILE=0 WITH_MIG=1 WITH_SDCARD=1 WITH_ETHERNET=1
```

`LINUX_FPGA_PROFILE=0` selects ordinary BIOS without embedding a Linux payload;
Raptor still uses its RV64 Linux-capable configuration. For the established
Linux/TFTP workflow, use `make fpga-netboot-rv64-build RAPT_CONFIG=small`
(or `rv32`). Preserve the same profile arguments when loading, and select the
KU15P JTAG adapter explicitly when KU5P is also connected.

## Datapath and diagnostics

Each direction has a 32-bit, 50 MHz store-and-forward queue with eight 2 KiB
slots. A descriptor becomes visible only after a complete frame passes error
and length checks. A transmitting slot stays occupied through the final beat.
Overflow drops a complete arriving frame. The configured maximum frame length
is 1536 bytes excluding FCS, including the Ethernet header and any VLAN tags.
The MAC checks incoming FCS and regenerates outgoing FCS. Standard minimum
frames are checked and padded by LiteEth.

Port A uses the existing 625 MHz DDR oversampling receiver and its calibrated
lane/control offsets. Port B uses G9, a global-clock-capable input, and native
RGMII capture, including both RX control edges. The native receive data/control
delay is 650 ps; routed setup and hold checks cover both DDR edges. The MAC and
PHY TX clocks use separate phase-aligned dividers from each port's 250 MHz source,
keeping MAC loads off the PHY launch clocks. Each port has its own PHY clock
pair and MMCM near its I/O region (A: X2Y8; B: X2Y2). B's MAC uses the same
local source as its PHY; the existing asynchronous FIFOs cross to the system
domain. Both PHYs advertise 1000 Mb/s
full duplex only. A/B share the physical E8 reset gate; either reset request
restarts both PHYs and clears the MAC crossings and frame queues.

UARTBone at 115200 baud exposes both MDIO interfaces, MAC CRC/preamble counts,
and each direction's accepted, forwarded, dropped, error and occupied-slot
counts. For an already programmed board:

```sh
fpga/litex/.venv/bin/python fpga/litex/scripts/cm005_bridge_probe.py \
  --port /dev/ttyUSB1 --csr-csv /path/to/matching-build/csr.csv \
  --counters-only --output /tmp/cm005-bridge-status.json
```

The probe checks and restores the UARTBone scratch register. Omit
`--counters-only` to also read PHY registers at address zero; `--scan` searches
all Clause-22 addresses. Hardware counter reads have passed, but UARTBone reads
can intermittently time out, including with `--counters-only`. The current
MDIO diagnostic has not returned a valid PHY ID; an empty `phys` result does
not establish PHY identification or link status.
Use the UART associated with the KU15P download cable and
close other consoles first. There is no Linux console in this bitstream.

## Pins and timing

Port A's mapping and sampling contract are documented in
[CM005-FMC-C.md](CM005-FMC-C.md). Port B uses the CM005 schematic's FMC contacts
and the CU08 baseboard FMC_C schematic, in ascending data-bit order:

| Signal | FMC contact | FPGA pin |
| --- | --- | --- |
| RX_CLK / TX_CLK | G2 / H35 | G9 / H13 |
| RX_CTL | G25 | G11 |
| RXD[0:3] | G27 G28 G30 G31 | K11 J11 D13 C13 |
| TX_CTL | H28 | F13 |
| TXD[0:3] | H29 H31 H32 H34 | E13 C12 B12 J13 |
| MDC / MDIO | H25 / H26 | L12 / K12 |
| Shared A/B reset gate | G16 | E8 |

All Ethernet I/O uses LVCMOS18. The bridge shares the SoC's constraints through
`cm005_timing.py`. TX's 125 MHz forwarded waveform remains `{2, 6}` ns relative
to the divided-data clock. It is described using rising master edges plus a
2 ns shift so Vivado 2026.1 can propagate source latency after mapping ODDRE1
to OSERDESE3. The older falling-edge description produced TIMING-5/36 and zero
capture-clock latency. External setup/hold budgets remain 1.2 ns; no false path
or relaxed I/O timing is used to hide these checks.

Port A uses drive 8 with FAST slew on TX data/control, and drive 6 with SLOW
slew on its forwarded clock. Port B uses drive 12 with MEDIUM slew on TX
data/control, and drive 12 with FAST slew on its clock. These supported I/O
settings balance the measured output delays. F13 (B TX control) is declared
unavailable during calibration: the shared PHY reset and all MAC resets wait
for IDELAY readiness before releasing either port.

## Build and validation

Run FPGA synthesis and implementation from a checkout with Vivado available,
verified source/dependency hashes and an isolated output directory:

```sh
fpga/litex/.venv/bin/python fpga/litex/cm005_bridge.py \
  --output-dir /path/to/isolated-output --build
```

Omitting `--build` only generates the design. Inspect routed setup/hold, clock
coverage, DRC and clock-methodology reports, and the A-port sampling-aperture
report before loading. A PHY link or simulation pass does not establish
hardware forwarding, netboot, Internet access or sustained error-free traffic.

The frame queue and bidirectional MAC regression is
`fpga/litex/tests/test_cm005_bridge.py`. It covers partial final words, maximum
frames, backpressure, overflow, early errors, bad CRC, reset clearing and
simultaneous opposite-direction traffic through the real MAC/CDC pipelines.
The full CM005 regression suite and production primitive simulations remain
applicable. Record actual board/network acceptance separately from these
functional and timing checks.

## KU5P endpoint PHY setup

The native RGMII receive timing contract requires the RTL8211F's internal RX
clock delay to be disabled while retaining the TX delay. Linux configures this
through `phy-mode = "rgmii-txid"`. For BIOS builds without automatic PHY setup,
read/save MDIO page register 31, select page `0xd08`, clear only bit 3 of RXCR
register `0x15`, read back the setting, and restore the saved page. Preserve all
other bits and confirm TXCR register `0x11` bit 8 remains enabled. Reapply after
PHY reset; do not copy a complete register value from another board.

The manual BIOS uses local/server IPs `192.168.1.50` / `192.168.1.100`.
A temporary server-side address on the FPGA downlink can serve TFTP; remove it
when finished. Linux uses the shared LAN's DHCP, DNS and gateway independently.
Record the matching bitstream, routed constraints, PHY settings, payload hashes
and network/error-counter deltas for each board acceptance in ignored local
records. Short transfer checks do not establish line-rate or BER performance.
