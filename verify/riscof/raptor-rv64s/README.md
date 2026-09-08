# RV64 supervisor ACT4 验证配置

这是当前 RTL 的特权测试投影，不是完整 RVA22S64 合规声明。保留既有
`raptor-rv64gc` M-mode 配置，本配置开放 S/U、Sv39/Svade 等验证所需能力。

首次验证集合为上游 `Svade` 目录中的 Sv39 S-mode/U-mode 两例；Sv32、Sv48、
Sv57 因目标配置不支持而排除。测试源码不修改，保留上游 NORUN 标签。
Sail 0.13.1 生成期望签名，DUT 执行自检查 ELF，无需 NEMU 差分。

```sh
make -C verify riscof-gen ISA=rv64 \
  ACT4_CONFIG="$PWD/verify/riscof/raptor-rv64s/test_config.yaml" \
  ACT4_EXTENSIONS=Svade EXCLUDE_EXTENSIONS= \
  ACT4_ELF_DIR=/tmp/raptor-supervisor/riscof/raptor-rv64s/elfs \
  BUILD_DIR=/tmp/raptor-supervisor

verify/riscof/riscv-arch-test/.venv/bin/python verify/scripts/act4_selection_audit.py \
  --repo verify/riscof/riscv-arch-test \
  --config verify/riscof/raptor-rv64s/test_config.yaml \
  --extensions-file /tmp/raptor-supervisor/riscof/raptor-rv64s/extensions.txt \
  --extensions Svade --exclude '' --output /tmp/raptor-supervisor/selection.json

python3 verify/scripts/run_act4.py --trap-on-ebreak --npc-bin /path/to/frozen/rv64-npc-sim \
  --mrom-img "$PWD/sim/csrc/mem/mrom-data/build/mrom-data.bin" --jobs 2 \
  --log-dir /tmp/raptor-supervisor/dut \
  /tmp/raptor-supervisor/riscof/raptor-rv64s/elfs
```

必须显式清空上游 Makefile 的 EXCLUDE_EXTENSIONS；该默认列表包含 Svade，
仅设置 include_priv_tests 并不足以选中测试。生成命令 exit 0 不证明有 ELF，
必须核对 selection.json、实际 ELF 数量和执行结果。

UDB 0.1.16 使用 Sv39 1.0.0、STVEC_MODES 和 STVEC_BASE_ALIGNMENT_VECTORED；
这些是数据库命名，不把特权基线改成另一个版本。计数器权限按 RTL 低三位，
Sail 中 Svadu 关闭、Svade 开启。CLINT 地址取自 hdl/include/npc/rapt_soc.svh。

限制：外部/软件中断注入宏尚未实现，不能使用此配置宣布中断测试通过。
PMA 仍是测试 RAM 投影，不等同全部 NPC 区域；完整 profile 强制扩展未全部声明。
其他特权测试及参数须逐项审核后扩展集合；不通过伪造扩展或移除 NORUN 来隐藏缺口。

### Configurable-ASID Sail model (phase 40)

`sail-asid9.json` targets upstream sail-riscv commit
`803f192b5906e39eeff2d31269d2e88a3baf7326`, built with Sail compiler 0.20.2.
The model still reports version `0.13.1`; record its source commit and binary
hash rather than identifying it by that version string alone. Keep `sail.json`
for the previously installed model: the two configuration schemas differ.

To use the new model, copy this configuration directory to an isolated build
location and copy `sail-asid9.json` over that copy's `sail.json`. Set
`ACT4_CONFIG` to the copied `test_config.yaml` and `ACT4_SAIL_DIR` to the new
model binary directory. Validate that copied configuration using
`--config-override <copied-sail.json> --validate-config` before generation.
Use `ACT4_EXTENSIONS=Sv,Svbare,SvPMP,ExceptionsSm,ExceptionsZc` and explicitly
clear `EXCLUDE_EXTENSIONS` for the 39-test phase-40 selection. The NPC runner
requires `--trap-on-ebreak` with this platform's finisher halt macros.

The new override sets `memory.asidlen=9`, migrates LR/SC exception fields,
disables newly inherited extensions outside this verification projection,
retains Sstvecd, and fixes delegation masks to the RTL's implemented masks.
It is a supervisor verification subset, not the full mandatory profile.


## Archived whole-access PMP experiment

The phase44 patched-model experiment and its dedicated configuration have
been removed from the working tree. Historical results remain scoped to that
patched model; they are not unmodified upstream Sail results.

## F/D/Zfhmin instruction verification

The supervisor projection now declares Zfhmin in UDB and enables it in each
Sail configuration variant. With `ACT4_EXTENSIONS=F,D,Zfhmin` and
`EXCLUDE_EXTENSIONS=`, the fixed phase 46 upstream checkout selects 202 RV64
instruction tests: F 82, D 114, Zfhmin 6. Audit these with
`act4_selection_audit.py --test-tree rv64i`; the default remains `priv` for
existing privileged-selection audits. Compare selected test paths with actual
ELFs, not only the generator exit status.

Zfhmin also requires FCVT.D.H and FCVT.H.D when D is present. The current
upstream checkout labels those two tests as requiring full Zfh. To exercise
them without declaring unimplemented half-precision arithmetic, prepare an
isolated test tree:

```sh
python3 verify/scripts/prepare_act4_zfhmin_d.py \
  --repo verify/riscof/riscv-arch-test \
  --output /tmp/raptor-zfhmin-d-tests
```

Run the upstream ACT4 `act` entrypoint with the chosen supervisor config,
`--test-dir /tmp/raptor-zfhmin-d-tests --extensions all --workdir <isolated-dir>`.
Use the same Ruby/Sail PATH and XDG environment as the normal `riscof-gen`
command. The adapter changes only REQUIRED_EXTENSIONS and MARCH in copied
files; `adaptation.json` records original, adapted, and unchanged-body hashes.
It leaves the upstream checkout, test instruction bodies, and signature
contents unchanged. Compile and generate new signatures with Sail before
running the self-checking ELFs on the frozen DUT.

These instruction-test results do not by themselves establish all privileged
FS-state, context-switch, exception, or complete profile requirements. The
phase 46 progress record contains exact frozen inputs and execution results.


## 要求台账与本地记录

`requirements.json` 保留强制要求、源码与测试定位、冻结证据和开放门槛。
验收必须核对对应源码、配置及产物，历史通过数量不代表当前完整 profile 合规。

过程性审查、历史进展和收尾规划存放于本地 `docs.agent/isa/rva22s64/`，
默认不进入 Git；该目录缺失不影响配置和验证脚本运行。
