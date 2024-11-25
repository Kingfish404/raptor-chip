import pandas as pd
import multiprocessing
from multiprocessing import Pool
from typing import Tuple
from abc import abstractmethod


class BPUBasic:
    def __init__(self) -> None:
        # Statistics for accuracy
        self.total_predictions = 0
        self.correct_predictions = 0

        # Branch type statistics
        self.call_count = 0
        self.ret_count = 0
        self.branch_count = 0
        self.jump_count = 0
        self.other_count = 0

        # Branch area
        self.area = 0

    def update_branch_stats(self, branch_type) -> None:
        """Update the count for each branch type."""
        if branch_type == "c":
            self.call_count += 1
        elif branch_type == "r":
            self.ret_count += 1
        elif branch_type == "b":
            self.branch_count += 1
        elif branch_type == "j":
            self.jump_count += 1
        else:
            self.other_count += 1

    def record_result(self, correct) -> None:
        """Update prediction statistics."""
        self.total_predictions += 1
        if correct:
            self.correct_predictions += 1

    def get_accuracy(self) -> float:
        """Calculate and return prediction accuracy as a percentage."""
        if self.total_predictions == 0:
            return 0.0
        return (self.correct_predictions / self.total_predictions) * 100

    @abstractmethod
    def print_stats(self) -> None:
        """Print prediction accuracy and branch statistics."""
        ...

    @abstractmethod
    def predict(self, pc) -> Tuple[bool, int]:
        """
        Make a prediction for the given program counter (pc).

        Parameters:
          pc: The program counter for the branch instruction.

        Returns:
          A tuple of (taken, target) where:
            - taken: True if the branch is taken, False otherwise.
            - target: The target address of the branch
        """
        ...

    @abstractmethod
    def update(self, pc, taken, target) -> None:
        """Update the BTB and PHT based on actual branch outcome."""
        ...


class SimplePredictor(BPUBasic):
    def __init__(self, btb_size=128):
        super().__init__()
        self.btb_size = btb_size
        self.btb = [None] * btb_size
        pc_width = 32
        self.area = 1 * pc_width + btb_size * pc_width

    def predict(self, pc):
        btb_index = pc % self.btb_size
        return True, self.btb[btb_index] if self.btb[btb_index] is not None else pc + 4

    def update(self, pc, taken, target):
        btb_index = pc % self.btb_size
        self.btb[btb_index] = target if taken else None

    def print_stats(self):
        """Print final statistics."""
        accuracy = self.get_accuracy()
        print("Simple Predictor:", end=" ")
        print(f"accuracy: {accuracy:5.2f}%", end=", ")
        print(f"btb_size: {self.btb_size:6d}", end=", ")
        print(
            f"Total: {self.total_predictions:6d}, Correct: {self.correct_predictions:6d}",
        )


