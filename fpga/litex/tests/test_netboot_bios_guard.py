"""Execute the private BIOS entry guard for both XLENs without board access."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
from prepare_private_bios import patch_netboot, patch_manual_boot


class NetbootGuardTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('cc'), 'requires host C compiler')
    def test_startup_cannot_dispatch_boot_with_either_config(self):
        for defined in (False, True):
            with self.subTest(defined=defined), tempfile.TemporaryDirectory(
                    prefix='raptor-chip-manual-startup-', dir='/tmp') as tmp:
                target = Path(tmp) / 'main.c'
                target.write_text('''static int boots;
void netboot(void) { boots++; }
void sdcardboot(void) { boots++; }
#ifndef CONFIG_BIOS_NO_BOOT
static void boot_sequence(void) { netboot(); sdcardboot(); }
#endif
int main(void) {
#ifndef CONFIG_BIOS_NO_BOOT
boot_sequence();
#endif
if (boots) return 1;
netboot(); sdcardboot(); /* Explicit commands remain functional. */
return boots != 2;
}
''')
                patch_manual_boot(target)
                binary = Path(tmp) / 'test'
                subprocess.run(['cc', '-Wall', '-Wextra', '-Werror',
                                *(['-DCONFIG_BIOS_NO_BOOT=0'] if defined else []),
                                str(target), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_manual_startup_guard(self):
        upstream = LITEX.parents[1] / 'third_party/enjoy-digital/litex/litex/soc/software/bios/main.c'
        with tempfile.TemporaryDirectory(prefix='raptor-chip-manual-boot-', dir='/tmp') as tmp:
            target = Path(tmp) / 'main.c'
            target.write_bytes(upstream.read_bytes())
            patch_manual_boot(target)
            first = target.read_bytes()
            patch_manual_boot(target)
            self.assertEqual(first, target.read_bytes())
            self.assertNotIn(b'#ifndef CONFIG_BIOS_NO_BOOT', first)
            self.assertEqual(first.count(b'#if 0 /* Raptor: boot only'), 2)
            target.write_text('int main(void) { boot_sequence(); }')
            with self.assertRaisesRegex(ValueError, 'automatic-boot BIOS'):
                patch_manual_boot(target)

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
                from netboot_names import name_bundle
                record = dict(xlen=bits, distro='buildroot' if bits == 32 else 'alpine',
                              kernel_version='6.18.51', files={'Image': 'a'*64})
                semantic = name_bundle(record) + '/boot.json'
                self.assertEqual(subprocess.run([str(binary), semantic], capture_output=True).returncode, 0)
                self.assertEqual(subprocess.run([str(binary), semantic.replace('6_18_51', '6.18.51')],
                                                capture_output=True).returncode, 7)


if __name__ == '__main__':
    unittest.main()
