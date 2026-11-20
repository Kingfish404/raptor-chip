# Raptor RQIO Direct FPGA / RTL to QEMU I/O & DMA Bridge

`raptor_qemu_bridge.py` connects the Raptor RVA23S64 softcore (on FPGA via
[`rapt_qemu_io_bridge.sv`](../../fpga/common/rtl/rapt_qemu_io_bridge.sv) or in Verilator
simulation via [`mmio-qemu-bridge.cc`](../../sim/csrc/mem/mmio-qemu-bridge.cc)) directly
to upstream `qemu-system-riscv64` (or the self-contained `builtin` device model).

## Memory Map & Interrupts

| Device | Raptor Physical Address | Size | PLIC IRQ (FPGA / Sim) |
| --- | --- | --- | --- |
| `VirtIO-Blk` (`virtio,mmio` v2) | `0x10001000` | `4 KiB` | `3` / `1` |
| `VirtIO-Net` (`virtio,mmio` v2) | `0x10002000` | `4 KiB` | `2` / `2` |
| `PCIe ECAM` (`pci-host-ecam-generic`) | `0x41000000` | `16 MiB` | INTx `11..14` |
| `SDHCI` (`arasan,sdhci-8.9a` v3.00) | `0x42000000` | `4 KiB` | `4` / `4` |
| `PCIe 32-bit MMIO` (`NVMe` BAR0) | `0x50000000` | `256 MiB` | `11` (`INTA`) |

## Transports & Backends

- `--transport raw-eth --iface <host-nic>`: L2 raw Ethernet tunnel using IEEE
  local experimental EtherType `0x88B5`. Multiplexed alongside guest Ethernet
  traffic on the same physical RJ45 port by `rapt_eth_rqio_mux.sv`.
- `--transport serial --device /dev/ttyUSBx`: SLIP (`0xC0`/`0xDB`) + CRC-16-CCITT
  byte-stream fallback over UART/JTAG-UART.
- `--transport unix --socket /tmp/raptor-rqio.sock`: Local Unix stream socket
  for Verilator simulation (`--qemu-io-socket=/tmp/raptor-rqio.sock`).
- `--backend qemu`: Spawns stock `qemu-system-riscv64 -machine virt` with a
  self-relocating RV64I shared-memory proxy stub (`memory-backend-file,share=on`),
  forwarding MMIO, PLIC pending interrupts, and VirtIO/NVMe DMA descriptors
  directly to QEMU's upstream `virtio-blk-device`, `nvme`, and `sdhci-pci`.
- `--backend builtin`: Self-contained OASIS VirtIO 1.2 (`VirtIO-Blk`,
  `VirtIO-Net`), SDHCI v3.00 (SDMA + ADMA2), and PCIe ECAM + NVMe 1.4 backend.

## Usage Examples

```sh
# Run unit and live qemu-system-riscv64 DMA integration tests:
python3 -m unittest discover -s tools/qemu_io_bridge -p 'test_*.py' -v

# Connect FPGA board over host Ethernet interface to stock QEMU:
sudo python3 tools/qemu_io_bridge/raptor_qemu_bridge.py \
  --transport raw-eth --iface enp3s0 --backend qemu \
  --disk rootfs.ext4 --nvme data.ext4

# Connect Verilator simulation over Unix socket to stock QEMU:
python3 tools/qemu_io_bridge/raptor_qemu_bridge.py \
  --transport unix --socket /tmp/raptor-rqio.sock --backend qemu \
  --blk-irq 1 --disk rootfs.ext4 --nvme data.ext4
```
