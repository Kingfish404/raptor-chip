# RV64 ACT4 初始配置

本目录用于恢复 RV64 的 M 模式指令测试入口，覆盖 RV64GC 和配置中列出的位操作等扩展。`include_priv_tests: False` 是当前覆盖边界；这份配置不构成 RVA22S64 合规声明。完整 supervisor/PMA/计数器/维护指令配置仍需逐项加入，并实现对应的平台中断宏。

使用 `make -C verify riscof ISA=rv64`。框架采用 Sail 0.13.1，RV64 使用其默认 64 位模式；RV32 显式传入 `--rv32`。`ACT4_EXTENSIONS` 可以选择测试子集，报告必须列出实际集合。
