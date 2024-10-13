# Docs

## Technical Specifications: GW2AR-LV18QN88C8/I7

| Key                         | value    |
| --------------------------- | -------- |
| Logic units(LUT4)           | 20736    |
| Flip-Flop(FF)               | 15552    |
| Shadow SRAM (S-SRAM)(bits)  | 41472    |
| Block SRAM (B-SRAM)(bits)   | 828K     |
| Numbers of B-SRAM           | 46       |
| 32bits SDR SDRAM            | 64M bits |
| Numbers of 18x18 Multiplier | 48       |
| Numbers of PLLs             | 2        |
| I/O Bank                    | 8        |

|       Item        |          Detail          |               Others               |
| :---------------: | :----------------------: | :--------------------------------: |
|     FPGA Chip     |   GW2AR-LV18QN88C8/I7    |          **Table Above**           |
| Onboard debugger  |          BL616           |           JTAG for FPGA            |
| Onboard debugger  |          BL616           |        USB to UART for FPGA        |
| Onboard debugger  |          BL616           | USB to SPI for FPGA communication  |
| Onboard debugger  |          BL616           | Control MS5351 generate frequency  |
|  Clock generator  |          MS5351          |  Provide extra 3 clocks for FPGA   |
| Display interface | 40Pins RGB lcd connector |                                    |
| Display interface |      HDMI interface      |                                    |
|        LED        |            6             |      Low voltage level enable      |
|      RGB LED      |            1             |               WS2812               |
|     User key      |            2             |                                    |
|   TF Card Slot    |            1             |                                    |
|   PCM Amplifier   |            1             |    MAX98357A，for audio driving    |
|      Storage      |      64Mbits Flash       |         To save bitstream          |
|       Size        |    22.55mm x 54.04mm     | Visit 3D file for more information |
