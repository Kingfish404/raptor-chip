"""python -m tools.bringup --sim /output/bringup-sim connect"""
import argparse
import json
from pathlib import Path
import sys

from .client import Board, BringupError, SerialTransport, SimTransport, write_result


def integer(text):
    return int(text, 0)


def integers(text):
    return [integer(value) for value in text.split(",")]


def main():
    parser = argparse.ArgumentParser(description="Raptor chip bring-up host")
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument("--sim", type=Path, help="RTL UART simulator executable")
    transport.add_argument("--serial", help="USB UART device, 1 Mbaud 8N1")
    parser.add_argument("--baud", type=int, default=1_000_000)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("connect", "stats", "reset", "idcode", "halt", "resume", "memory-test"):
        sub.add_parser(action)
    power = sub.add_parser("power-on")
    power.add_argument("--clock", type=int, default=5, help="100 MHz half ticks, 1..6")
    power.add_argument("--external", action="store_true")
    reg = sub.add_parser("register")
    reg.add_argument("number", type=integer, help="Abstract regno, e.g. 0x1001 or 0x7b1")
    irq = sub.add_parser("irq")
    irq.add_argument("level", type=int, choices=[0, 1])
    load = sub.add_parser("load")
    load.add_argument("image", type=Path)
    load.add_argument("--address", type=integer, default=0x80000000)
    for action in ("run", "link-shmoo", "clock-shmoo", "test"):
        command = sub.add_parser(action)
        command.add_argument("image", type=Path, help="Binary, or cpu-tests directory for test")
        command.add_argument("--half", type=int, default=15)
        command.add_argument("--clock", type=int, default=5)
        command.add_argument("--board-delay", type=int, default=0)
        command.add_argument("--timeout-cycles", type=integer, default=100_000_000)
        command.add_argument("--samples", type=integers, default=[0])
        command.add_argument("--taps", type=integers, default=[0])
        command.add_argument("--halves", type=integers, default=list(range(2, 16)))
        command.add_argument("--clocks", type=integers, default=list(range(1, 7)))
        command.add_argument("--output", type=Path)
        command.add_argument("--chip-serial", default="unspecified")
        command.add_argument("--conditions", type=json.loads, default={})
    args = parser.parse_args()
    if args.action == "test" and (args.output is None or args.chip_serial == "unspecified"):
        parser.error("test requires --output and --chip-serial")
    link = SimTransport(args.sim) if args.sim else SerialTransport(args.serial, args.baud)
    board = Board(link)
    code = 0
    try:
        identity = board.connect()
        if args.action == "connect":
            result = identity
        elif args.action == "power-on":
            result = board.power_on(args.clock, args.external)
        elif args.action == "stats":
            result = board.stats()
        elif args.action == "reset":
            board.reset()
            result = {"reset_held": True}
        elif args.action == "irq":
            board.irq(args.level)
            result = {"irq": args.level}
        elif args.action == "idcode":
            if not board.read(0x18) & 8:
                board.power_on()
            result = {"idcode": f"0x{board.idcode():08x}"}
        elif args.action in ("halt", "resume", "register"):
            if not board.read(0x18) & 8:
                board.power_on()
            if args.action == "register":
                board.halt()
                result = {"register": args.number, "value": board.register(args.number)}
            else:
                getattr(board, args.action)()
                result = {args.action: True}
        elif args.action == "memory-test":
            result = board.memory_test()
        elif args.action == "load":
            board.load(args.address, args.image.read_bytes())
            result = {"loaded": str(args.image), "address": args.address, "reset_held": True}
        elif args.action == "run":
            result = board.run(args.image.read_bytes(), args.half, args.clock,
                               args.timeout_cycles, args.samples[0], args.board_delay, args.taps[0])
            code = int(not result["pass"])
        elif args.action in ("link-shmoo", "clock-shmoo"):
            halves = args.halves if args.action == "link-shmoo" else [args.half]
            clocks = args.clocks if args.action == "clock-shmoo" else [args.clock]
            def progress(row):
                name = (f"clock={row['clock_half_ticks']} H={row['half_period']} "
                        f"sample={row['sample_delay']} taps={row['input_taps']}")
                print(f"{name}: {'PASS' if row['pass'] else 'FAIL'}", file=sys.stderr)
            result = board.shmoo(args.image.read_bytes(), halves, args.samples, clocks,
                                 args.board_delay, args.timeout_cycles, args.taps, progress)
        else:
            results = []
            for image in sorted(args.image.glob("*.bin")):
                try:
                    outcome = board.run(image.read_bytes(), args.half, args.clock,
                                        args.timeout_cycles, args.samples[0], args.board_delay,
                                        args.taps[0])
                except BringupError as error:
                    outcome = {"pass": False, "error": str(error)}
                results.append({"name": image.stem, **outcome})
                print(f"{image.stem}: {'PASS' if outcome['pass'] else 'FAIL'}", file=sys.stderr)
                result = write_result(args.output, args.chip_serial, args.conditions, results)
            if not results:
                raise BringupError("No binary tests found")
            code = int(not result["pass"])
        if getattr(args, "output", None) and args.action != "test":
            outcomes = result if isinstance(result, list) else [result]
            write_result(args.output, args.chip_serial, args.conditions, outcomes)
        print(json.dumps(result, indent=2))
        return code
    except (BringupError, OSError, ValueError) as error:
        try:
            board.reset()
        except (BringupError, OSError):
            pass
        print(f"bringup: {error}", file=sys.stderr)
        return 1
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
