# Microarchitecture (uarch)

```text
 ------------------------------------------------------------
 RISC-V processor pipeline
 has the following (conceptual) stages:
 ------------------------------------------------------------
 in-order      | IFU - Instruction Fetch Unit
 issue         | IDU - Instruction Decode Unit
               | RNU - Register Naming Unit (rename, PRF)
 --------------+ ROU - Re-Order Unit (ROB, uop queue)
 out-of-order  :
 execution     : EXU - Execution Unit (RS, IOQ)
 --------------+
 in-order      | LSU - Load Store Unit (STQ, SQ)
 --------------+
 in-order      | ROU - Re-Order Unit
 commit        | CMU - Commit Unit
 ------------------------------------------------------------
 Stages (`=>' split each stage):
 [
  frontend (in-order and speculative issue):
        v- [BUS <-load- AXI4]
    IFU[l1i,tlb] =issue=> IDU =issue=> RNU[prf,rmt,rat]
        ^- bpu[btb(COND/DIRE/INDR/RETU),pht,rsb]
    RNU =rename=> ROU[uop]
    ROU[uop] -dispatch-> ROU[rob]
             =dispatch=> EXU[rs ]
  backend  (out-of-order execution):
    EXU[rs]  =write-back=> ROU[rob]
        ^- LSU[l1d,tlb] <-load/store-> [BUS <-load/store-> AXI4]
        |- MUL :mult/div
    LSU[stq] (speculative store temp queue)
    LSU[sq ] (committed store queue -> L1D/BUS)
  frontend (in-order commit):
    ROU[rob] =commit=> CMU & LSU[sq]
    CMU =resolve-branch=> frontend: IFU[pc,bpu]
 ]
 ------------------------------------------------------------
 See /rtl_sv/include/ysyx.svh for more details.
```

mermaid [^1] diagram [^2] of the uarch:

```mermaid
flowchart TD
 subgraph FE["frontend (in-order)"]
        IFU["IFU"]
        L1I["L1I"]
        IDU["IDU"]
        BPU["BPU (BTB/PHT/RSB)"]
        RNU["RNU (PRF/RMT/RAT)"]
        ROU["ROU (ROB)"]
        CSR["CSR"]
        CMU["CMU"]
  end
 subgraph BE["backend (out-of-order)"]
        EXU["EXU (RS/IOQ)"]
        MUL["MUL"]
        ALU["ALU"]
  end
 subgraph MEM["memory subsystem"]
        LSU["LSU"]
        STQ["Store Temp Queue"]
        SQ["Store Queue"]
        L1D["L1D"]
        BUS["BUS"]
        CLINT["CLINT"]
  end
    IFU --> IDU & L1I & BPU
    IDU --> RNU
    RNU --> ROU
    ROU --> EXU & LSU & CMU & CSR
    LSU --> BUS & STQ & SQ & L1D
    EXU --> ROU & MUL & ALU
    BUS --> LSU & AXI["AXI4"] & IFU
    L1I --> IFU
    CMU --> IFU
    BPU --> IFU
    L1D --> LSU
    SQ --> LSU & BUS
    STQ --> SQ
    CSR --> EXU
    RNU --> ROU
    ALU --> EXU
    MUL --> EXU
    CLINT --> BUS
    LSU --> EXU
```

[^1]: https://mermaid.js.org/
[^2]: https://www.mermaidchart.com/play
