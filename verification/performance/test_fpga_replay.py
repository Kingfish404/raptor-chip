import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import fpga_replay
from fpga_image import PAGE, SRAM, SparseRam
from simpoints import digest
from test_pc_reference import window, write_profile


class FakeJtag:
    """Host-protocol oracle; this does not model RTL or establish board correctness."""
    def __init__(self, _args):
        self.memory = {}
        self.dumps = 0

    def read(self, address, words=1):
        if address == fpga_replay.CONTROL:
            return [0x5250545300010001]
        if address == fpga_replay.CONTROL + 0xB0:
            return [0x1111111111111111] * 2
        if address == fpga_replay.CONTROL + 0x70:
            return [196]
        return [self.memory.get(address + i * 8, 0) for i in range(words)]

    def write(self, address, value):
        self.memory[address] = value

    def wait(self, _offset, predicate, _timeout=60):
        status = 4 | 32
        assert predicate(status)
        return status

    def transfer(self, descriptor, dump=None, timeout=1800):
        del timeout
        size = sum(int(line.split()[2]) for line in descriptor.read_text().splitlines())
        if dump is not None:
            self.dumps += 1
            dump.write_bytes(bytes([int(self.dumps == 1)]) + bytes(size - 1))
        return size

    def hold(self):
        pass

    def close(self):
        pass