class BranchPredictor(BPUBasic):
    def __init__(self, btb_size=128, pht_size=1024):
        super().__init__()
        self.btb_size = btb_size
        self.pht_size = pht_size

        # BTB initialized with None
        self.btb = [None] * btb_size

        # PHT initialized with 2-bit saturating counters (00: Strongly Not Taken, 11: Strongly Taken)
        self.pht = [1] * pht_size

        # Global History Register
        self.ghr = 0  # 8-bit GHR (can be modified)
        self.ghr_size = 8

        pc_width = 32
        self.area = 1 * pc_width + btb_size * pc_width + pht_size

    def _btb_index(self, pc):
        """Generate an index into the BTB from the program counter (pc)."""
        return pc % self.btb_size

    def _pht_index(self, pc):
        """Generate an index into the PHT using GHR and pc."""
        ghr_bits = self.ghr & ((1 << self.ghr_size) - 1)
        return (pc ^ ghr_bits) % self.pht_size

    def predict(self, pc):
        """Make a prediction for the given program counter (pc)."""
        btb_index = self._btb_index(pc)
        pht_index = self._pht_index(pc)

        # Check if BTB entry exists for this PC
        btb_entry = self.btb[btb_index]

        if btb_entry is not None and btb_entry["pc"] == pc:
            # BTB hit, predict based on PHT
            if self.pht[pht_index] >= 2:  # 2-bit predictor: 2 and 3 means Taken
                return True, btb_entry["target"]
            else:
                return True, pc + 4
        else:
            return True, pc + 4

    def update(self, pc, taken, target):
        """Update the BTB and PHT based on actual branch outcome."""
        btb_index = self._btb_index(pc)
        pht_index = self._pht_index(pc)

        if self.btb[btb_index] is None or self.btb[btb_index]["pc"] != pc:
            self.btb[btb_index] = {"pc": pc, "target": target}

        # Update PHT (2-bit saturating counter)
        if taken:
            if self.pht[pht_index] < 3:
                self.pht[pht_index] += 1
        else:
            if self.pht[pht_index] > 0:
                self.pht[pht_index] -= 1

        self.ghr = ((self.ghr << 1) | int(taken)) & ((1 << self.ghr_size) - 1)

    def print_stats(self):
        """Print final statistics."""
        accuracy = self.get_accuracy()
        print("Branch Predictor:", end=" ")
        print(f"accuracy: {accuracy:5.2f}%", end=", ")
        print(f"btb_size: {self.btb_size:6d}, pht_size: {self.pht_size:6d}", end=", ")
        print(
            f"Total: {self.total_predictions:6d}, Correct: {self.correct_predictions:6d}",
        )


def parse_bpu_trace(filename):
    trace = []
    with open(filename, "r") as file:
        """
        a000453c-a0004514-c
        a0004518-a000451c-b
        a0004530-a0003924-r
        a0003938-a0003dac-r
        """
        for line in file:
            line = line.strip()
            if not line:
                continue

            pc_target, branch_type = line.split("-"), line[-1]
            pc = int(pc_target[0], 16)
            target = int(pc_target[1], 16)

            trace.append((pc, target, branch_type))

    return trace


def simulate_bpu(params: Tuple[list, BPUBasic]):
    trace, bpu = params

    for pc, target, branch_type in trace:
        taken, predicted = bpu.predict(pc)

        correct = taken and (target == predicted)
        # print(
        #     f"pc: {pc:8x}, target: {target:8x}, predicted: {predicted:8x}, "
        #     f"taken: {taken}, correct: {correct}"
        # )

        bpu.record_result(correct)
        bpu.update_branch_stats(branch_type)
        bpu.update(pc, taken, target)

    # bpu.print_stats()
    return {
        "name": bpu.__class__.__name__,
        "acc": round(bpu.get_accuracy(), 3),
        "area": bpu.area,
        "c": bpu.call_count,
        "r": bpu.ret_count,
        "b": bpu.branch_count,
        "j": bpu.jump_count,
        "o": bpu.other_count,
    }


def main():
    filename = "./../bpu-trace.txt"
    trace_data = parse_bpu_trace(filename)
    btb_size_list = [2**i for i in range(0, 10)]

    with Pool(multiprocessing.cpu_count()) as p:
        result = p.map(
            simulate_bpu,
            [
                (trace_data, SimplePredictor(btb_size=btb_size))
                for btb_size in btb_size_list
            ],
        )
        result = sorted(result, key=lambda x: x["acc"], reverse=True)
        result_df = pd.DataFrame(result)
        print(result_df)

    print("")
    with Pool(multiprocessing.cpu_count()) as p:
        result = p.map(
            simulate_bpu,
            [
                (trace_data, BranchPredictor(btb_size=btb_size, pht_size=pht_size))
                for btb_size in btb_size_list
                for pht_size in [1, 2, 4, 8, 16]
            ],
        )
        result = sorted(result, key=lambda x: x["acc"], reverse=True)
        result_df = pd.DataFrame(result)
        print(result_df)


if __name__ == "__main__":
    main()
