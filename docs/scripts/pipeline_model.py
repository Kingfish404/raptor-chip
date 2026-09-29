"""Illustrative queue-occupancy model for the Raptor explorer.

Not NPC/Verilator or an RTL timing model. A straight-line listing (branches do
not redirect) uses preset widths, simplified queues and a register-name
scoreboard. The single completion delay and conservative store/control-flow
retirement do not reproduce RTL bypasses, replay or store followers.
"""

from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass, field
from typing import Any

REG_RE = re.compile(
    r"\b(x(?:[0-9]|[12][0-9]|3[01])|zero|ra|sp|gp|tp|t[0-6]|s(?:[0-9]|1[01])|a[0-7])\b"
)


def _cfg(values: dict[str, Any]) -> dict[str, int]:
    return {
        "decode": int(values.get("decode_width") or 2),
        "rename": int(values.get("rename_width") or 2),
        "dispatch": int(values.get("dispatch_width") or 2),
        "commit": int(values.get("commit_width") or 2),
        "rob": int(values.get("rob_entries") or 32),
        "alq": int(values.get("alq_entries") or 8),
        "brq": int(values.get("brq_entries") or 8),
        "mdq": int(values.get("mdq_entries") or 4),
        "ioq": int(values.get("ioq_entries") or 8),
        "fpq": int(values.get("fpq_entries") or 1),
        "fetch_stage": int(values.get("fetch_response_stage") or 0),
        "mul": 1 if values.get("m_fast") else 3,
        "l1d_hit": 2,
        "complete_reg": 1,
        "mmio": 4,
        "pmem_fill": 8,
        "iq_reclaim": 0 if int(values.get("iq_reclaim_on_issue", 1)) == 1 else 1,
    }


def exec_spec(domain: str, kernel: str, cfg: dict[str, int]) -> tuple[str, int]:
    if domain == "mmio":
        return "soc_uart", cfg["mmio"]
    if domain == "memory" and kernel == "list":
        return "soc_pmem", cfg["pmem_fill"]
    if domain == "memory":
        return "rapt_l1d", cfg["l1d_hit"]
    if domain == "mul":
        return "rapt_ieu_muldiv", cfg["mul"]
    if domain == "fp":
        return "rapt_feu", 4
    return "rapt_ieu", 1


def iq_kind(domain: str) -> str:
    if domain in {"memory", "mmio"}:
        return "ioq"
    if domain == "mul":
        return "mdq"
    if domain == "branch":
        return "brq"
    if domain == "fp":
        return "fpq"
    return "alq"


def parse_regs(mnem: str, operands: str) -> tuple[str | None, list[str]]:
    names = REG_RE.findall(operands.lower())
    store = mnem.startswith(("sw", "sh", "sb", "sd", "c.sw", "c.sh", "c.sb"))
    branch = mnem.startswith(("b", "j", "c.b", "c.j")) or mnem in {"ret", "jalr", "jr"}
    if store or branch or mnem in {"ret"}:
        return None, names
    dest = names[0] if names else None
    srcs = names[1:] if store else names[1:]
    if dest == "zero":
        dest = None
    return dest, srcs


@dataclass
class Insn:
    idx: int
    asm: str
    mnemonic: str
    domain: str
    kernel: str
    dest: str | None
    srcs: list[str]
    loc: str | None = None
    committed: bool = False
    issued: bool = False
    store: bool = False
    control: bool = False
    iq: str | None = None


