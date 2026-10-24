#!/usr/bin/env python3
"""Cross-build native Ubuntu profiling binaries from existing benchmark sources."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
BENCHMARKS = """
    aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum nettle-aes nettle-sha256
    nsichneu picojpeg qrduino sglib-combined slre statemate tarfind ud wikisort xgboost
""".split()


def build(output, cross):
    output.mkdir(parents=True, exist_ok=True)
    core = REPO / "abstract-machine/app/am-kernels/benchmarks/coremark_eembc/src"
    embench = REPO / "app/build/src/embench-iot"
    header = REPO / "app/benchmarks/coremark/portme"
    cc = cross + "gcc"
    flags = ["-O2", "-g", "-march=rv64gc", "-mabi=lp64d", "-fno-pie", "-no-pie",
             "-std=gnu99", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-unused-variable",
             "-Wno-sign-compare", "-Wno-unused-but-set-variable"]
    commands, inputs = [], set()

    def compile_one(name, sources, extra, headers):
        sources = [Path(p) for p in sources]
        inputs.update(sources + list(headers))
        command = [cc, *flags, "-I" + str(HERE), *extra,
                   *map(str, sources), "-lm", "-o", str(output / name)]
        subprocess.run(command, check=True)
        commands.append(command)
        print("BUILT", name, flush=True)

    core_sources = [core / name for name in
                    ("core_list_join.c", "core_main.c", "core_matrix.c", "core_state.c", "core_util.c")]
    compile_one("coremark", core_sources + [HERE / "core_portme.c", HERE / "profile.c"],
                ["-I" + str(core), "-I" + str(header), "-DITERATIONS=64", "-DHAS_FLOAT=1",
                 "-DPERFORMANCE_RUN=1", '-DCOMPILER_FLAGS="' + " ".join(flags) + '"',
                 '-DMEM_LOCATION="Linux static arrays"'],
                [core / "coremark.h", header / "core_portme.h", HERE / "profile.h"])
    for name in BENCHMARKS:
        directory = embench / "src" / name
        sources = sorted(directory.glob("*.c"))
        if not sources:
            raise RuntimeError("Missing Embench sources: " + str(directory))
        compile_one(name, sources + [embench / "support/beebsc.c", HERE / "embench_main.c", HERE / "profile.c"],
                    ["-I" + str(directory), "-I" + str(embench / "support"),
                     "-DGLOBAL_SCALE_FACTOR=1", '-DBENCH_NAME="' + name + '"'],
                    [*directory.glob("*.h"), *embench.glob("support/*.h"), HERE / "profile.h"])
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    manifest = {
        "compiler": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
        "flags": flags, "coremark_iterations_default": 64, "embench_global_scale_factor": 1,
        "embench_warmup_heat": 1, "commands": commands,
        "sources": {str(p.relative_to(REPO)): sha(p) for p in sorted(inputs)},
        "binaries": {name: sha(output / name) for name in ["coremark", *BENCHMARKS]},
        "source_revisions": {
            name: subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
            for name, path in [("embench", embench), ("am-kernels", core)]},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cross", default="riscv64-linux-gnu-")
    args = parser.parse_args()
    build(args.output.resolve(), args.cross)