class FpgaReplayTests(unittest.TestCase):
    def test_cycle_budget_rejects_values_that_cannot_fit_hardware(self):
        for value in (0, -1, 1 << 64, True, 1.5):
            with self.assertRaises(ValueError):
                fpga_replay.cycle_budget({"cycle_limit": value}, 100)
        self.assertEqual(fpga_replay.cycle_budget({}, 100), 100)

    def test_transition_pages_preserve_dirty_data_and_sparse_zeroes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            images = {}
            for name, values in {"a": [1, 0, 0], "b": [1, 2, 3],
                                 "c": [1, 2, 0], "d": [4, 2, 0]}.items():
                directory = root / name
                directory.mkdir()
                stored = [i for i, value in enumerate(values) if value]
                (directory / "mem_pmem.bin").write_bytes(b"".join(
                    bytes([values[i]]) * PAGE for i in stored))
                (directory / "mem_pmem.bin.meta").write_text(
                    f"size={3 * PAGE}\nchunk_size={PAGE}\nchunks={len(stored)}\n" +
                    "".join(f"chunk={i * PAGE}\n" for i in stored))
                images[name] = directory
            sequence = ["b", "b", "c", "d", "a"]
            points = [{"id": str(i)} for i in range(len(sequence))]
            cases = [({}, {}, points, {str(i): images[name] for i, name in enumerate(sequence)})]
            transitions = fpga_replay.prepare_transitions(cases, 1, images["a"])
            self.assertEqual(transitions[tuple(sorted((images["b"], images["c"])))], {2})
            memory = [bytes([1]) * PAGE, bytes(PAGE), bytes(PAGE)]
            previous = images["a"]
            for ordinal, name in enumerate(sequence):
                current = images[name]
                dirty = {0} if ordinal == 1 else set()
                if dirty:
                    memory[0] = bytes([99]) * PAGE
                changed = set() if current == previous else transitions[
                    tuple(sorted((previous, current)))]
                restore = dirty | changed
                target = SparseRam(current)
                try:
                    for page in restore:
                        memory[page] = target.page(page)
                    self.assertEqual(memory, [target.page(i) for i in range(3)])
                finally:
                    target.close()
                if ordinal == 1:
                    self.assertEqual(restore, {0})
                previous = current

    def test_failure_snapshot_preserves_unsafe_drain_state(self):
        jtag = Mock()
        jtag.read.side_effect = [[0x110], [123456], [5500080], [33], [0], [999], [14]]
        snapshot = fpga_replay.failure_snapshot(jtag)
        self.assertEqual(snapshot, {"status": 0x110, "elapsed_cycles": 123456,
                                   "retired": 5500080, "boundary_rows": 33, "error_code": 0,
                                   "drain_cycles": 999, "drain_ready": 14})
        jtag.write.assert_not_called()
        jtag.hold.assert_not_called()
        jtag.read.assert_has_calls([call(fpga_replay.CONTROL + offset)
                                   for offset in (8, 0x68, 0x70, 0x78, 0x90, 0xE8, 0xF0)])

    def test_failure_snapshot_stops_after_transport_failure(self):
        jtag = Mock()
        jtag.read.side_effect = [[0x110], TimeoutError("lost transport")]
        snapshot = fpga_replay.failure_snapshot(jtag)
        self.assertEqual(snapshot, {"status": 0x110, "read_error": "lost transport"})
        self.assertEqual(jtag.read.call_count, 2)

    def test_multiple_profiles_points_repetitions_and_weighted_estimates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkpoint = root / "checkpoint"
            checkpoint.mkdir()
            (checkpoint / "mem_pmem.bin").write_bytes(bytes([1]) * PAGE)
            (checkpoint / "mem_pmem.bin.meta").write_text(
                "size=0x200000\nchunk_size=0x1000\nchunks=1\nchunk=0x0\n")
            other_checkpoint = root / "other-checkpoint"
            other_checkpoint.mkdir()
            (other_checkpoint / "mem_pmem.bin").write_bytes(bytes([2]) * PAGE)
            (other_checkpoint / "mem_pmem.bin.meta").write_bytes(
                (checkpoint / "mem_pmem.bin.meta").read_bytes())
            points = [{"id": f"point-{i}", "start": i * 128, "warmup": 0,
                       "checkpoint_start": i * 128, "instructions": 128,
                       "weight": .5, "start_pc": "0x80000000"}
                      for i in range(2)]
            pcs = [0x80000000] * 256
            native = root / "native.bbv.jsonl"
            write_profile(native, pcs, 128)
            profile_sha256 = digest(native)
            plan = {"schema": "raptor-sample-plan-v1", "profile_sha256": profile_sha256,
                    "settings": {"warmup": 0}, "regions": [{"name": "roi", "start": 0,
                    "end": 256, "instructions": 256, "points": points}]}
            other_plan = dict(plan, profile_sha256="other-profile")
            for name in ("plan", "capture", "other-plan", "other-capture", "exporter"):
                (root / name).write_text(name)
            spec = root / "spec.json"
            spec.write_text(json.dumps({"schema": "raptor-fpga-evaluation-spec-v1",
                "cases": [{"id": "samples", "kind": "sample", "plan": "plan",
                           "capture": "capture", "pc_reference": native.name},
                          {"id": "other", "kind": "sample", "plan": "other-plan",
                           "capture": "other-capture", "cycle_limit": 50000000000}]}))
            build = {"sha256": "1" * 64, "configuration": {
                "sampling": True, "xlen": 64, "clock_mhz": 50}}
            state = {key: 0 for key in ("csr_mepc", "csr_mcycle", "csr_minstret",
                "clint_mtime", "clint_mtimecmp", "clint_msip", "csr_mstatus")}
            state["pc"] = 0x80000000

            def export(command, **_kwargs):
                Path(command[1].split(",")[1]).write_bytes(bytes(4096))

            timeouts = []

            def observe(_jtag, point, _domain, timeout):
                timeouts.append(timeout)
                observed = window(pcs, point["checkpoint_start"], [0, point["instructions"]])
                observed.update(schema="raptor-window-v1", warmup=0,
                                instructions=point["instructions"])
                for row in observed["boundaries"]:
                    row["cycle"] = 100 + row["instructions"] * 2
                return observed

            arguments = ["fpga_replay.py", "--spec", str(spec), "--native-build", str(root),
                         "--exporter", str(root / "exporter"), "--output", str(root / "output"),
                         "--hw-target", "test"]
            with (patch.object(sys, "argv", arguments),
                  patch.object(fpga_replay, "Jtag", FakeJtag),
                  patch.object(fpga_replay, "check_build", return_value=(build, {})),
                  patch.object(fpga_replay, "load_capture", side_effect=[
                      (plan, points, {point["id"]: checkpoint for point in points}),
                      (other_plan, points, {point["id"]: other_checkpoint for point in points})]),
                  patch.object(fpga_replay, "read_state", return_value=state),
                  patch.object(fpga_replay.subprocess, "run", side_effect=export),
                  patch.object(fpga_replay, "restore_image", return_value=(bytes(6144), SRAM)),
                  patch.object(fpga_replay, "upload_verified", return_value={
                      "bytes": PAGE, "readback_verified": True}),
                  patch.object(fpga_replay, "observations", side_effect=observe)):
                self.assertEqual(fpga_replay.main(), 0)
            result = json.loads((root / "output/results.json").read_text())
            self.assertTrue(result["complete"])
            self.assertEqual(timeouts, [300] * 6 + [1060] * 6)
            self.assertEqual(len(result["setup"]), 1)
            self.assertEqual(result["setup"][0]["shared_profiles"],
                             sorted(["other-profile", profile_sha256]))
            self.assertEqual(len(result["cases"]), 2)
            for case in result["cases"]:
                self.assertEqual(len(case["runs"]), 6)
                self.assertEqual(len(case["estimates"]), 3)
                for estimate in case["estimates"]:
                    self.assertTrue(estimate["complete"])
                    self.assertEqual(estimate["regions"][0]["profiles"][case["id"]]["cycles"], 512)
            self.assertEqual([run["restored_pages"] for run in result["cases"][0]["runs"]],
                             [0, 1, 0, 0, 0, 0])
            self.assertEqual([run["restored_pages"] for run in result["cases"][1]["runs"]],
                             [1, 0, 0, 0, 0, 0])
            self.assertTrue(all(run["native_pc_audit"]["complete"]
                                for run in result["cases"][0]["runs"]))
            self.assertEqual(digest(Path(result["cases"][0]["pc_reference"]["path"])),
                             profile_sha256)
            self.assertTrue((root / "output/progress.json").is_file())


if __name__ == "__main__":
    unittest.main()
