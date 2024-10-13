# generates configuration files for Verilog source and app

#
# if file changed run `configuration-generate.py`
# if `RAM_ADDR_WIDTH` is modified recompile `os`
#
RAM_FILE = "app/os.mem" # path to initial RAM content
RAM_ADDR_WIDTH = 14    # 2^14*4 (65536) bytes of RAM
UART_BAUD_RATE = 9600  # 9600 baud, 8 bits, 1 stop bit, no parity


# calculate memory addresses based on RAM_ADDR_WIDTH
# subtract 4 to get the top address for the stack (skipping LEDS and UART)
top_address = hex(2**RAM_ADDR_WIDTH - 4)

with open('app/os_start.S', 'w') as file:
    file.write('# generated - do not edit\n')
    file.write('.global _start\n')
    file.write('_start:\n')
    file.write('    li sp, {}\n'.format(hex(2**(RAM_ADDR_WIDTH+2) - 4)))
    file.write('    jal ra, run\n')

with open('app/os_config.h', 'w') as file:
    file.write('// generated - do not edit\n')
    file.write(
        'volatile unsigned char *leds = (unsigned char *){};\n'.format(hex(2**(RAM_ADDR_WIDTH+2) - 1)))
    file.write(
        'volatile unsigned char *uart_out = (unsigned char *){};\n'.format(hex(2**(RAM_ADDR_WIDTH+2) - 2)))
    file.write(
        'volatile unsigned char *uart_in = (unsigned char *){};\n'.format(hex(2**(RAM_ADDR_WIDTH+2) - 3)))

with open('src/Config.v', 'w') as file:
    file.write('`ifndef VERILATOR_SIM\n')
    file.write('// generated - do not edit\n')
    file.write('`define RAM_FILE \"../{}\"\n'.format(RAM_FILE))
    file.write('`define RAM_ADDR_WIDTH {}\n'.format(RAM_ADDR_WIDTH))
    file.write('`define UART_BAUD_RATE {}\n'.format(UART_BAUD_RATE))
    file.write('`endif\n')

print("generated: src/Config.v, app/os_config.h, app/os_start.S")
