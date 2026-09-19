#!/usr/bin/env python3
"""Copy and patch private LiteX software. Never edit or restore the checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from patch_litex_picolibc import patch_common_mak, patch_libc_mk


NETBOOT_GUARD = r'''
/* Raptor: never select a global or other-XLEN boot manifest. */
#if __riscv_xlen == 64
#define RAPT_NETBOOT_PREFIX "raptor-netboot/rv64/"
#elif __riscv_xlen == 32
#define RAPT_NETBOOT_PREFIX "raptor-netboot/rv32/"
#else
#error Unsupported Raptor netboot XLEN
#endif
static int raptor_netboot_path_valid(const char *path)
{
    const char *prefix = RAPT_NETBOOT_PREFIX;
    while (*prefix) {
        if (*path++ != *prefix++) return 0;
    }
    /* Bundle IDs are a single component; disallow traversal and aliases. */
    const char *start = path;
    while ((*path >= '0' && *path <= '9') ||
           (*path >= 'a' && *path <= 'z') ||
           (*path >= 'A' && *path <= 'Z') || *path == '-' || *path == '_')
        path++;
    return path != start && !strcmp(path, "/boot.json");
}
'''

NETBOOT_ENTRY = r'''
    if (nb_params != 1 || !raptor_netboot_path_valid(params[0])) {
        printf("Refusing ambiguous or wrong-XLEN netboot path.\n");
        printf("Use: netboot " RAPT_NETBOOT_PREFIX "<bundle-id>/boot.json\n");
        printf("Copy the exact command printed by the matching netboot serve target.\n");
        return;
    }
'''


def patch_netboot(path):
    source = path.read_text()
    if NETBOOT_GUARD in source and NETBOOT_ENTRY in source:
        return
    anchor = 'void netboot(int nb_params, char **params)\n{'
    if source.count(anchor) != 1:
        raise ValueError('unsupported LiteX netboot entry; refusing an unguarded BIOS')
    path.write_text(source.replace(anchor, NETBOOT_GUARD + '\n' + anchor + NETBOOT_ENTRY))


def patch_manual_boot(path):
    """Disable startup dispatch, not the interactive boot commands in boot.c."""
    source = path.read_text()
    anchor = '#ifndef CONFIG_BIOS_NO_BOOT'
    guard = '#if 0 /* Raptor: boot only through explicit BIOS console commands. */'
    if source.count(guard) == 2 and anchor not in source:
        return
    if source.count(anchor) != 2 or guard in source:
        raise ValueError('unsupported LiteX startup sequence; refusing an automatic-boot BIOS')
    path.write_text(source.replace(anchor, guard))


def prepare(source, dest):
    if dest.resolve().is_relative_to(source.resolve()):
        raise ValueError("private software must not be inside the LiteX source tree")
    software = dest / "litex/soc/software"
    shutil.copytree(source / "litex/soc/software", software, dirs_exist_ok=True)
    patch_common_mak(software / "common.mak")
    patch_libc_mk(software / "libc/Makefile")
    patch_netboot(software / "bios/boot.c")
    patch_manual_boot(software / "bios/main.c")
    return software


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("boot_arguments", nargs="*")
    args = parser.parse_args()
    prepare(args.source, args.destination)
    if args.boot_arguments:
        subprocess.run([sys.executable, str(Path(__file__).with_name("patch_litex_sdcard_linux_override.py")),
                        str(args.destination), *args.boot_arguments], check=True)


if __name__ == "__main__":
    main()