@dataclass
class Model:
    insns: list[Insn]
    cfg: dict[str, int]
    cycle: int = 0
    fetch_i: int = 0
    l1i: deque[tuple[int, int]] = field(default_factory=deque)
    ifu: deque[int] = field(default_factory=deque)
    fqu: deque[int] = field(default_factory=deque)
    idu: deque[int] = field(default_factory=deque)
    rnu: deque[int] = field(default_factory=deque)
    uoq: deque[int] = field(default_factory=deque)
    rob: deque[int] = field(default_factory=deque)
    alq: list[int] = field(default_factory=list)
    brq: list[int] = field(default_factory=list)
    mdq: list[int] = field(default_factory=list)
    ioq: list[int] = field(default_factory=list)
    fpq: list[int] = field(default_factory=list)
    executing: dict[int, tuple[str, int]] = field(default_factory=dict)
    completing: dict[int, int] = field(default_factory=dict)
    done: set[int] = field(default_factory=set)
    reclaim: dict[str, int] = field(default_factory=dict)
    ready_at: dict[str, int] = field(default_factory=dict)
    committed: list[int] = field(default_factory=list)

    def iq(self, kind: str) -> list[int]:
        return {"alq": self.alq, "brq": self.brq, "mdq": self.mdq, "ioq": self.ioq, "fpq": self.fpq}[kind]

    def iq_cap(self, kind: str) -> int:
        return {"alq": self.cfg["alq"], "brq": self.cfg["brq"], "mdq": self.cfg["mdq"], "ioq": self.cfg["ioq"], "fpq": self.cfg["fpq"]}[kind]

    def srcs_ready(self, insn: Insn) -> bool:
        return all(r in {"zero", "x0"} or self.ready_at.get(r, -1) <= self.cycle for r in insn.srcs)

    def occupancy(self) -> dict[str, list[int]]:
        occ: dict[str, list[int]] = {}

        def put(node: str, idx: int) -> None:
            occ.setdefault(node, []).append(idx)

        for idx, _ready in self.l1i:
            put("rapt_l1i", idx)
        for idx in self.ifu:
            put("rapt_ifu", idx)
        for idx in self.fqu:
            put("rapt_fqu", idx)
        for idx in self.idu:
            put("rapt_idu", idx)
        for idx in self.rnu:
            put("rapt_rnu", idx)
        for idx in self.uoq:
            put("rapt_prf", idx)
        for idx in self.rob:
            put("rapt_rou", idx)
        for idx in self.alq + self.brq:
            put("rapt_ieu", idx)
        for idx in self.mdq:
            put("rapt_ieu_muldiv", idx)
        for idx in self.fpq:
            put("rapt_feu", idx)
        for idx in self.ioq:
            put("rapt_lsu", idx)
        for idx, (node, _) in self.executing.items():
            put(node, idx)
            if node == "soc_pmem":
                put("rapt_l1d", idx)
                put("rapt_bus", idx)
                put("rapt_axi_master", idx)
            elif node == "soc_uart":
                put("rapt_lsu", idx)
                put("rapt_bus", idx)
                put("rapt_router", idx)
            elif node == "rapt_l1d":
                put("rapt_lsu", idx)
        for idx in self.completing:
            put("rapt_cdb_arb", idx)
        return occ

    def commit(self) -> None:
        n = 0
        saw_store = False
        saw_cf = False
        while self.rob and n < self.cfg["commit"]:
            idx = self.rob[0]
            insn = self.insns[idx]
            if idx not in self.done:
                break
            if insn.store and (saw_store or n):
                break
            if insn.control and saw_cf:
                break
            self.rob.popleft()
            insn.committed = True
            insn.loc = "rapt_cmu"
            self.committed.append(idx)
            n += 1
            if insn.store:
                saw_store = True
                break
            if insn.control:
                saw_cf = True
                break

    def complete(self) -> None:
        for idx, at in list(self.completing.items()):
            if at > self.cycle:
                continue
            self.completing.pop(idx)
            self.done.add(idx)
            insn = self.insns[idx]
            insn.loc = "rapt_rou"
            if insn.dest:
                self.ready_at[insn.dest] = self.cycle

    def execute(self) -> None:
        done = [idx for idx, (_, left) in self.executing.items() if left <= 1]
        for idx, (node, left) in list(self.executing.items()):
            if left > 1:
                self.executing[idx] = (node, left - 1)
        for idx in done:
            node, _ = self.executing.pop(idx)
            insn = self.insns[idx]
            insn.loc = "rapt_cdb_arb"
            if node == "rapt_ieu_muldiv":
                self.completing[idx] = self.cycle + self.cfg["complete_reg"]
            else:
                self.done.add(idx)
                if insn.dest:
                    self.ready_at[insn.dest] = self.cycle

    def issue(self) -> None:
        ports = {"alq": 2, "brq": 1, "mdq": 1, "ioq": 1, "fpq": 1}
        for kind, q in (("alq", self.alq), ("brq", self.brq), ("mdq", self.mdq), ("ioq", self.ioq), ("fpq", self.fpq)):
            issued = 0
            keep: list[int] = []
            for idx in q:
                insn = self.insns[idx]
                if issued < ports[kind] and self.srcs_ready(insn):
                    node, lat = exec_spec(insn.domain, insn.kernel, self.cfg)
                    self.executing[idx] = (node, max(lat, 1))
                    insn.issued = True
                    insn.loc = node
                    issued += 1
                    if self.cfg["iq_reclaim"]:
                        self.reclaim[kind] = self.reclaim.get(kind, 0) + 1
                else:
                    keep.append(idx)
            q[:] = keep

    def dispatch(self) -> None:
        moved = 0
        pending = [
            idx
            for idx in self.rob
            if not self.insns[idx].issued
            and idx not in self.executing
            and idx not in self.completing
            and idx not in self.done
            and self.insns[idx].iq is None
        ]
        for idx in pending:
            if moved >= self.cfg["dispatch"]:
                break
            insn = self.insns[idx]
            kind = iq_kind(insn.domain)
            q = self.iq(kind)
            if len(q) + self.reclaim.get(kind, 0) >= self.iq_cap(kind):
                continue
            q.append(idx)
            insn.iq = kind
            insn.loc = {"alq": "rapt_ieu", "brq": "rapt_ieu", "mdq": "rapt_ieu_muldiv", "fpq": "rapt_feu", "ioq": "rapt_lsu"}[kind]
            moved += 1
        self.reclaim.clear()

    def allocate(self) -> None:
        n = 0
        while self.uoq and n < self.cfg["dispatch"] and len(self.rob) < self.cfg["rob"]:
            idx = self.uoq.popleft()
            self.rob.append(idx)
            self.insns[idx].loc = "rapt_rou"
            self.insns[idx].iq = None
            n += 1

    def _move(self, src: deque[int], dst: deque[int], width: int, loc: str, cap: int) -> None:
        n = 0
        while src and n < width and len(dst) < cap:
            idx = src.popleft()
            dst.append(idx)
            self.insns[idx].loc = loc
            n += 1

    def rename(self) -> None:
        self._move(self.rnu, self.uoq, self.cfg["rename"], "rapt_prf", self.cfg["rob"])

    def decode(self) -> None:
        self._move(self.idu, self.rnu, self.cfg["decode"], "rapt_rnu", 8)

    def into_idu(self) -> None:
        self._move(self.fqu, self.idu, self.cfg["decode"], "rapt_idu", self.cfg["decode"])

    def into_fqu(self) -> None:
        self._move(self.ifu, self.fqu, self.cfg["decode"], "rapt_fqu", 2 * self.cfg["decode"])

    def fetch(self) -> None:
        w = self.cfg["decode"]
        delay = 1 + self.cfg["fetch_stage"]
        while self.l1i and self.l1i[0][1] <= self.cycle and len(self.ifu) < w:
            idx, _ = self.l1i.popleft()
            self.ifu.append(idx)
            self.insns[idx].loc = "rapt_ifu"
        while len(self.l1i) < w and self.fetch_i < len(self.insns):
            idx = self.fetch_i
            self.fetch_i += 1
            self.l1i.append((idx, self.cycle + delay))
            self.insns[idx].loc = "rapt_l1i"

    def step(self) -> dict[str, list[int]]:
        self.commit()
        self.complete()
        self.execute()
        self.issue()
        self.dispatch()
        self.allocate()
        self.rename()
        self.decode()
        self.into_idu()
        self.into_fqu()
        self.fetch()
        occ = self.occupancy()
        retiring = [i for i in self.committed[-self.cfg["commit"] :] if self.insns[i].loc == "rapt_cmu"]
        if retiring:
            occ.setdefault("rapt_cmu", []).extend(retiring)
        self.cycle += 1
        return occ

    def drained(self) -> bool:
        return (
            self.fetch_i >= len(self.insns)
            and not self.l1i
            and not self.ifu
            and not self.fqu
            and not self.idu
            and not self.rnu
            and not self.uoq
            and not self.rob
            and not self.executing
            and not self.completing
            and all(i.committed for i in self.insns)
        )


