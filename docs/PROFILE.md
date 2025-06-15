# NPC 性能评估结果

使用`am-kernels`中的`microbench`测试程序进行性能测试。

```shell
cd npc
make perf
```

## Result

SoC Frequency: 100 MHz

| commit  | comment     | #Cycle   | #Inst  | IPC   | Freq (MHz) | Power (mW) | Area (um^2) | IFU, %       | LSU, %       | EXU, %       | LD, %     | ST, %    | ALU, %    | BR, %     | CSR, % | OTH, %   | JAL,  %  | JALR,  % |
| ------- | ----------- | -------- | ------ | ----- | ---------- | ---------- | ----------- | ------------ | ------------ | ------------ | --------- | -------- | --------- | --------- | ------ | -------- | -------- | -------- |
| 66b3344 | perf        | 38309563 | 849339 | 0.022 | 466        | -          | 23963       | 22366563, 58 | 13394983,35  | 849339,99    | 83421,10  | 67252, 8 | 448991,53 | 190050,22 | 2, 0   | 59623, 7 | -        | -        |
| c1f2dc3 | l1i:8x4B    | 26917653 | 848522 | 0.032 | 334        | -          | 24760       | 11054218, 41 | 13317869,49  | 848522,99    | 83387,10  | 67219, 8 | 448589,53 | 189744,22 | 2, 0   | 59581, 7 | -        | -        |
| dac9e4f | OPtiming    | 26917653 | 848522 | 0.032 | 532        | -          | 23999       | 11054218, 41 | 13317869,49  | 848522,99    | 83387,10  | 67219, 8 | 448589,53 | 189744,22 | 2, 0   | 59581, 7 | -        | -        |
| 3e0f1ce | i8B,axi[^1] | 16970857 | 854729 | 0.050 | 560        | -          | 26811       | 2057170,  12 | 12349500,73  | 854729,99    | 85701,10  | 67200, 8 | 450511,53 | 191757,22 | 2, 0   | 59558, 7 | -        | -        |
| 3e0f1ce | axi-delay   | 20720045 | 849533 | 0.041 | 560        | -          | 26811       | 4984694,  24 | 13186752,64  | 849533,99    | 83815,10  | 67200, 8 | 448891,53 | 190067,22 | 2, 0   | 59558, 7 | -        | -        |
| 046eea8 | l1i:4x8B    | 21867026 | 847917 | 0.039 | 566        | -          | 22798       | 6141021,  28 | 13182254,60  | 847917,99    | 83361,10  | 67194, 8 | 448273,53 | 189533,22 | 2, 0   | 59554, 7 | -        | -        |
| [^2]    | l1i:4x8B    | 22646833 | 848317 | 0.037 | 566        | -          | 22798       | 6211357,  27 | 13890525,61  | 848317,99    | 83377,10  | 67209, 8 | 448511,53 | 189648,22 | 2, 0   | 59570, 7 | -        | -        |
| 569dd1c | add wbu[^3] | 23519169 | 848435 | 0.036 | 575        | -          | 23553       | 6236285,  27 | 13889145,59  | 848435,99    | 83377,10  | 67209, 8 | 448557,53 | 189720,22 | 2, 0   | 59570, 7 | -        | -        |
| f7dd997 | pipeline    | 22312119 | 848260 | 0.038 | 545        | -          | 25919       | 6463036,  29 | 13946471, 63 | 848261,100   | 87185,10  | 61326, 7 | 361309,43 | 255834,30 | 2, 0   | 82604,10 | -        | -        |
| f32a4a1 | ppa optim   | 21974627 | 848206 | 0.039 | 564        | -          | 24034       | 6464539,  29 | 13948055, 63 | 848207,100   | 87382,10  | 54971, 6 | 362596,43 | 256221,30 | 2, 0   | 87034,10 | -        | -        |
| 72541a3 | optim[^4]   | 20575381 | 849051 | 0.041 | 532        | -          | 24946       | 14333993, 70 | 13265764, 64 | 849051, 99   | 109098,13 | 57673, 7 | 274270,32 | 324499,38 | 3, 0   | 83508,10 | -        | -        |
| 92e723a | simple bpu  | 21763542 | 849279 | 0.039 | 534        | -          | 24671       | 14928565, 69 | 13267292, 61 | 982830,116   | 108899,13 | 48331, 6 | 429884,51 | 206616,24 | 3, 0   | 10791, 1 | 36009, 4 | 8746,  1 |
| 2ead5f6 | fence.i     | 21760489 | 849588 | 0.039 | 599        | -          | 25014       | 14926844, 69 | 13264464, 61 | 983342,116   | 108835,13 | 48359, 6 | 430306,51 | 206524,24 | 3, 0   | 10783, 1 | 36035, 4 | 8743,  1 |
| 88a5e66 | ppa optim   | 21741693 | 849723 | 0.039 | 540        | -          | 24889       | 14910490, 69 | 13264613, 61 | 983397,116   | 108830,13 | 48363, 6 | 430678,51 | 206283,24 | 3, 0   | 10788, 1 | 36043, 4 | 8735,  1 |
| 7be16e9 | ppa optim   | 21825180 | 849831 | 0.039 | 634        | -          | 24347       | 15000124, 69 | 13319454, 61 | 983511,116   | 83681,10  | 67215, 8 | 449141,53 | 190209,22 | 3, 0   | 10109, 1 | 33894, 4 | 15579, 2 |
| c3022ee | BPU optim   | 21479203 | 847141 | 0.039 | 546        | 5.752e-03  | 28697       | 14561299, 68 | 13489285, 63 | 6494240,767  | 83094,10  | 66976, 8 | 448263,53 | 189617,22 | 3, 0   | 10052, 1 | 33614, 4 | 15522, 2 |
| 6603df2 | rv32em[^5]  | 19146031 | 477722 | 0.025 | 89.674     | -          | 68136       | 12952068, 68 | 13242864, 69 | 5591721,1170 | 72774,15  | 57985,12 | 232795,49 | 62541,13  | 3, 0   | 10039, 2 | 29759, 6 | 11826, 2 |
| 6603df2 | rv32im[^5]  | 19146031 | 470876 | 0.024 | 90.352     | -          | 76891       | 13150578, 68 | 13458225, 69 | 5590714,1187 | 69816,15  | 56900,12 | 230434,49 | 62199,13  | 3, 0   | 9854,  2 | 29847, 6 | 11823, 3 |
| 4c5d3bc | rv32em[^6]  | 19235382 | 477647 | 0.025 | 421        | 7.868e-03  | 37395       | 12976526, 67 | 13243438, 69 | 5612381,1175 | 72761,15  | 57971,12 | 232762,49 | 62534,13  | 3, 0   | 10039, 2 | 29754, 6 | 11823, 2 |
| 4c5d3bc | rv32im[^6]  | 19567694 | 470947 | 0.024 | 421        | 9.792e-03  | 45844       | 13175979, 67 | 13458303, 69 | 5591408,1187 | 69829,15  | 56912,12 | 230465,49 | 62206,13  | 3, 0   | 9854,  2 | 29852, 6 | 11826, 3 |
| 4c5d3bc | rv32i       | 21314593 | 846426 | 0.025 | 541        | 7.567e-03  | 36946       | 14542641, 68 | 13288154, 62 | 6196033,732  | 83256,10  | 68505, 8 | 446226,53 | 189466,22 | 3, 0   | 9820,  1 | 33628, 4 | 15522, 2 |

