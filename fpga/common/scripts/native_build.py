#!/usr/bin/env python3
"""Reproducible native FPGA builds."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

COMMON = Path(__file__).resolve().parents[1]
REPO = COMMON.parents[1]
from rtl_pack import pack

BOARD = PROFILE = None


def configure(board):
    global BOARD, PROFILE
    BOARD = Path(board).resolve()
    PROFILE = json.loads((BOARD / "board.json").read_text())


def board_parser():
    """Parse --board first, because the board profile supplies other defaults."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--board", type=Path, help="board directory containing board.json")
    args, _ = parser.parse_known_args()
    if args.board:
        configure(args.board)
    elif BOARD is None:
        parser.error("--board is required")
    return parser


def run(command, *, cwd=None, log=None):
    print("+", " ".join(map(str, command)), flush=True)
    if log:
        with Path(log).open("w") as dest:
            result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=dest, stderr=subprocess.STDOUT)
        if result.returncode:
            print(Path(log).read_text()[-12000:], file=sys.stderr)
            raise subprocess.CalledProcessError(result.returncode, command)
    else:
        subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def write_reports(out, failed=False):
    """Keep an offline HTML dashboard and a short resource summary with each run."""
    command = [sys.executable, COMMON / "scripts/vivado_reports_index.py", out,
               "--title", f"Native FPGA reports - {BOARD.name} / {out.name}"]
    if failed:
        command.append("--build-failed")
    run(command)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tcl(value):
    value = str(value)
    if any(c in value for c in "{}\n\r"):
        raise ValueError(f"Unsupported Tcl path/value: {value!r}")
    return "{" + value + "}"


def configuration(args):
    result = {key: getattr(args, key) for key in (
        "xlen", "preset", "memory", "clock_mhz", "ram_bytes", "reset_button", "ddr_part", "cross", "ethernet"
    )}
    if PROFILE.get("cm005_bridge"):
        result["cm005_bridge"] = args.cm005_bridge
        result["cm005_ethernet"] = args.cm005_ethernet
    return result


def input_hashes(cm005_bridge=False):
    files = []
    extensions = {".sv", ".svh", ".py", ".c", ".h", ".S", ".tcl", ".xdc", ".json"}
    for root in (REPO / "hdl", REPO / "sim/include", REPO / "sim/rtl", COMMON, BOARD):
        # Prune generated trees before traversal: Ubuntu rootfs/kernel caches can
        # contain hundreds of thousands of files and are never source inputs.
        for directory, children, names in os.walk(root):
            parent = Path(directory)
            children[:] = [name for name in children
                           if name not in {"build", "tests", "__pycache__"} and
                           parent / name != REPO / "hdl/chisel/target"]
            files += [parent / name for name in names
                      if Path(name).suffix in extensions and (parent / name).is_file()]
    if cm005_bridge:
        bridge_sources = (
            "cm005_native.py", "cm005_bridge.py", "cm005_bridge_queue.py", "cm005_switch.py", "cm005.py",
            "cm005_oversample.py", "cm005_timing.py", "usp_clock.py", "ku15p_soc.py",
            "mlk_cu08_ku15p.py", "mlk_cu08_ku15p_platform.py",
            "cores/cpu/raptor/core.py", "cores/cpu/raptor/__init__.py",
            "scripts/check_cm005_aperture.tcl")
        files += [REPO / "fpga/litex" / name for name in bridge_sources]
        for name in ("migen", "litex", "liteeth", "litedram"):
            root = REPO / "third_party/enjoy-digital" / name
            dependency_sources = sorted(root.rglob("*.py"))
            if not dependency_sources:
                raise RuntimeError(f"Missing bridge generator dependency: {root}")
            files += dependency_sources
    return {str(p.relative_to(REPO)): sha(p) for p in sorted(set(files))}


