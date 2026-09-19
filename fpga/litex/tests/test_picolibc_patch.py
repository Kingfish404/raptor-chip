"""Keep the private libc compatibility patch normalized and idempotent."""
from pathlib import Path
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / "scripts"))
from patch_litex_picolibc import patch_common_mak, patch_libc_mk


class PicolibcPatchTest(unittest.TestCase):
    def test_source_paths_are_normalized_once(self):
        paths = [f"$(PICOLIBC_SRC_DIR)/newlib/libc/{directory}/{name}.c"
                 for directory in ("tinystdio", "stdlib", "stdio")
                 for name in ("strtoul", "strtoull")]
        with tempfile.TemporaryDirectory(prefix="raptor-chip-libc-", dir="/tmp") as tmp:
            target = Path(tmp) / "Makefile"
            target.write_text("\n".join(paths))
            self.assertTrue(patch_libc_mk(target))
            expected = "\n".join(paths).replace("/newlib/libc/", "/libc/")
            expected = expected.replace("/libc/stdio/", "/libc/tinystdio/")
            self.assertEqual(target.read_text(), expected)
            self.assertFalse(patch_libc_mk(target))

    def test_vendored_makefiles_remain_idempotent(self):
        software = LITEX.parents[1] / "third_party/enjoy-digital/litex/litex/soc/software"
        for relative, patch in (("common.mak", patch_common_mak),
                                ("libc/Makefile", patch_libc_mk)):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory(
                    prefix="raptor-chip-libc-", dir="/tmp") as tmp:
                target = Path(tmp) / "Makefile"
                original = (software / relative).read_bytes()
                target.write_bytes(original)
                patch(target)
                first = target.read_bytes()
                self.assertFalse(patch(target))
                self.assertEqual(first, target.read_bytes())
                self.assertEqual(original, (software / relative).read_bytes())


if __name__ == "__main__":
    unittest.main()
