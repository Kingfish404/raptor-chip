# Microarchitecture (uarch)

```text
 ------------------------------------------------------------
 RISC-V processor pipeline
 has the following (conceptual) stages:
 ------------------------------------------------------------
 in-order      | IFU - Instruction Fetch Unit
 issue         | IDU - Instruction Decode Unit
 --------------+ IQU - Instruction Queue Unit
 out-of-order  :
 execution     : EXU - Execution Unit
 --------------+
 in-order      | LSU - Load Store Unit
 --------------+
 in-order      | IQU - Instruction Queue Unit
 commit        | WBU - Write Back Unit
 ------------------------------------------------------------
 Stages (`=>' split each stage):
 [
  frontend (in-order and speculative issue):
        v- [BUS <-load- AXI4]
    IFU[l1i] =issue=> IDU =issue=> IQU[uop]
        ^- bpu[btb,btb_jal]
    IQU[uop] -dispatch-> IQU[rob]
             =dispatch=> EXU[rs ]
  backend  (out-of-order execution):
    EXU[rs]  =write-back=> IQU[rob]
        ^- LSU[l1d] <-load/store-> [BUS <-load/store-> AXI4]
        |- MUL :mult/div
  frontend (in-order commit):
    IQU[rob] =commit=>
    WBU[rf ] =resolve-branch=> frontend: IFU[pc,bpu]
 ]
 ------------------------------------------------------------
 See ./include/ysyx.svh for more details.
```
