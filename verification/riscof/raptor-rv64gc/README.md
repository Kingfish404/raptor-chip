# RV64 ACT4 初始配置

本目录提供 RV64GC M 模式指令测试配置（`include_priv_tests: False`），覆盖 RV64GC 与位操作等基础扩展。当前 `default` RV64 RTL 默认实现 RVA23U64 / RVA23S64；`make -C verification riscof ISA=rv64` 默认运行 [`raptor-rva23s64`](../raptor-rva23s64/README.md)（Sail 0.16）。

如需单独运行本 RV64GC M 模式子集，请显式指定 `ACT4_SUITE=raptor-rv64gc`（`ACT4_EXTENSIONS` 可进一步筛选扩展子集，报告须列出实际集合）。
