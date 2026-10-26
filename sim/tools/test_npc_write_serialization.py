#!/usr/bin/env python3
"""Exercise the NPC memory endpoint's optional write serialization, both XLENs."""

import argparse
from pathlib import Path
import subprocess


DRIVER = r'''
#include "Vrapt_npc_soc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static unsigned serialize;
extern "C" unsigned npc_mem_serialize_writes() { return serialize; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  serialize = argc > 1 ? std::strtoul(argv[1], nullptr, 10) : 0;
  Vrapt_npc_soc d;
  auto check = [&](bool ok, const char *why) {
    if (!ok) { std::fprintf(stderr, "FAIL mode=%u: %s\n", serialize, why); std::exit(1); }
  };
  auto tick = [&]() { d.clock=0; d.eval(); d.clock=1; d.eval(); };
  d.clock=0; d.reset=1; d.arvalid=0; d.awvalid=0; d.wvalid=0;
  d.rready=0; d.bready=0; d.araddr=0x80000000; d.arsize=2;
  d.arlen=0; d.arburst=1; d.arid=9; d.awaddr=0x80000008;
  d.awsize=2; d.awlen=0; d.awburst=1; d.awid=3;
  d.wdata=0x12345678; d.wstrb=15; d.wlast=1;
  tick(); tick(); d.reset=0; d.eval();
  check(d.out_awready, "initial AW admission");
  d.awvalid=1; tick(); d.awvalid=0;
  check(d.out_wready && !d.out_awready, "first AW owns W slot");
  d.wvalid=1; tick(); d.wvalid=0;
  check(bool(d.out_awready) == !serialize, "AW policy during B latency");
  // Present the follower before B becomes valid. Default mode captures AW,
  // strict mode must retain backpressure through the B handshake edge.
  d.awid=4; d.awaddr=0x80000010; d.awvalid=1;
  tick();
  if (!serialize) d.awvalid=0;
  check(d.out_wready, "empty W buffer accepts one early follower");
  d.wdata=0x87654321; d.wvalid=1; tick(); d.wvalid=0;
  check(!d.out_wready, "full W buffer backpressures a second follower");
  // Reads stay independent of write response backpressure.
  d.arvalid=1; tick(); d.arvalid=0;
  for (unsigned i=0; i<12; ++i) {
    tick();
    check(!d.out_awready && !d.out_wready, "write ownership while B stalls");
    if (i>=3) {
      check(d.out_bvalid && d.out_bid==3 && d.out_bresp==0, "first B stable");
      check(d.out_rvalid && d.out_rid==9, "independent read completion");
    }
  }
  d.rready=1; d.bready=1; d.eval();
  check(bool(d.out_awready) == !serialize, "strict AW waits through B handshake");
  check(bool(d.out_wready) == !serialize, "buffer may advance with B dequeue");
  tick();
  check(!d.out_bvalid, "first B consumed exactly once");
  if (serialize) {
    check(d.out_awready && !d.out_wready, "strict AW opens with follower W buffered");
    tick(); d.awvalid=0;
  }
  check(d.out_wready, "buffered follower serviced once ownership opens");
  d.bready=0;
  for (unsigned i=0; i<8; ++i) tick();
  check(d.out_bvalid && d.out_bid==4 && d.out_bresp==0, "follower response identity");
  d.bready=1; tick();
  check(!d.out_bvalid && d.out_awready, "all writes drained");
  // A multi-beat write retains AW ownership until its final beat and B.
  d.awlen=1; d.awid=5; d.awvalid=1; tick(); d.awvalid=0;
  d.wvalid=1; d.wlast=0; tick(); d.wvalid=0; d.eval();
  check(!d.out_awready && !d.out_bvalid && d.out_wready, "burst ownership");
  d.wvalid=1; d.wlast=1; tick(); d.wvalid=0; d.bready=0;
  check(bool(d.out_awready)==!serialize, "burst final beat applies AW policy");
  for (unsigned i=0; i<8; ++i) tick();
  check(d.out_bvalid && d.out_bid==5, "burst response");
  d.bready=1; tick();
  check(!d.out_bvalid && d.out_awready, "burst drained");
  std::printf("PASS runtime serialize=%u: delayed/stalled B, AW/W ownership, reads, bursts\n", serialize);
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    mock = out / "mock"
    mock.mkdir()
    data = (root / "rtl/include/dpic_mock/rapt_dpi_c.svh").read_text()
    data += "\n`undef RAPT_DPI_C_MEM_READ_LATENCY\n`define RAPT_DPI_C_MEM_READ_LATENCY(rval) rval = 2\n"
    data += "`undef RAPT_DPI_C_MEM_WRITE_LATENCY\n`define RAPT_DPI_C_MEM_WRITE_LATENCY(rval) rval = 3\n"
    (mock / "rapt_dpi_c.svh").write_text(data)
    driver = out / "main.cpp"
    driver.write_text(DRIVER)
    for xlen in (32, 64):
        obj = out / f"obj{xlen}"
        command = ["verilator", "--cc", "--exe", "--build", "-j", "2",
                   "--top-module", "rapt_npc_soc", "--Mdir", str(obj)]
        if xlen == 64:
            command += ["-DRAPT_RV64"]
        command += [f"-I{mock}"]
        command += [f"-I{root / p}" for p in
                    ("rtl/configs/small-cache", "rtl/include", "rtl/include/npc")]
        command += [str(root / "sim/rtl/rapt_npc_soc.sv"), str(driver)]
        with (out / f"build{xlen}.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        for mode in (0, 1):
            result = subprocess.run([str(obj / "Vrapt_npc_soc"), str(mode)],
                                    text=True, capture_output=True)
            (out / f"rv{xlen}-mode{mode}.log").write_text(result.stdout + result.stderr)
            print(f"RV{xlen}: {result.stdout.strip()}", flush=True)
            result.check_returncode()


if __name__ == "__main__":
    main()
