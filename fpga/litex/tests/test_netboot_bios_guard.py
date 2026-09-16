"""Execute the private BIOS entry guard for both XLENs without board access."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
from prepare_private_bios import patch_netboot


class NetbootGuardTest(unittest.TestCase):
    def test_upstream_anchor_and_idempotence(self):
        upstream = LITEX.parents[1] / 'third_party/enjoy-digital/litex/litex/soc/software/bios/boot.c'
        with tempfile.TemporaryDirectory(prefix='raptor-chip-bios-guard-', dir='/tmp') as tmp:
            target = Path(tmp) / 'boot.c'
            target.write_bytes(upstream.read_bytes())
            patch_netboot(target)
            first = target.read_bytes()
            patch_netboot(target)
            self.assertEqual(first, target.read_bytes())
            self.assertIn(b'raptor_netboot_path_valid(params[0])', first)
            target.write_text('void netboot_changed(void) {}')
            with self.assertRaisesRegex(ValueError, 'unguarded BIOS'):
                patch_netboot(target)

    @unittest.skipUnless(shutil.which('cc'), 'requires host C compiler')
    def test_rejected_paths_never_reach_download(self):
        for bits in (32, 64):
            with self.subTest(bits=bits), tempfile.TemporaryDirectory(
                    prefix='raptor-chip-bios-guard-', dir='/tmp') as tmp:
                source = Path(tmp) / 'guard.c'
                source.write_text('''#include <stdio.h>
#include <string.h>
static int downloads;
void netboot(int nb_params, char **params)
{
    downloads++;
}
int main(int argc, char **argv) {
    netboot(argc - 1, argv + 1);
    return downloads ? 0 : 7;
}
''')
                patch_netboot(source)
                binary = Path(tmp) / 'guard'
                subprocess.run(['cc', '-std=gnu99', '-Wall', '-Wextra', '-Werror',
                                f'-D__riscv_xlen={bits}', str(source), '-o', str(binary)], check=True)
                good = f'raptor-netboot/rv{bits}/' + 'a' * 64 + '/boot.json'
                bad = [[], ['boot.json'], ['boot.bin'], [''],
                       [good.replace(f'rv{bits}', f'rv{96-bits}')],
                       [f'raptor-netboot/rv{bits}/../boot.json'],
                       [f'raptor-netboot/rv{bits}//boot.json'],
                       [good + '/extra'], [good, 'extra'],
                       [good.replace('/boot.json', '/other.json')]]
                for args in bad:
                    result = subprocess.run([str(binary), *args], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 7, args)
                    self.assertIn('Refusing', result.stdout)
                self.assertEqual(subprocess.run([str(binary), good], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
