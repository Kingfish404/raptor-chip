"""Focused acceptance using the same Board library and UART packets as the CLI."""
import argparse
import json
from pathlib import Path

from .client import Board, BringupError, SimTransport, bootrom, decode, packet, write_result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--programs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--section", choices=["platform", "cpu", "shmoo", "all"], default="all")
    args = parser.parse_args()
    link = SimTransport(args.sim)
    board = Board(link)
    results = []

    def save(name, result):
        results.append({"name": name, **result})
        write_result(args.output, "RTL-chip32-middle-16k", {"backend": "pad RTL / UART",
                     "reference_hz": 100_000_000}, results)
        print(f"{name}: {'PASS' if result['pass'] else 'FAIL'}", flush=True)

    try:
        board.connect()
        if args.section in ("platform", "all"):
            invalid = bytearray(packet(0xA5, 1, 251))
            invalid[8] ^= 1
            assert decode(link.exchange(invalid))[3] == 1
            save("packet CRC rejected", {"pass": True})
            save("host memory patterns", board.memory_test())
            # Boot an infinite loop before measuring pins and debug behavior.
            board.load(0x20000000, bootrom(4))
            board.load(0x80000000, bytes.fromhex("6f000000"))
            frequencies = board.power_on()
            board.wait(200000)
            assert board.idcode() == 0x10001913
            board.halt()
            assert board.register(0x1000) == 0
            dpc = board.register(0x7B1)
            board.resume()
            save("clock DIAG JTAG debug", {"pass": True, "idcode": "0x10001913",
                                         "dpc": dpc, **frequencies})
            # Exercise the real UART control guard when leaving a live external
            # selection. The portable model shares its cycle source; actual
            # external frequency selection is tested with the MMCM primitives.
            board.power_on(external=True)
            assert board.read(4) & 16
            board.power_on()
            assert not board.read(4) & 16
            board.reset()
            try:
                board.write(4, board.read(4) ^ 16)
            except BringupError:
                pass
            else:
                raise AssertionError("Clock source changed with clock enable still set")
            board.power_on()
            save("clock source guard and reselection", {"pass": True})
            # Keep issuing uncached reads so runtime IRQ must leave the bridge
            # operational. No chip-internal state is read by this host model.
            # lui t0,0x00100; again: lw t1,0(t0); j again
            board.load(0x80000000, bytes.fromhex("b702100003a302006ff0dfff"))
            board.power_on(6)
            board.irq(1)
            frames_before = board.read(0x28)
            board.wait(20000)
            runtime_frames = (board.read(0x28) - frames_before) & 0xFFFFFFFF
            assert runtime_frames > 0 and board.read(4) & 8
            board.dmi(0x10, 3)
            board.wait(20000)
            assert board.read(4) & 8
            board.dmi(0x10, 1)
            board.wait(50000)
            assert board.idcode() == 0x10001913
            board.irq(0)
            save("plain IRQ and retained bridge boot", {"pass": True,
                 "runtime_frames": runtime_frames})
            for address, data in ((8, 2), (0x80000000, 1)):
                try:
                    board.write(address, data)
                except BringupError:
                    continue
                raise AssertionError("Unsafe live change accepted")
            save("live memory and clock writes rejected", {"pass": True})
            board.irq(1)
            board.write(0x14, 1024)
            board.wait(20000)
            assert board.read(0x18) & 2 and not board.read(0x18) & 0x18
            assert board.read(0x34) == 1
            # A rejected source/reset write must not clear the fault behind
            # the control register's back and release the chip unexpectedly.
            board.write(0x14, 1_000_000)
            try:
                board.write(4, (board.read(4) & ~2) ^ 16)
            except BringupError:
                pass
            else:
                raise AssertionError("Unsafe source/reset change was accepted")
            assert board.read(0x18) & 2 and not board.read(0x18) & 0x18
            board.reset()
            board.write(0x14, 1_000_000)
            save("watchdog holds chip reset and recovers", {"pass": True,
                 "rejected_reset_keeps_fault": True})
            for name, passed, code in (("console_test", True, 0), ("fail_test", False, 7)):
                outcome = board.run((args.programs.parent / "diagnostics" /
                                     f"{name}.bin").read_bytes(), half_period=4)
                assert outcome["pass"] == passed and outcome["exit_code"] == code
                if passed:
                    assert outcome["console"] == "Raptor bring-up UART\n"
                save(name, {**outcome, "pass": True, "observed_exit": code})
        if args.section in ("cpu", "all"):
            for image in sorted(args.programs.glob("*.bin")):
                try:
                    outcome = board.run(image.read_bytes(), half_period=4)
                except BringupError as error:
                    outcome = {"pass": False, "error": str(error)}
                save(image.stem, outcome)
        if args.section in ("shmoo", "all"):
            image = (args.programs / "dummy.bin").read_bytes()
            # 60 ns transport/direction at 25 MHz. Request data launches one
            # core cycle into the low phase. Extra DQ offsets expose its edge.
            matrix = board.shmoo(image, samples=(0, 6, 10), clocks=(2,), board_delay=6,
                                  timeout_cycles=1_000_000)
            for row in matrix:
                minimum_half = row["sample_delay"] // 4 + 2
                expected = row["half_period"] >= minimum_half
                row["observed_pass"] = row["pass"]
                row["pass"] = row["observed_pass"] == expected
                row["expected_pass"] = expected
                save(f"link H{row['half_period']} S{row['sample_delay']}", row)
            for row in board.shmoo(image, half_periods=(15,), clocks=range(1, 7),
                                   timeout_cycles=2_000_000):
                save(f"clock divider {row['clock_half_ticks']}", row)
        if not all(row["pass"] for row in results):
            raise SystemExit(1)
    finally:
        board.reset()
        link.close()


if __name__ == "__main__":
    main()
