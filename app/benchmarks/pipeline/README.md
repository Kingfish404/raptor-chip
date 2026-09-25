# 裸机流水线 microbenchmark

用于把 CoreMark 的混合瓶颈拆成可控的依赖链、执行吞吐、访存并行和 store 排空实验。独立于已有的 AM/用户态 `microbench`，不经过 pk，不依赖 libc，不改 `sim/.config` 或生产 RTL。支持 RV32 / RV64，要求 M-mode、M 扩展、`mcycle/minstret` 和 NPC 的 NS16550 UART（`0x10000000`）。

## 构建和运行

从仓库根目录构建，产物可放到独立临时目录：

```sh
make -C app/benchmarks/pipeline build XLEN=64 BUILD_DIR=/tmp/pipeline-build-rv64
```

运行使用**已经构建好的、与 XLEN 对应**的 simulator 和 MROM：

```sh
make -C app/benchmarks/pipeline run-rv64 \
  NPC="$PWD/sim/build/default/riscv64-npc-sim" \
  MROM="$PWD/sim/build/default/mrom/rv64-spike-rv64ima/mrom-data.bin" \
  OUTPUT=/tmp/pipeline-run-rv64 \
  RUN_ARGS='--label default-rv64-mshr2 --delay 0 --seed 1'
```

RV32 使用 `run-rv32` 及对应的 RV32 NPC/MROM。输出目录不可复用已有 `run.log`；脚本拒绝覆盖运行证据。`CROSS_COMPILE` 默认 `riscv64-elf-`。可覆盖 `ROUNDS=16 SAMPLES=3`，脚本限制轮数不超过 4096、样本数不超过 32。可用 `RUN_ARGS='--timeout 300 ...'` 延长仿真时间。

运行生成 ELF、bin、反汇编、link map、原始日志、`measurements.csv`、`summary.json` 和 `manifest.json`。Manifest 保存程序、simulator、MROM、benchmark 源码 SHA256、运行命令及 delay/seed。现有 simulator 的 RTL 配置/版本需由使用者核实并填写 label；工作区 HEAD 不能证明已有 simulator 的源码版本。默认不启用差分：每项做结果校验并要求 GOOD TRAP，但这不是完整 ISA/访存排序验证。

RV64 write-back 的整机 store 保留探针可单独构建：`make -C app/benchmarks/pipeline probe-wb XLEN=64 ROUNDS=1 BUILD_DIR=/tmp/pipeline-wb-probe`。用现有 RV64 NPC 和 MROM 运行 `probe_wb.bin`；它依次输出初始化读值、同地址密集 store 的读值、同一 cache line 八个 word 的即时与延迟读值，共 18 行十六进制数。正常结果为首行 0、后续全为 7，失败返回非零。此探针不能替代差分或完整内存排序验证。

## 测试矩阵

| 测试 | 测量意图 |
| --- | --- |
| `empty` | CSR 读数及 fence 的空区间开销 |
| `add_dep` / `add_8` | ADD 单一 RAW 链与 8 条独立 RAW 链 |
| `xor_dep` / `xor_8` | XOR 单链与 8 链，交叉检查简单 ALU |
| `mul_dep` / `mul_8` | 非零、非恒等操作数的 MUL 单链与吞吐；按 XLEN 模运算校验 |
| `rename_waw` | 同一架构目的寄存器连续覆写，源为 x0，无真实 RAW 依赖 |
| `rename_war` | 读旧版本后覆写该寄存器，检查 WAR/WAW 是否导致额外串行化 |
| `load_dep` | 热缓存自指针追踪，后继地址真实依赖上一次 load 数据 |
| `load_8_hot` | 8 个独立地址、8 个不同 cache line 的热 load 吞吐 |
| `load_8_cold` | 首次访问 8 条 line，观察并行 miss 的净收益 |
| `load_chain_cold` | 同样 8 条冷 line 的指针环，地址只能逐次产生 |
| `load_miss_first` / `load_miss_last` | 一个冷 load 与六个热 load，改变冷 load 的程序顺序 |
| `store_same` / `store_words` / `store_lines` | 同地址、同 line 中 8 个 word、8 条不同 line 的 store 吞吐 |
| `store_load` | 同地址 store→load 对，包含 SQ forwarding/排序路径 |

热循环每轮 64 条目标指令，加 `addi` / `bnez` 两条循环控制指令；默认 16 轮，即 1024 条目标指令。`store_load` 的 1024 ops 包括 512 store 和 512 load；WAR 的 ops 同样包括读和覆写。汇编禁止 RVC 和 relaxation；反汇编保留了函数名，方便按 PC 选择 trace。

## 如何解释数字

- 单链的 cycles/op 估计的是**结果到下一条使用者的有效依赖延迟**，包括唤醒和旁路路径，不是执行单元内部级数。8 链测的是整条机器路径的吞吐；前端、端口、rename、commit 和循环恢复都可能限制它。WAW/WAR 对比能发现异常串行化，但不能单独证明重命名实现正确。
- `kernels.S` 的计时顺序是：前置 fence → mcycle → minstret → 测试体 → 后置 fence → minstret → mcycle。当前核心的 CSR 串行化提供计时边界；移植到别的核需要重新检查边界约束。计时包含循环控制及尾部 fence，不包含初始化、打印、校验、函数调用/返回。cycle 与 instret 的采样端点相差 CSR 指令，不能当成完全相同窗口。
- `summary.json` 同时保留原始 cycles/op 和减去 empty 中位数后的估计。**减 empty 不是精确的单指令延迟**：尾部 fence 在真实负载下可能需要排空；尤其 store 数字包含排空成本。比较 ROUNDS=8/16/32 的斜率可以降低固定开销影响。RV32 使用低 32 位计数器模减，区间须小于 2^32 cycles/instructions。
- 每次正式测量前用两次调用预热同一段代码。热测试同时预热数据；冷测试在独立 scratch 上预热代码，再使用从未软件读写的新 bank。冷链表在二进制中静态初始化，不在计时前用 store 建链。每个冷样本独占 8 KiB bank；假设 cache line 为 64 bytes、无数据预取。改变几何或引入预取需重新设计布局。
- miss-first/last 只报告聚合完成时间，**不能据此断言年轻 load 是否提前广播**。要确认 IOQ 队首阻塞，请按反汇编 PC 同时观察请求接受、数据返回、IOQ complete、completion 身份和退休事件；其计数可能重叠。
- 所有打印在整组测量结束后执行；不得把 simulator 总运行周期当成 kernel 周期。store 校验在计时结束后读回；它验证最终内存值，不证明每个中间 store 已经对外可见。

比较 MSHR=0/2 时固定二进制 SHA256、XLEN、其他 RTL 参数、内存 delay、seed、ROUNDS 和 SAMPLES。建议先看热 load 是否受影响，再比较独立冷 load 与冷指针链；只在前者变快说明收益来自可利用的访存并行。结合跨 line store 和 miss-first/last 再判断全局阻塞/有序完成的代价。不要把多个测试的收益相加推算 CoreMark。
