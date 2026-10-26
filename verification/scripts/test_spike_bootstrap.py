#!/usr/bin/env python3
"""Exercise Spike bootstrap with real local Git submodules and a tiny C build."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPIKE_URL = "https://github.com/riscv-software-src/riscv-isa-sim"


class SpikeBootstrapTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="raptor-spike-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.upstream = self.root / "upstream"
        self.softfloat = self.root / "softfloat"
        self.work = self.root / "work"
        self.work.mkdir()
        self.env = os.environ.copy()
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            self.env.pop(key, None)
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "protocol.file.allow",
            "GIT_CONFIG_VALUE_0": "always",
            "GIT_CONFIG_KEY_1": f"url.{self.upstream.as_uri()}.insteadOf",
            "GIT_CONFIG_VALUE_1": SPIKE_URL,
            "GIT_AUTHOR_NAME": "Bootstrap test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Bootstrap test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        })
        for name in ("Makefile", "patch.sh"):
            shutil.copy2(ROOT / "nemu/tools/spike-diff" / name, self.work / name)

        self.run_command("git", "init", str(self.softfloat))
        (self.softfloat / "internals.h").write_text("#define SOFTFLOAT_VALUE 42\n")
        self.commit(self.softfloat)
        self.run_command("git", "init", str(self.upstream))
        self.run_command("git", "-C", str(self.upstream), "submodule", "add",
                         str(self.softfloat), "berkeley-softfloat-3")
        headers = self.upstream / "softfloat"
        headers.mkdir()
        (headers / "internals_upstream.h").symlink_to("../berkeley-softfloat-3/internals.h")
        (headers / "softfloat.h").write_text('#include "internals_upstream.h"\n')
        (headers / "probe.c").write_text(
            '#include "softfloat.h"\nint softfloat_probe(void) { return SOFTFLOAT_VALUE; }\n')
        (self.upstream / "riscv").mkdir()
        (self.upstream / "riscv/processor.h").write_text("} halt_request;\n")
        configure = self.upstream / "configure"
        configure.write_text("""#!/bin/sh
set -eu
cat > Makefile <<'EOF'
libsoftfloat.a: ../softfloat/probe.c ../softfloat/internals_upstream.h
	$(CC) -c ../softfloat/probe.c -o probe.o
	$(AR) rcs $@ probe.o
EOF
""")
        configure.chmod(0o755)
        self.commit(self.upstream)

    def run_command(self, *args, cwd=None):
        result = subprocess.run(args, cwd=cwd or self.work, env=self.env,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def commit(self, repo):
        self.run_command("git", "-C", str(repo), "add", ".")
        self.run_command("git", "-C", str(repo), "commit", "-m", "Fixture")

    def build(self, target="repo/build/libsoftfloat.a"):
        output = self.run_command("make", "-j2", target)
        self.assertNotIn("resetting jobserver mode", output)
        self.assertTrue((self.work / "repo/softfloat/internals_upstream.h").is_file())
        return output

    def test_fresh_clone_initializes_submodule_before_compile(self):
        self.build()
        self.assertTrue((self.work / "repo/build/libsoftfloat.a").is_file())

    def test_retry_previously_configured_incomplete_checkout(self):
        self.run_command("git", "clone", "--depth=1", SPIKE_URL, "repo")
        self.assertFalse((self.work / "repo/softfloat/internals_upstream.h").exists())
        build = self.work / "repo/build"
        build.mkdir()
        self.run_command("../configure", cwd=build)
        before = (build / "Makefile").stat().st_mtime_ns
        self.build()
        self.assertEqual((build / "Makefile").stat().st_mtime_ns, before)

    def test_header_target_prepares_transitive_includes(self):
        self.build("repo/softfloat/softfloat.h")
        self.assertFalse((self.work / "repo/build/Makefile").exists())

    def test_initialized_checkout_reuses_archive_without_network(self):
        self.build()
        archive = self.work / "repo/build/libsoftfloat.a"
        before = archive.stat().st_mtime_ns
        shutil.rmtree(self.upstream)
        shutil.rmtree(self.softfloat)
        self.build()
        self.assertEqual(archive.stat().st_mtime_ns, before)
        processor = (self.work / "repo/riscv/processor.h").read_text()
        self.assertEqual(processor.count("void take_trap_public"), 1)


if __name__ == "__main__":
    unittest.main()