def identity(args):
    data = {"configuration": configuration(args), "inputs": input_hashes(getattr(args, "cm005_bridge", 0))}
    data["sha256"] = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
    data["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    return data


def region_map():
    raw = json.loads((REPO / "hdl/configs/memory_map.json").read_text())
    return {name: {key: int(value, 0) for key, value in reg.items()} for name, reg in raw["regions"].items()}


def write_map(args, out):
    regions = region_map()
    values = {}
    for source, name in (("mrom", "Rom"), ("sram", "Sram"), ("ns16550", "Uart"), ("main_ram", "Ram")):
        values[name + "Base"] = regions[source]["base"]
        if "size" in regions[source]:
            values[name + "Bytes"] = regions[source]["size"]
    # RV32 uses the existing 1 GiB Linux profile, RV64 maps the full 2 GiB.
    profile = json.loads((REPO / "hdl/configs/memory_map.json").read_text())["profiles"]["ku15p_mig"]
    values["DdrBytes"] = int(profile["rv32_linux_size" if args.xlen == 32 else "ram_size"], 0)
    (out / "sources/native_map.sv").write_text("package rapt_native_map_pkg;\n" + "".join(
        f"  localparam longint unsigned {name} = 64'h{value:x};\n" for name, value in values.items()
    ) + "endpackage\n")
    ram_bytes = args.ram_bytes if args.memory == "bram" else values["DdrBytes"]
    divisor = (args.clock_mhz * 1_000_000 + 115200 * 8) // (115200 * 16)
    (out / "native_map.h").write_text(
        f'#define NATIVE_BOARD_STRING "{PROFILE["banner"]}"\n'
        f"#define UART_BASE 0x{values['UartBase']:x}u\n"
        f"#define RAM_BASE 0x{values['RamBase']:x}u\n#define RAM_BYTES 0x{ram_bytes:x}u\n"
        f"#define UART_DIVISOR {divisor}u\n#define NATIVE_XLEN_STRING \"{args.xlen}\"\n"
    )
    (out / "boot.ld").write_text(f"""OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {{
  rom (rx) : ORIGIN = 0x{values['RomBase']:x}, LENGTH = 0x{values['RomBytes']:x}
  sram (rw) : ORIGIN = 0x{values['SramBase']:x}, LENGTH = 0x{values['SramBytes']:x}
}}
SECTIONS {{
  .text : {{ KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) }} > rom
  .data : {{ *(.data*) *(.sdata*) }} > sram
  ASSERT(SIZEOF(.data) == 0, "boot ROM cannot have initialized writable data")
  .bss (NOLOAD) : {{ . = ALIGN(8); _bss_start = .; *(.bss*) *(.sbss*) *(COMMON)
                    . = ALIGN(8); _bss_end = .; }} > sram
  __global_pointer$ = ORIGIN(sram) + 0x800;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
  ASSERT(_bss_end <= _stack_top - 2048, "boot stack has less than 2 KiB")
  /DISCARD/ : {{ *(.comment*) *(.eh_frame*) }}
}}
""")
    return values, ram_bytes


def firmware(args, out, values):
    isa = f"rv{args.xlen}imac_zicsr_zifencei"
    abi = "ilp32" if args.xlen == 32 else "lp64"
    flags = [f"-march={isa}", f"-mabi={abi}", "-mcmodel=medany", "-Os", "-g", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-msmall-data-limit=0", "-nostdlib", "-Werror", "-Wall",
             "-Wextra", "-Wl,--build-id=none", "-Wl,--no-relax"]
    run([args.cross + "gcc", *flags, "-I", out, "-T", out / "boot.ld",
         COMMON / "firmware/start.S", COMMON / "firmware/boot.c", "-o", out / "boot.elf"])
    run([args.cross + "objcopy", "-O", "binary", out / "boot.elf", out / "boot.bin"])
    data = (out / "boot.bin").read_bytes()
    if len(data) > values["RomBytes"]:
        raise ValueError("boot ROM overflow")
    data = data.ljust(values["RomBytes"], b"\0")
    width = args.xlen // 8
    (out / "boot.hex").write_text("".join(
        f"{int.from_bytes(data[i:i + width], 'little'):0{width * 2}x}\n" for i in range(0, len(data), width)
    ))
    run([args.cross + "gcc", *flags, "-Wl,-Ttext=0x80000000", "-Wl,-e,_start",
         COMMON / "firmware/payload.S", "-o", out / "payload.elf"])
    run([args.cross + "objcopy", "-O", "binary", out / "payload.elf", out / "payload.bin"])
    (out / "payload.hex").write_text("".join(f"{b:02x}\n" for b in (out / "payload.bin").read_bytes()))


def device_tree(args, out, ram_bytes):
    reg = region_map()
    ethernet = ""
    if getattr(args, "ethernet", 0):
        ethernet = '''
        ethernet@18000000 {
            compatible = "raptor,native-ethernet-v1";
            reg = <0 0x18000000 0 0x10000>;
            interrupt-parent = <&plic>; interrupts = <2>;
            local-mac-address = [02 52 41 50 05 01];
            phy-mode = "rgmii-txid";
            phy-handle = <&eth_phy>;
            mdio {
                #address-cells = <1>; #size-cells = <0>;
                eth_phy: ethernet-phy@1 { reg = <1>; };
            };
        };
'''
    if getattr(args, "cm005_bridge", 0):
        ethernet = '''
        bridge@18000000 {
            compatible = "raptor,cm005-forwarder-v1";
            reg = <0 0x18000000 0 0x1000>;
        };
'''
    if getattr(args, "cm005_ethernet", 0):
        layout = PROFILE["cm005_cpu_ethernet"]
        base = {key: int(layout[key], 0) for key in ("phy_base", "csr_base", "buffer_base")}
        mac = layout["mac"].replace(":", " ")
        buffer_bytes = (layout["rx_slots"] + layout["tx_slots"]) * layout["slot_size"]
        ethernet += f'''
        ethernet@{base['csr_base']:x} {{
            compatible = "litex,liteeth";
            reg = <0 0x{base['csr_base']:x} 0 0x100>,
                  <0 0x{base['phy_base']:x} 0 4>,
                  <0 0x{base['buffer_base']:x} 0 0x{buffer_bytes:x}>;
            reg-names = "mac", "mdio", "buffer";
            interrupt-parent = <&plic>; interrupts = <2>;
            local-mac-address = [{mac}];
            litex,rx-slots = <{layout['rx_slots']}>;
            litex,tx-slots = <{layout['tx_slots']}>;
            litex,slot-size = <{layout['slot_size']}>;
        }};
'''
    def cells(name):
        return f"0 0x{reg[name]['base']:x} 0 0x{reg[name]['size']:x}"
    isa = f"rv{args.xlen}imafdc_zicsr_zifencei_zicntr"
    text = f"""/dts-v1/;
/ {{
    #address-cells = <2>;
    #size-cells = <2>;
    compatible = "{PROFILE['compatible']}";
    model = "{PROFILE['model']}";
    aliases {{ serial0 = &uart; }};
    chosen {{ stdout-path = "serial0:115200n8";
              bootargs = "console=ttyS0,115200 earlycon=sbi"; }};
    cpus {{
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <1000000>;
        cpu@0 {{
            device_type = "cpu"; reg = <0>; status = "okay"; compatible = "riscv";
            riscv,isa = "{isa}";
            riscv,isa-base = "rv{args.xlen}i";
            riscv,isa-extensions = "i", "m", "a", "f", "d", "c", "zicsr", "zifencei", "zicntr";
            mmu-type = "riscv,sv{'32' if args.xlen == 32 else '39'}";
            clock-frequency = <{args.clock_mhz * 1_000_000}>;
            cpu_intc: interrupt-controller {{
                #address-cells = <0>; #interrupt-cells = <1>;
                interrupt-controller; compatible = "riscv,cpu-intc";
            }};
        }};
    }};
    memory@{reg['main_ram']['base']:x} {{ device_type = "memory";
        reg = <0 0x{reg['main_ram']['base']:x} 0 0x{ram_bytes:x}>; }};
    soc {{
        #address-cells = <2>; #size-cells = <2>; compatible = "simple-bus"; ranges;
        clint@{reg['clint']['base']:x} {{ compatible = "riscv,clint0";
            reg = <{cells('clint')}>; interrupts-extended = <&cpu_intc 3 &cpu_intc 7>; }};
        plic: interrupt-controller@{reg['plic']['base']:x} {{
            compatible = "riscv,plic0"; reg = <{cells('plic')}>;
            #address-cells = <0>; #interrupt-cells = <1>; interrupt-controller;
            interrupts-extended = <&cpu_intc 11 &cpu_intc 9>; riscv,ndev = <31>;
        }};
        uart: serial@{reg['ns16550']['base']:x} {{ compatible = "ns16550a";
            reg = <{cells('ns16550')}>; clock-frequency = <{args.clock_mhz * 1_000_000}>;
            current-speed = <115200>; reg-shift = <0>; reg-io-width = <1>;
            interrupt-parent = <&plic>; interrupts = <1>;
            fifo-size = <1>; tx-threshold = <0>; no-loopback-test;
        }};
{ethernet}
    }};
}};
"""
    (out / "native.dts").write_text(text)
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", out / "native.dtb", out / "native.dts"])


def peripheral_wrapper(args, out):
    """Flatten the two AXI interfaces for an independent platform OOC run."""
    master_outputs = set("araddr arid arlen arsize arburst arcache arvalid rready "
                         "awaddr awid awlen awsize awburst awcache awvalid wdata wstrb wlast wvalid bready".split())
    widths = {"araddr": args.xlen, "arid": 4, "arlen": 8, "arsize": 3, "arburst": 2, "arcache": 4,
              "arvalid": 1, "arready": 1, "rid": 4, "rdata": args.xlen, "rresp": 2, "rlast": 1,
              "rvalid": 1, "rready": 1, "awaddr": args.xlen, "awid": 4, "awlen": 8, "awsize": 3,
              "awburst": 2, "awcache": 4, "awvalid": 1, "awready": 1, "wdata": args.xlen,
              "wstrb": args.xlen // 8, "wlast": 1, "wvalid": 1, "wready": 1, "bid": 4,
              "bresp": 2, "bvalid": 1, "bready": 1}
    ports = ["input wire clk, reset, uart_rx", "output wire uart_tx, uart_irq",
             "output wire peripheral_rd, peripheral_wr",
             "output wire [15:0] peripheral_raddr, peripheral_waddr",
             "output wire [31:0] peripheral_wdata", "output wire [3:0] peripheral_wstrb",
             "input wire [31:0] peripheral_rdata"]
    assignments = []
    for interface in ("cpu", "ddr"):
        for field, width in widths.items():
            is_input = (field in master_outputs) == (interface == "cpu")
            direction = "input" if is_input else "output"
            vector = f"[{width - 1}:0] " if width > 1 else ""
            ports.append(f"{direction} wire {vector}{interface}_{field}")
            lhs, rhs = f"{interface}.{field}", f"{interface}_{field}"
            if not is_input:
                lhs, rhs = rhs, lhs
            assignments.append(f"assign {lhs} = {rhs};")
    text = "module rapt_native_bus_syn_top (\n" + ",\n".join(ports) + ");\n"
    text += f"axi4_if #(.XLEN({args.xlen})) cpu(), ddr();\n" + "\n".join(assignments)
    text += f"""
rapt_native_bus #(.XLEN({args.xlen}), .WithDdr({int(args.memory == 'ddr')}),
    .WithPeripheral({int(bool(args.ethernet or args.cm005_bridge))}),
    .RamBytes({args.ram_bytes}), .ClockHz({args.clock_mhz * 1_000_000}),
    .RomFile({json.dumps(str(out / 'boot.hex'))})) bus (
    .clk, .reset, .uart_rx, .uart_tx, .uart_irq, .cpu, .ddr,
    .peripheral_rd, .peripheral_wr, .peripheral_raddr, .peripheral_waddr,
    .peripheral_wdata, .peripheral_wstrb, .peripheral_rdata);
endmodule
"""
    (out / "sources/peripheral_top.sv").write_text(text)


def prepare(args, out):
    before = identity(args)
    sources = out / "sources"
    sources.mkdir(exist_ok=True)
    values, ram_bytes = write_map(args, out)
    firmware(args, out, values)
    device_tree(args, out, ram_bytes)
    flags = ("-DRAPT_RV64 " if args.xlen == 64 else "") + (
        f"-DRAPT_FPGA_DSP=1 -DRAPT_FPGA_LUTRAM=1 -DRAPT_CORE_CLOCK_MHZ={args.clock_mhz} "
        f"-DRAPT_MTIME_FREQ_MHZ=1 -DRAPT_PMEM_BYTES={ram_bytes}"
    )
    packed = pack(REPO, args.build_root / "rtl-cache", args.preset, flags, immutable=True)
    for name in ("rapt_pack.sv", "rapt_pack.svh"):
        shutil.copyfile(packed.parent / name, sources / name)
    for root in (COMMON / "rtl", BOARD / "rtl", BOARD / "constraints", BOARD / "ip"):
        for path in root.iterdir():
            if path.is_file():
                shutil.copyfile(path, sources / path.name)
    if args.ethernet:
        for path in (BOARD / "vendor/ethernet").glob("*"):
            if path.is_file():
                shutil.copyfile(path, sources / path.name)
    if args.cm005_bridge:
        generated = out / "cm005-generated"
        command = [args.bridge_python, REPO / "fpga/litex/cm005_native.py", "--output", generated]
        if args.cm005_ethernet:
            command += ["--with-cpu-ethernet"]
        run(command,
            log=out / "cm005-generation.log")
        for path in generated.iterdir():
            if path.is_file():
                shutil.copyfile(path, sources / path.name)
    config = f"""`define RAPT_XLEN {args.xlen}
`define NATIVE_BOARD_STRING "{PROFILE['banner']}"
`define NATIVE_CLOCK_HZ {args.clock_mhz * 1_000_000}
`define NATIVE_DDR {int(args.memory == 'ddr')}
`define NATIVE_ETHERNET {args.ethernet}
`define NATIVE_CM005_BRIDGE {args.cm005_bridge}
`define NATIVE_CM005_ETHERNET {args.cm005_ethernet}
`define NATIVE_RAM_BYTES {args.ram_bytes}
`define NATIVE_USE_RESET_BUTTON {args.reset_button}
`define NATIVE_ROM_FILE "{out / 'boot.hex'}"
"""
    if args.memory == "ddr":
        config += "`define NATIVE_WITH_DDR\n"
    if args.ethernet:
        config += "`define NATIVE_WITH_ETHERNET\n"
    if args.cm005_bridge:
        config += "`define NATIVE_WITH_CM005_BRIDGE\n"
    (sources / "native_config.svh").write_text(config)
    names = ["native_config.svh", "rapt_pack.sv", "native_map.sv",
             "rapt_native_uart.sv", "rapt_native_bus.sv", "rapt_native_soc.sv"]
    (sources / "soc_sources.sv").write_text("".join(f'`include "{name}"\n' for name in names))
    eth_names = ["rgmii_lfsr.sv", "axis_gmii_rx.sv", "axis_gmii_tx.sv", "eth_mac_1g.sv",
                 "rapt_native_eth.sv", "rapt_rk_rgmii_rx.sv", "rapt_rk_ethernet.sv"] if args.ethernet else []
    (sources / "ethernet_sources.sv").write_text("".join(f'`include "{name}"\n' for name in eth_names))
    names = ["soc_sources.sv"]
    if args.memory == "ddr":
        names.append(PROFILE["ddr_rtl"])
    names += eth_names
    if args.cm005_bridge:
        names.append("rapt_cm005_bridge.v")
    names.append(PROFILE["top"] + ".sv")
    (sources / "board_sources.sv").write_text("".join(f'`include "{name}"\n' for name in names))
    peripheral_wrapper(args, out)
    cfg = {"out": out, "xlen": args.xlen, "with_ddr": int(args.memory == "ddr"),
           "with_ethernet": args.ethernet, "with_cm005_bridge": args.cm005_bridge,
           "ddr_part": args.ddr_part, "jobs": args.jobs, "clock_mhz": args.clock_mhz,
           **{key: PROFILE[key] for key in ("part", "top", "bitstream", "ddr_clock_port", "reference_hz")}}
    (out / "config.tcl").write_text("".join(f"set {key} {tcl(value)}\n" for key, value in cfg.items()))
    if identity(args)["sha256"] != before["sha256"]:
        raise RuntimeError("Source files changed during prepare; retry to obtain a coherent build")
    before["artifacts"] = {str(p.relative_to(out)): sha(p) for p in sorted(sources.iterdir()) if p.is_file()}
    for name in ("boot.elf", "boot.bin", "boot.hex", "native.dtb", "native.dts", "config.tcl"):
        before["artifacts"][name] = sha(out / name)
    (out / "manifest.json").write_text(json.dumps(before, indent=2) + "\n")
    return before


def verilator(args, out, top, testbench=None, binary=False):
    command = ["verilator", "--binary" if binary else "--lint-only", "--timing", "--assert", "-Wno-fatal",
               "--top-module", top, "-I" + str(out / "sources"), "-I" + str(REPO / "hdl/include"),
               "-I" + str(REPO / "hdl/include/npc"), "-I" + str(COMMON / "tests"), out / "sources/soc_sources.sv"]
    if testbench:
        command += [testbench]
    if binary:
        command += ["-j", str(args.jobs), "--Mdir", out / ("obj_" + top)]
    if args.trace:
        command += ["--trace", "--trace-depth", "1"]
    run(command, log=out / (top + "-compile.log"))
    if binary:
        run([out / ("obj_" + top) / ("V" + top), "+PAYLOAD=" + str(out / "payload.hex"),
             "+PAYLOAD_SIZE=" + str((out / "payload.bin").stat().st_size),
             *(["+TRACE"] if args.trace else [])], cwd=out, log=out / (top + ".log"))
        print((out / (top + ".log")).read_text()[-4000:])


def validated_result(out):
    saved = json.loads((out / "result.json").read_text())
    for name, digest in saved["artifacts"].items():
        if sha(out / name) != digest:
            raise RuntimeError(f"Build artifact changed after validation: {name}")
    if not saved.get("timing_pass"):
        raise RuntimeError("A passing routed timing gate is required before loading")
    return saved


def validate_load(args, out):
    saved = validated_result(out)
    if saved["identity"] != identity(args)["sha256"]:
        raise RuntimeError("Sources/configuration differ from the routed bitstream; rebuild before loading")


def hardware_inputs(manifest):
    """Exact inputs consumed by Vivado; the separately uploaded DTB is excluded."""
    # prepare copies both board variants, but BRAM's compilation unit and Tcl
    # never read the DDR-only files. Preserve that small-to-large build boundary.
    unused = set()
    if manifest["configuration"]["memory"] == "bram":
        unused = {"sources/" + PROFILE["ddr_rtl"], "sources/ddr4.xdc", "sources/create_ip.tcl"}
    artifacts = {name: digest for name, digest in manifest["artifacts"].items()
                 if (name.startswith("sources/") or name in ("boot.hex", "config.tcl")) and name not in unused}
    required = {"sources/board_sources.sv", "sources/rapt_pack.sv", "boot.hex", "config.tcl"}
    if not required <= artifacts.keys():
        raise RuntimeError("Incomplete hardware snapshot; a full build is required")
    return {"configuration": manifest["configuration"], "artifacts": artifacts,
            "build_script": manifest["inputs"]["fpga/common/scripts/native_build.tcl"]}


def refresh_software(args, out):
    """Refresh software only if every exported hardware input remains identical."""
    saved = validated_result(out)
    previous = json.loads((out / "manifest.json").read_text())
    if saved["artifacts"].get("manifest.json") != sha(out / "manifest.json") or \
            saved["identity"] != previous["sha256"]:
        raise RuntimeError("Missing matching implementation manifest; a full build is required")
    prior_inputs = hardware_inputs(previous)
    # Keep the actual implemented revision separately from refreshed software.
    if "implemented_manifest.json" not in saved["artifacts"]:
        shutil.copyfile(out / "manifest.json", out / "implemented_manifest.json")
        saved["artifacts"]["implemented_manifest.json"] = sha(out / "implemented_manifest.json")
        saved["implementation_identity"] = saved["identity"]
    # A failed refresh must leave no loadable stamp referring to mixed inputs.
    (out / "result.json").unlink()
    current = prepare(args, out)
    if hardware_inputs(current) != prior_inputs:
        raise RuntimeError("Hardware inputs changed; a full build is required")
    for name, digest in saved["artifacts"].items():
        if name != "manifest.json" and sha(out / name) != digest:
            raise RuntimeError(f"Implementation artifact changed during refresh: {name}")
    saved["identity"] = current["sha256"]
    saved["artifacts"]["manifest.json"] = sha(out / "manifest.json")
    saved["software_refresh"] = "byte-identical hardware inputs"
    (out / "result.json").write_text(json.dumps(saved, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, parents=[board_parser()])
    parser.add_argument("action", choices=("prepare", "refresh-software", "lint", "test", "sim", "ip-check", "peripheral-synth",
                                          "synth", "build", "load", "info"))
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=64)
    parser.add_argument("--preset", default="small")
    parser.add_argument("--memory", choices=("bram", "ddr"), default=PROFILE.get("default_memory", "bram"))
    parser.add_argument("--clock-mhz", type=int, choices=(25, 50, 100), default=50)
    parser.add_argument("--ram-bytes", type=int, default=131072)
    parser.add_argument("--reset-button", type=int, choices=(0, 1), default=0)
    parser.add_argument("--ethernet", type=int, choices=(0, 1), default=0,
                        help="enable native gigabit Ethernet on supported boards")
    parser.add_argument("--cm005-bridge", type=int, choices=(0, 1), default=PROFILE.get("cm005_bridge", 0),
                        help="retain independent CM005 A/B forwarding on CU08 (50 MHz)")
    parser.add_argument("--cm005-ethernet", type=int, choices=(0, 1), default=0,
                        help="attach the native CPU to CM005 while retaining A/B forwarding")
    parser.add_argument("--bridge-python", default=str(REPO / "fpga/litex/.venv/bin/python"),
                        help="Python environment for the pinned CM005 Migen/LiteEth generator")
    parser.add_argument("--ddr-part", default=PROFILE["ddr_part"])
    parser.add_argument("--cross", default="riscv64-unknown-elf-")
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--hw-target", help="optional exact JTAG target glob, e.g. */0ABC01A")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--trace", action="store_true", help="capture the focused boot AXI waveform")
    parser.add_argument("--build-root", type=Path, default=BOARD / "build")
    args = parser.parse_args()
    if args.ethernet and not PROFILE.get("ethernet"):
        parser.error("native Ethernet is not supported by this board")
    if args.cm005_bridge and not PROFILE.get("cm005_bridge"):
        parser.error("CM005 forwarding is not supported by this board")
    if args.cm005_ethernet and not (args.cm005_bridge and PROFILE.get("cm005_cpu_ethernet")):
        parser.error("CM005 CPU Ethernet requires this board's CM005 forwarder")
    if args.cm005_bridge and args.clock_mhz != 50:
        parser.error("CM005 forwarding currently requires CLOCK_MHZ=50; disable it explicitly for other clocks")
    if args.jobs <= 0 or args.jobs > 32:
        parser.error("jobs must be between 1 and 32")
    if args.ram_bytes < 16384 or args.ram_bytes > 1048576 or args.ram_bytes & (args.ram_bytes - 1):
        parser.error("BRAM size must be a power of two between 16 KiB and 1 MiB")
    if not args.preset.replace("_", "").replace("-", "").isalnum():
        parser.error("invalid preset name")
    args.build_root = args.build_root.resolve()
    suffix = hashlib.sha256(json.dumps(configuration(args), sort_keys=True).encode()).hexdigest()[:10]
    out = args.build_root / f"rv{args.xlen}-{args.preset}-{args.memory}-{args.clock_mhz}MHz-{suffix}"
    if args.action == "info":
        print(json.dumps({"configuration": configuration(args), "output": str(out)}, indent=2))
        return
    out.mkdir(parents=True, exist_ok=True)
    with (out / ".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "load":
            validate_load(args, out)
            run([args.vivado, "-mode", "batch", "-source", COMMON / "scripts/vivado_load.tcl",
                 "-tclargs", out / PROFILE["bitstream"], PROFILE["device"],
                 *([args.hw_target] if args.hw_target else [])], cwd=out)
            return
        if args.action == "refresh-software":
            refresh_software(args, out)
            print(f"refresh-software: PASS ({out})")
            return
        manifest = prepare(args, out)
        if args.action == "lint":
            verilator(args, out, "rapt_native_soc")
        elif args.action == "test":
            run([sys.executable, "-m", "unittest", "discover", "-s", COMMON / "tests", "-p", "test_*.py", "-v"])
            for top in ("tb_native_bus", "tb_native_uart"):
                verilator(args, out, top, COMMON / "tests" / (top + ".sv"), binary=True)
        elif args.action == "sim":
            verilator(args, out, "tb_native_boot", COMMON / "tests/tb_native_boot.sv", binary=True)
        elif args.action in ("ip-check", "peripheral-synth", "synth", "build"):
            # Never let a failed new run leave an old loadable result stamp.
            if args.action == "build":
                (out / "result.json").unlink(missing_ok=True)
                (out / "timing.pass").unlink(missing_ok=True)
                for name in ("utilization.rpt", "utilization_summary.rpt", "timing_summary.rpt",
                             "check_timing.rpt", "cdc.rpt", "drc.rpt", "route_status.rpt"):
                    (out / name).unlink(missing_ok=True)
            if args.action in ("build", "synth"):
                for name in ("synth_utilization.rpt", "synth_utilization_summary.rpt", "synth_timing.rpt"):
                    (out / name).unlink(missing_ok=True)
            try:
                run([args.vivado, "-mode", "batch", "-source", COMMON / "scripts/native_build.tcl", "-tclargs",
                     out / "config.tcl", args.action], cwd=out, log=out / (args.action + ".log"))
                if identity(args)["sha256"] != manifest["sha256"]:
                    raise RuntimeError("Sources changed during Vivado execution; build is not current")
                if args.action == "build":
                    if (out / "timing.pass").read_text().strip() != "PASS":
                        raise RuntimeError("Missing routed timing pass")
                    artifacts = {name: sha(out / name) for name in (
                        PROFILE["bitstream"], "timing.pass", "timing_summary.rpt", "utilization.rpt", "manifest.json"
                    )}
                    (out / "result.json").write_text(json.dumps({"identity": manifest["sha256"],
                        "timing_pass": True, "artifacts": artifacts}, indent=2) + "\n")
            except Exception:
                if args.action in ("build", "synth"):
                    try:
                        write_reports(out, failed=True)
                    except Exception as report_error:
                        print(f"WARN: could not generate partial Vivado reports: {report_error}", file=sys.stderr)
                raise
            if args.action in ("build", "synth"):
                write_reports(out)
        print(f"{args.action}: PASS ({out})")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc
