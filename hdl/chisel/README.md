# Raptor instruction decoder generator

This directory generates instruction decoders for the hand-written
SystemVerilog core. It is not the processor's top-level implementation.

From the repository root:

```sh
make verilog
```

For direct use after setting up the repository environment:

```sh
make -C hdl/chisel verilog
make -C hdl/chisel test
make -C hdl/chisel elaborate-help
```

The [Makefile](Makefile) invokes `sbt "runMain Elaborate"` and writes to
`hdl/generated/`. Edit [decode.scala](src/main/scala/decode.scala) and
[riscv-inst.scala](src/main/scala/riscv-inst.scala), then regenerate; generated
SystemVerilog alone is not the source of truth.

Install a JDK compatible with the pinned sbt/Chisel toolchain and `sbt` through
the repository setup. Versions are defined in [build.sbt](build.sbt) and
[project/build.properties](project/build.properties). The Makefile prepends
`third_party/espresso/build` to PATH, overridable with `ESPRESSO_BIN_DIR`.
Generation updates the shared output directory, so do not interleave it with
another session's decoder generation or dependent builds.
