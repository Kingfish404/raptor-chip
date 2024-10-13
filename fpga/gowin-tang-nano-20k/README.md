# Tang Nano 20K (Gowin GW2AR-18) RISC-V

## Hardware
- __[Tango Nano 20K-Aliexpress](https://www.aliexpress.com/item/1005005581148230.html)__ (38.77 $) or [Tang Nano 20K FPGA-淘宝网](https://item.taobao.com/item.htm?id=717932028073) (169 RMB)
  - or [Tang Nano 9K FPGA-淘宝网](https://item.taobao.com/item.htm?id=666055424174) (89-108 RMB)

## For ysyx chips

`cat` all your related `*.v` or `*.sv` file to `src/ysyx.v`, put the `*.vh` or `*.svh` to `src/include`.

## Configuration
`configuration.py` contains data used by `generate-config.py` to generate:
  - `src/Config.v`, `os/os_config.h`, `os/os_start.S`

## Simulation
- Using Verilator: [Veripool](https://www.veripool.org/verilator/)
- build and run simulation: `make sim`

## SYN and PNR with Open-Source FPGA Toolchain
- Tools by [YosysHQ](https://yosyshq.net/):
  - [YosysHQ/nextpnr: nextpnr portable FPGA place and route tool](https://github.com/YosysHQ/nextpnr)
  - [YosysHQ/apicula: Project Apicula 🐝: bitstream documentation for Gowin FPGAs](https://github.com/YosysHQ/apicula)
- Synthesis: `make syn`
- Place and route: `make pnr`

## SYN and PNR with Gowin EDA
- connect fpga board, open EDA, click `Run all`, program device using `openFPGALoader`
  - [GOWIN EDA | GOWIN Semiconductor](https://www.gowinsemi.com/en/support/home/) or [广东高云半导体科技股份有限公司](https://www.gowinsemi.com.cn/faq.aspx) (the latter is login-free to download the educational version)
```yaml
# Gowin FPGA Designer (version 1.9.9.03) GUI settings
MENU > Project > Set Device:
  - Filter: [Series: GW2AR, Package: QFN88, Speed: C8/17, Device Version: C]
  - select: GW2AR-LV18QN88C8/I7
MENU > Project > Configuration > Global > Constraints:
  - Custom: 27.000
MENU > Project > Configuration > Synthesize > General:
  - General:
    - include Path: \gowin_tang-nano-20k\src\include
  - GowinSynthesis:
    - Verilog Language: SystemVerilog2017
```

## Running and testing
- Tools:
  - [openFPGALoader: universal utility for programming FPGA — openFPGALoader: universal utility for programming FPGA latest documentation](https://trabucayre.github.io/openFPGALoader/)
- Program device:
  - `make program_flash` or `openFPGALoader -b tangnano20k -f impl/syn/fpga.fs` for open-source tools
  - `make program_sdram` or `openFPGALoader -b tangnano20k impl/syn/fpga.fs` for open-source tools
- Using usb to connect the card via `tty` (e.g. `/dev/ttyUSB1`), list of `tty` tools:
  - Serial Monitor: [Serial Monitor - Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=ms-vscode.vscode-serial-monitor) (vscode extension)
  - minicom: [Debian -- Details of package minicom in sid](https://packages.debian.org/sid/minicom) (`brew install minicom`)
  - CoolTerm (GUI): [Roger Meier's Freeware](https://freeware.the-meiers.org/) (open web page, download, install)
- Connect with serial terminal at 9600 baud, 8 bits, 1 stop bit, no parity
  - ` minicom -b 9600 -D /dev/tty.usbserial-20230306211`
- Button S1 is reset, click it to restart and display the prompt (does not reset ram)

```shell
.
├── app # source of initial program
└── src # Verilog source  
fpga.*  # files associated with Gowin EDA
```

## References & Thanks

- [calint/tang-nano-20k--riscv](https://github.com/calint/tang-nano-20k--riscv)
- [Tang Nano 20K - Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
- [GW2AR-LV18QN88C8/I7](http://www.gowinsemi.com.cn/prod_view.aspx?TypeId=10&FId=t3:10:3&Id=167#GW2AR)
- [How to config MS5351](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/example/unbox.html#pll_clk)