def simulate(instructions: list[dict[str, Any]], values: dict[str, Any], max_cycles: int = 2048) -> dict[str, Any]:
    cfg = _cfg(values)
    insns: list[Insn] = []
    for i, src in enumerate(instructions):
        mnem = src.get("mnemonic") or ""
        operands = src.get("operands") or ""
        dest, srcs = parse_regs(mnem, operands)
        domain = src.get("domain") or "integer"
        insns.append(
            Insn(
                idx=i,
                asm=src.get("asm") or mnem,
                mnemonic=mnem,
                domain=domain,
                kernel=src.get("kernel") or "",
                dest=dest,
                srcs=srcs,
                store=domain in {"memory", "mmio"} and mnem.startswith(("s", "c.s")),
                control=domain == "branch",
            )
        )
    model = Model(insns=insns, cfg=cfg)
    frames: list[dict[str, Any]] = []
    while model.cycle < max_cycles:
        occ = model.step()
        frames.append({"t": model.cycle - 1, "occ": {k: v for k, v in occ.items() if v}})
        if model.drained():
            break
    if not all(i.committed for i in insns):
        raise RuntimeError(f"pipeline model stalled at cycle {model.cycle}")
    commits = len(model.committed)
    cycles = max(model.cycle, 1)
    return {
        "kind": "contract-cycle",
        "cycles": cycles,
        "committed": commits,
        "ipc": round(commits / cycles, 3),
        "widths": {k: cfg[k] for k in ("decode", "rename", "dispatch", "commit")},
        "notes": [
            "Illustrative cycle model; not timing-equivalent to current RTL or NPC/Verilator.",
            "Listing order; branches do not redirect, so this is not CoreMark IPC.",
            "FQU/IDU/RNU/UOQ are registered queues with no empty-queue bypass.",
            "IQ issue uses a register scoreboard from the dump; issued slots free next cycle.",
            "Model adds one completion cycle to all ports; current RTL bypasses it on integer endpoints. L1D is hit-only here; MSHR replay is not modeled.",
        ],
        "frames": frames,
    }
