# Native Ethernet ABI v1

The native RK controller occupies `0x18000000..0x1800ffff`, inside the CPU's
existing uncached peripheral PMA. This address is a platform choice; the device
tree identifies the interface as `raptor,native-ethernet-v1`. The bus accepts
aligned, single-beat 32-bit accesses and preserves the appropriate RV64 byte
lanes. Registers require all four write strobes; packet RAM supports byte
strobes. Unsupported AXI widths, alignment and bursts return DECERR.

| Offset | Register | Behavior |
| --- | --- | --- |
| `0x00` | ID | `0x524e4554` (`RNET`) |
| `0x04` | Version | `1` |
| `0x08` | Control | Bit 0 enables packet queues/MAC; MDIO remains accessible when disabled |
| `0x0c` | Status | Bit 0 RX pending, bit 1 TX ready, bit 2 PHY/MAC clocks ready |
| `0x10` | IRQ mask | Bit 0 RX, bit 1 TX |
| `0x14` | IRQ status | RX is level-sensitive; TX is sticky and write-one-to-clear |
| `0x18` | RX descriptor | Bits 18:16 slot, bits 15:0 frame length; zero when empty |
| `0x1c` | RX pop | Write bit 0 to return the head slot after reading its data |
| `0x20` | TX length | Commit a complete 14–1536 byte frame; rejected if busy or out of range |
| `0x28` | RX good | Complete valid frames accepted into the queue |
| `0x2c` | RX errors | Invalid, runt or oversized frames rejected |
| `0x30` | RX overflow | Whole frames discarded because all eight slots were occupied |
| `0x34` | TX complete | Packet payloads consumed by the MAC |
| `0x38` | TX rejected | Invalid or duplicate commits |
| `0x3c` | RX bad FCS | MAC CRC-error counter |
| `0x40` | MDIO output | Bit 0 MDC, bit 1 output enable, bit 2 output value |
| `0x44` | MDIO input | Bit 0 input value |
| `0x2000..0x27ff` | TX SRAM | One 2048-byte slot; writes while busy are ignored |
| `0x4000..0x7fff` | RX SRAM | Eight 2048-byte slots |

Lengths exclude preamble and FCS. The vendored CVA6 MAC retains FCS on its
internal receive stream; `RxFcsBytes=4` excludes it from published descriptors.
TX pads short Ethernet frames to 60 bytes and generates FCS. The maximum Linux
MTU is 1500, including normal VLAN headroom within the hardware frame limit.

RX publishes a slot only after the final byte passes error/length checks. A
frame that starts while full is discarded in its entirety, even if software
frees a slot mid-frame. Registered Gray pointers transfer ownership across clock
domains, and descriptors/data remain stable until pop. RX bytes are assembled
into 32-bit SRAM writes so the 16 KiB array infers four RAMB36s.

TX software writes the entire buffer before committing its length. A toggle
handshake transfers ownership to the 125 MHz MAC and back to the CPU. SRAM reads
are synchronous with lookahead; AXI-stream data remains stable under backpressure.
Completion can precede the final wire FCS/IFG; the MAC backpressures the next
packet until it can accept it. No DMA or cache maintenance is involved.

Disabling the controller or losing its clocks clears packet ownership and
hardware counters. Reset asserts asynchronously and releases locally in each
physical clock domain. MDIO and interrupt-mask registers remain CPU-accessible.
The driver masks IRQs and quiesces NAPI before a software reset. `ethtool -S`
exposes the raw hardware counters; those counters describe the current enable/
clock epoch, while normal software packet counters survive interface restarts.

PHY initialization uses upstream Linux MDIO bitbang and RTL8211F support with
`phy-mode = "rgmii-txid"`. Only 1000BASE-T full duplex is advertised. RGMII RX
uses an inverted MMCM capture clock, fixed 100 ps input delays, and explicit
alignment of adjacent IDDRE1 low/high samples. TX125 and IDELAY-ref300 share the
board's main MMCM; a separate RX MMCM follows the PHY. Including MIG, the native
DDR design uses three MMCM sites. The MIG debug hub uses the core clock directly
so it does not occupy another MMCM beside the RGMII RX pins.

The MAC source and its MIT license headers are preserved in `vendor/ethernet/`;
`provenance.json` records its upstream revision, local origin and file hashes.
