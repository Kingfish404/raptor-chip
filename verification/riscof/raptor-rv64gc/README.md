# RV64 ACT4 初始配置

本目录用于恢复 RV64 的 M 模式指令测试入口，覆盖 RV64GC 和配置中列出的位操作等扩展。default RV64 RTL 完全支持 RVA22S64；本测试配置以 `include_priv_tests: False` 选择 M 模式指令测试。S/U、PMA、计数器和维护指令使用相应的 supervisor 配置及定向测试。

使用 `make -C verification riscof ISA=rv64`。框架采用 Sail 0.13.1，RV64 使用其默认 64 位模式；RV32 显式传入 `--rv32`。`ACT4_EXTENSIONS` 可以选择测试子集，报告必须列出实际集合。