[^1]: icache line size 修改为 8B，现在 icache size 为 8x8B，L1I Cache 的 SDRAM 部分修改为 arburst，一次传输 8B。
[^2]: `046eea8e` 及之前的版本中，npc 的频率设置为 466 MHz，之后的版本中，npc 的频率设置为 500 MHz。
[^3]: 从 3 周期 cpu 变为 4 周期 cpu，为之后的流水线设计做准备。
[^4]: exu forward, fix pmu and axi store load separate
[^5]: using one cycle fast m extension
[^6]: change to using multi cycle m extension (booth's and restoring division)


### coremark npc (Marks/IPC)

| Extensions     | RV32IM   | RV32I    | RV32EM   | RV32E    | RV32EM (multi) |
| -------------- | -------- | -------- | -------- | -------- | -------------- |
| RV32IM         | 935/.199 | 2.082    | 0.997    | 2.078    | 1.191          |
| RV32I          |          | 449/.238 | 0.479    | 0.998    | 0.572          |
| RV32EM         |          |          | 938/.201 | 2.084    | 1.195          |
| RV32E          |          |          |          | 450/.238 | 0.573          |
| RV32EM (multi) |          |          |          |          | 785/.169       |

### microbench npc (total/scored/IPC)

| Extensions     | RV32IM       | RV32I         | RV32EM       | RV32E         | RV32EM (multi) |
| -------------- | ------------ | ------------- | ------------ | ------------- | -------------- |
| RV32IM         | 743/927/.190 | 1.246         | 1.036        | 1.257         | 1.062          |
| RV32I          |              | 926/1189/.214 | 0.832        | 1.009         | 0.852          |
| RV32EM         |              |               | 770/952/.191 | 1.213         | 1.025          |
| RV32E          |              |               |              | 934/1200/.215 | 0.845          |
| RV32EM (multi) |              |               |              |               | 789/1002/.182  |

### microbench ysyxsoc (total/scored/IPC)

| Extensions     | RV32IM         | RV32I           | RV32EM         | RV32E           | RV32EM (multi) |
| -------------- | -------------- | --------------- | -------------- | --------------- | -------------- |
| RV32IM         | 6537/9192/.024 | 1.064           | 0.997          | 1.053           | 1.000          |
| RV32I          |                | 6957/10224/.040 | 0.937          | 0.990           | 0.940          |
| RV32EM         |                |                 | 6520/9185/.025 | 1.056           | 1.003          |
| RV32E          |                |                 |                | 6886/10141/.039 | 0.950          |
| RV32EM (multi) |                |                 |                |                 | 6540/9228/.025 |

### PPA result

```shell
# commit: 4c5d3bc
# rv32i
| Endpoint           | Clock Group | Delay Type | Path Delay | Path Required | CPPR  | Slack | Freq(MHz) |
| wbu/_242_:D        | core_clock  | max        | 1.806f     | 1.961         | 0.000 | 0.155 | 541.877   |
| wbu/_254_:D        | core_clock  | max        | 1.803f     | 1.961         | 0.000 | 0.158 | 542.969   |
| wbu/_253_:D        | core_clock  | max        | 1.799f     | 1.961         | 0.000 | 0.162 | 543.923   |
Generate the report at 2024-11-24T14:22:15
Report : Averaged Power
 +---------------+----------------+--------------+---------------+-------------+-----------+
| Power Group   | Internal Power | Switch Power | Leakage Power | Total Power | (%)       |
+---------------+----------------+--------------+---------------+-------------+-----------+
| combinational | 2.432e-03      | 0.000e+00    | 7.703e-04     | 3.202e-03   | (42.320%) |
| sequential    | 4.272e-03      | 0.000e+00    | 9.311e-05     | 4.365e-03   | (57.680%) |
+---------------+----------------+--------------+---------------+-------------+-----------+
Net Switch Power   ==    0.000e+00 (0.000%)
Cell Internal Power   ==    6.704e-03 (88.590%)
Cell Leakage Power   ==    8.634e-04 (11.410%)
Total Power   ==  7.567e-03
   Chip area for module '\ysyx': 53.466000
   Chip area for module '\ysyx_bus': 944.300000
   Chip area for module '\ysyx_clint': 978.348000
   Chip area for module '\ysyx_exu$interfaces$idu_pipe_if': 3414.908000
   Chip area for module '\ysyx_exu_alu': 1682.450000
   Chip area for module '\ysyx_exu_csr': 1933.820000
   Chip area for module '\ysyx_idu$interfaces$idu_pipe_if': 1255.520000
   Chip area for module '\ysyx_idu_decoder': 1772.092000
   Chip area for module '\ysyx_ifu': 2550.142000
   Chip area for module '\ysyx_ifu_l1i': 4952.920000
   Chip area for module '\ysyx_lsu': 2197.958000
   Chip area for module '\ysyx_reg': 14876.316000
   Chip area for module '\ysyx_wbu': 333.830000
   Chip area for top module '\ysyx': 36946.070000
# rv32em
| Endpoint           | Clock Group | Delay Type | Path Delay | Path Required | CPPR  | Slack  | Freq(MHz) |
| exu/mul/_09860_:D  | core_clock  | max        | 2.334f     | 1.961         | 0.000 | -0.373 | 421.381   |
| exu/mul/_09761_:D  | core_clock  | max        | 2.328r     | 1.969         | 0.000 | -0.359 | 423.926   |
| exu/mul/_09862_:D  | core_clock  | max        | 2.320r     | 1.969         | 0.000 | -0.351 | 425.277   |
Generate the report at 2024-11-24T14:19:45
Report : Averaged Power
 +---------------+----------------+--------------+---------------+-------------+-----------+
| Power Group   | Internal Power | Switch Power | Leakage Power | Total Power | (%)       |
+---------------+----------------+--------------+---------------+-------------+-----------+
| combinational | 2.667e-03      | 0.000e+00    | 7.641e-04     | 3.431e-03   | (43.605%) |
| sequential    | 4.344e-03      | 0.000e+00    | 9.344e-05     | 4.437e-03   | (56.395%) |
+---------------+----------------+--------------+---------------+-------------+-----------+
Net Switch Power   ==    0.000e+00 (0.000%)
Cell Internal Power   ==    7.011e-03 (89.101%)
Cell Leakage Power   ==    8.575e-04 (10.899%)
Total Power   ==  7.868e-03
   Chip area for module '\ysyx': 53.466000
   Chip area for module '\ysyx_bus': 917.966000
   Chip area for module '\ysyx_clint': 978.348000
   Chip area for module '\ysyx_exu$interfaces$idu_pipe_if': 3514.126000
   Chip area for module '\ysyx_exu_alu': 1702.400000
   Chip area for module '\ysyx_exu_csr': 1911.476000
   Chip area for module '\ysyx_exu_mul': 8679.846000
   Chip area for module '\ysyx_idu$interfaces$idu_pipe_if': 1100.176000
   Chip area for module '\ysyx_idu_decoder': 1772.092000
   Chip area for module '\ysyx_ifu': 2533.916000
   Chip area for module '\ysyx_ifu_l1i': 4952.920000
   Chip area for module '\ysyx_lsu': 2030.644000
   Chip area for module '\ysyx_reg': 6914.670000
   Chip area for module '\ysyx_wbu': 333.830000
   Chip area for top module '\ysyx': 37395.876000
# rv32im
| Endpoint           | Clock Group | Delay Type | Path Delay | Path Required | CPPR  | Slack  | Freq(MHz) |
| exu/mul/_09756_:D  | core_clock  | max        | 2.343r     | 1.969         | 0.000 | -0.374 | 421.252   |
| exu/mul/_09855_:D  | core_clock  | max        | 2.327f     | 1.961         | 0.000 | -0.367 | 422.557   |
| exu/mul/_09857_:D  | core_clock  | max        | 2.335r     | 1.969         | 0.000 | -0.366 | 422.576   |
Generate the report at 2024-11-24T14:20:59
Report : Averaged Power
 +---------------+----------------+--------------+---------------+-------------+-----------+
| Power Group   | Internal Power | Switch Power | Leakage Power | Total Power | (%)       |
+---------------+----------------+--------------+---------------+-------------+-----------+
| combinational | 3.418e-03      | 0.000e+00    | 9.781e-04     | 4.396e-03   | (44.893%) |
| sequential    | 5.282e-03      | 0.000e+00    | 1.140e-04     | 5.396e-03   | (55.107%) |
+---------------+----------------+--------------+---------------+-------------+-----------+
Net Switch Power   ==    0.000e+00 (0.000%)
Cell Internal Power   ==    8.700e-03 (88.847%)
Cell Leakage Power   ==    1.092e-03 (11.153%)
Total Power   ==  9.792e-03
   Chip area for module '\ysyx': 53.466000
   Chip area for module '\ysyx_bus': 946.960000
   Chip area for module '\ysyx_clint': 978.348000
   Chip area for module '\ysyx_exu$interfaces$idu_pipe_if': 3529.820000
   Chip area for module '\ysyx_exu_alu': 1702.400000
   Chip area for module '\ysyx_exu_csr': 1978.242000
   Chip area for module '\ysyx_exu_mul': 8607.760000
   Chip area for module '\ysyx_idu$interfaces$idu_pipe_if': 1255.520000
   Chip area for module '\ysyx_idu_decoder': 1772.092000
   Chip area for module '\ysyx_ifu': 2602.012000
   Chip area for module '\ysyx_ifu_l1i': 4946.536000
   Chip area for module '\ysyx_lsu': 2182.796000
   Chip area for module '\ysyx_reg': 14954.254000
   Chip area for module '\ysyx_wbu': 333.830000
   Chip area for top module '\ysyx': 45844.036000
```

### ysyxsoc simulation result

```log
./build/ysyxSoCFull -b -n -d /Users/yujin/Developer/c-projects/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so -m /Users/yujin/Developer/c-projects/ysyx-workbench/npc/csrc/mem/mrom-data/build/mrom-data.bin /Users/yujin/Developer/c-projects/ysyx-workbench/am-kernels/benchmarks/microbench/build/microbench-riscv32e-ysyxsoc.bin
npc monitor.cc:74 load_file image: /Users/yujin/Developer/c-projects/ysyx-workbench/am-kernels/benchmarks/microbench/build/microbench-riscv32e-ysyxsoc.bin, size: 22925
npc monitor.cc:105 load_img Load MROM image from /Users/yujin/Developer/c-projects/ysyx-workbench/npc/csrc/mem/mrom-data/build/mrom-data.bin
npc monitor.cc:74 load_file image: /Users/yujin/Developer/c-projects/ysyx-workbench/npc/csrc/mem/mrom-data/build/mrom-data.bin, size: 24
[src/memory/paddr.c:64 init_mem] physical memory area [0x80000000, 0x87ffffff]
2024-12-23 11:49:51.354 ysyxSoCFull[59576:16288533] +[IMKClient subclass]: chose IMKClient_Modern
2024-12-23 11:49:51.354 ysyxSoCFull[59576:16288533] +[IMKInputSession subclass]: chose IMKInputSession_Modern
FSBL: 63160, SSBL: 718841|655681
Init: 747215|28374, mvendorid: 0x79737978, marchid: 23060087
======= Running MicroBench [input *test*] =======
[qsort] Quick sort: * Passed.
[queen] Queen placement: * Passed.
[bf] Brainf**k interpreter: * Passed.
[fib] Fibonacci number: * Passed.
[sieve] Eratosthenes sieve: * Passed.
[15pz] A* 15-puzzle search: * Passed.
[dinic] Dinic's maxflow algorithm: * Passed.
[lzip] Lzip compression: * Passed.
[ssort] Suffix sort: * Passed.
[md5] MD5 digest: * Passed.
==================================================
MicroBench PASS
Scored time: 6313.000 ms
Total  time: 9015.000 ms
npc sdb.cc:76 npc_exu_ebreak EBREAK at pc = a000392c
npc pmu.cc:151 perf ======== Instruction Analysis ========
npc pmu.cc:161 perf #Inst: 477791, cycle: 18938284, IPC: 0.025, 0.023 (main), CLINT: 9469137 (us),  0.050 MIPS
npc pmu.cc:163 perf |      IFU,  % |      LSU,  % |      EXU,  % |
npc pmu.cc:167 perf | 12690375, 67 | 13039537, 69 |  6082718,1273 |
npc pmu.cc:169 perf |     LD, % |     ST, % |    ALU, % |     BR, % | CSR, % |   OTH, % |    JAL,  % |   JALR,  % |
npc pmu.cc:182 perf |  69461,15 |  56518,12 | 232521,49 |  64691,14 |   3, 0 | 10533, 2 |  32239,  7 |  11825,  2 |
npc pmu.cc:183 perf ======== TOP DOWN Analysis ========
npc pmu.cc:185 perf |      IFU,  % |      LSU,  % |      EXU,  % |       LD,  % |       ST,  % |
npc pmu.cc:191 perf | 12690375, 67 | 13039537, 69 |  6082718,1273 |    69461, 15 |    56518, 12 |
npc pmu.cc:195 perf IFU Avg Cycle: 2.0, LSU Avg Cycle: 103.5
npc pmu.cc:198 perf BPU Success: 24327, Fail: 60867, Rate: 28.6%
npc pmu.cc:201 perf ifu_bra_hazard_cycle:   153288,  1%, ifu_lsu_hazard_cycle:  7077426, 37%
npc pmu.cc:203 perf idu_hazard_cycle:     9053,  0% (data hazard)
npc pmu.cc:204 perf ifu_fetch_cnt: 6237083, instr_cnt: 477791
npc pmu.cc:211 perf ======== Cache Analysis ========
npc pmu.cc:214 perf |      HIT, % |     MISS, % |  HIT CYC, % | MISS CYC, % |  HIT Cost AVG | MISS Cost AVG |     AMAT |
npc pmu.cc:226 perf |       -1, 0 |        1,100 |       -1,-0 | 18938284,100 |             0 |       9469142 | 9469142.0 |
npc pmu.cc:239 statistic Simulate time: 24032346 us, 24032 ms, Freq: 0.788 MHz, Inst:  19881 I/s, 0.020 MIPS
npc pmu.cc:244 statistic HIT GOOD TRAP at pc: a0003930, inst: 00100073
```

## ICache Simulator Result using microbench trace

| cache_size | line_num | line_size | hit_cost | miss_cost |    hit_rate |    amat |
| ---------: | -------: | --------: | -------: | --------: | ----------: | ------: |
|        128 |        8 |        16 |        0 |        43 |    0.899069 | 4.34003 |
|        128 |        4 |        32 |        0 |        59 |    0.919833 | 4.72988 |
|        128 |       16 |         8 |        0 |        35 |    0.848068 | 5.31762 |
|        128 |        2 |        64 |        0 |        91 |     0.93627 | 5.79945 |
|         64 |        4 |        16 |        0 |        43 |    0.842909 | 6.75492 |
|         64 |        2 |        32 |        0 |        59 |    0.878307 | 7.17989 |
|         64 |        8 |         8 |        0 |        35 |    0.778308 | 7.75923 |
|        128 |       32 |         4 |        0 |        31 |    0.746398 | 7.86166 |
|         32 |        2 |        16 |        0 |        43 |    0.785835 |  9.2091 |
|         64 |        1 |        64 |        0 |        91 |     0.88555 | 10.4149 |
|         32 |        4 |         8 |        0 |        35 |    0.693061 | 10.7429 |
|         64 |       16 |         4 |        0 |        31 |      0.6265 | 11.5785 |
|        128 |        1 |       128 |        0 |       155 |    0.919852 |  12.423 |
|         32 |        1 |        32 |        0 |        59 |     0.75214 | 14.6237 |
|         16 |        1 |        16 |        0 |        43 |    0.632886 | 15.7859 |
|         32 |        8 |         4 |        0 |        31 |    0.480072 | 16.1178 |
|         16 |        2 |         8 |        0 |        35 |    0.489442 | 17.8695 |
|          8 |        1 |         8 |        0 |        35 |    0.426871 | 20.0595 |
|         16 |        4 |         4 |        0 |        31 |    0.134273 | 26.8375 |
|          8 |        2 |         4 |        0 |        31 |   0.0024322 | 30.9246 |
|          4 |        1 |         4 |        0 |        31 | 1.18818e-06 |      31 |


## TODO: Exception Handling

- 抛出异常时, 需要将`mepc`设置为发生异常的指令的PC值, 这种特性称为"精确异常". 如果不满足这一特性, 从异常处理通过`mret`返回时, 就无法精确返回到之前发生异常的指令处, 从而使得发生异常前后的状态不一致. 这可能会导致系统软件无法利用异常机制实现现代操作系统的某些关键机制, 例如进程切换, 请页调度等. 但在流水线处理器中, IFU的PC会不断变化, 等到某条指令在执行过程中抛出异常时, IFU的PC已经与这条指令不匹配了. 为了获取与该指令匹配的PC, 我们需要在IFU取指时将相应的PC一同传递到下游.
- 指令可能会在推测执行时抛出异常, 但如果推测错误, 那实际上这条指令不应该被执行, 所抛出的异常也不应该被处理. 因此, 在异常处理过程中需要更新处理器状态的操作, 都需要等到确认推测正确后, 才能真正进行, 包括写入`mepc`, `mcause`, 跳转到`mtvec`所指示的位置等.
- `mcause`的更新取决于异常的类型, 在RISC-V处理器中, 不同的异常号由不同的部件产生. 产生的异常号也需要传递到流水线的下游, 等到确认推测正确后, 才能真正写入`mcause`.

| 异常号 | 异常描述                       | 产生部件 | OK  |
| ------ | ------------------------------ | -------- | --- |
| 0      | Instruction address misaligned | IFU      |     |
| 1      | Instruction access fault       | IFU      |     |
| 2      | Illegal Instruction            | IDU      | y   |
| 3      | Breakpoint                     | IDU      | y   |
| 4      | Load address misaligned        | LSU      |     |
| 5      | Load access fault              | LSU      |     |
| 6      | Store/AMO address misaligned   | LSU      |     |
| 7      | Store/AMO access fault         | LSU      |     |
| 8      | Environment call from U-mode   | IDU      | y   |
| 9      | Environment call from S-mode   | IDU      | y   |
| 11     | Environment call from M-mode   | IDU      | y   |
| 12     | Instruction page fault         | IFU      |     |
| 13     | Load page fault                | LSU      |     |
| 15     | Store/AMO page fault           | LSU      |     |

