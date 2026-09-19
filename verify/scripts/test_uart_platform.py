#!/usr/bin/env python3
"""UART model/DTB contracts, isolated from shared simulator/NEMU configuration."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]


class UARTPlatformTest(unittest.TestCase):
    def test_production_models_rv32_rv64(self):
        kconfig = (ROOT/'nemu/src/device/Kconfig').read_text()
        irq = re.search(r'config SERIAL_PLIC_IRQ\s+int[^\n]+\s+default (\d+)', kconfig)[1]
        with tempfile.TemporaryDirectory(prefix='raptor-chip-uart-', dir='/tmp') as tmp:
            work = Path(tmp)
            (work/'generated').mkdir()
            (work/'generated/autoconf.h').write_text('')
            (work/'verilated.h').write_text('#pragma once\nclass VerilatedContext { public: void gotFinish(bool) {} unsigned long long time() { return 0; } };\n')
            (work/'device').mkdir()
            # Only NEMU's registration and environment are stubbed; device code is included unchanged.
            nemu = work/'nemu'
            (nemu/'device').mkdir(parents=True)
            (nemu/'utils.h').write_text('''#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#define panic(...) abort()
#ifdef CONFIG_ISA64
typedef uint64_t word_t;
#else
typedef uint32_t word_t;
#endif
typedef word_t paddr_t;
#define CONFIG_SERIAL_INPUT_FIFO 1
#define CONFIG_SERIAL_MMIO 0x3f8
#define CONFIG_SERIAL_MMIO_US16550 0x10000000
#define CONFIG_SERIAL_PLIC_IRQ '''+irq+'\n')
            (nemu/'device/map.h').write_text('''#include <utils.h>
typedef void (*io_callback_t)(uint32_t, int, bool);
uint8_t *new_space(int);
void add_mmio_map(const char *, paddr_t, void *, uint32_t, io_callback_t);
''')
            for bits in (32,64):
                for model in ('sim','nemu'):
                    source = ROOT/'app/tests/host'/('mmio_uart_platform.cc' if model=='sim' else 'nemu_uart_platform.c')
                    binary = work/f'{model}{bits}'
                    command = ['c++' if model=='sim' else 'cc', '-O1', '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections']
                    command += ['-std=c++17', '-I'+str(work), '-I'+str(ROOT/'sim/include')] if model=='sim' else ['-std=c11', '-I'+str(nemu)]
                    if bits==64: command += ['-DCONFIG_ISA64']
                    compiled = subprocess.run(command+[str(source),'-o',str(binary)],capture_output=True,text=True)
                    self.assertEqual(compiled.returncode,0,compiled.stderr)
                    result = subprocess.run([str(binary)],input=b'',capture_output=True,check=True)
                    self.assertIn(b'PASS:',result.stdout)
                    self.assertEqual(result.stderr,b'AA')

    def test_all_canonical_uart_dtbs_and_linux_presets(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-uart-dtb-',dir='/tmp') as tmp:
            checked=0
            for source in sorted((ROOT/'linux/dts').glob('*.dts')):
                output=Path(tmp)/(source.stem+'.dtb')
                subprocess.run(['dtc','-q','-I','dts','-O','dtb','-i',str(source.parent),'-o',str(output),str(source)],check=True,capture_output=True)
                nodes=subprocess.check_output(['fdtget','-l',str(output),'/soc'],text=True).split()
                for node in nodes:
                    compatible=subprocess.run(['fdtget',str(output),'/soc/'+node,'compatible'],capture_output=True,text=True)
                    if 'ns16550' not in compatible.stdout: continue
                    irq=subprocess.check_output(['fdtget','-t','i',str(output),'/soc/'+node,'interrupts'],text=True).strip()
                    self.assertEqual(irq,'10',str(source));checked+=1
            self.assertGreaterEqual(checked,8)
        for preset in (ROOT/'nemu/configs').glob('riscv*linux_defconfig'):
            self.assertIn('CONFIG_SERIAL_PLIC_IRQ=10',preset.read_text(),str(preset))

if __name__=='__main__': unittest.main()
