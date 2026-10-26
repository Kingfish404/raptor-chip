# Physical design

`openroad/` places and routes the mapped module netlists produced by
[synth/yosys](../synth/yosys/) with OpenROAD. It currently enables NanGate45.
The module registry, PDK selection, and option names are shared with the
synthesis flow; see [synth/README.md](../synth/README.md) for the full
description, metrics, and limitations.

```sh
source env.sh
make -C layout doctor PDK=nangate45
make -C layout pnr MODULE=fqu PDK=nangate45 RAPT_CONFIG=small CLK_FREQ_MHZ=100
make -C layout viz MODULE=fqu PDK=nangate45 RAPT_CONFIG=small CLK_FREQ_MHZ=100
make -C layout summary PDK=nangate45 RAPT_CONFIG=small MODULES_TO_RUN="fqu cmu"
```

`make -C layout pnr` first rebuilds the matching `synth/yosys` netlist with
`SRAM_MODE=flops`. Outputs go to `layout/openroad/build/`.
