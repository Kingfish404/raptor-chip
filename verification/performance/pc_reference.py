"""Match FPGA boundary PC digests to a complete native instruction stream."""
from __future__ import annotations

from simpoints import digest, read_profile

ALGORITHM = "rotate-xor-pc-v1"
MASK = (1 << 64) - 1
CONSTANT = 0x9E3779B97F4A7C15


def rotate(value, amount):
    amount %= 64
    return ((value << amount) | (value >> ((64 - amount) % 64))) & MASK


def domain_key(domain):
    mode = domain.get("mode", "all")
    if mode == "all":
        return (mode,)
    if mode != "user" or not domain.get("include_kernel_cycles", True):
        raise ValueError("unsupported native PC reference domain")
    pointer = domain.get("thread_pointer")
    return mode, int(domain["satp_root"], 0), None if pointer is None else int(pointer, 0)


class PcReference:
    def __init__(self, path, expected_sha256, domain):
        self.sha256 = digest(path)
        if self.sha256 != expected_sha256:
            raise ValueError("native PC reference differs from the selected BBV profile")
        rows, footer = read_profile(path)
        self.domain = domain_key(footer.get("retirement_domain", {"mode": "all"}))
        if self.domain != domain_key(domain):
            raise ValueError("native PC reference uses a different retirement domain")
        self.boundaries = {0: (0, 0)}
        previous = 0
        for row in rows:
            if row.get("pc_digest_algorithm") != ALGORITHM:
                raise ValueError("native profile does not contain ordered PC boundary bands")
            start = int(row["pc_digest_start"], 16)
            end = int(row["pc_digest_end"], 16)
            if not 0 <= start <= MASK or not 0 <= end <= MASK or start != previous:
                raise ValueError("native PC digest continuity is invalid")
            band = row["pc_band"]
            if len(band) != min(row["instructions"], 64):
                raise ValueError("native PC band length is invalid")
            signature = start
            for ordinal, (pc, observed) in enumerate(band, 1):
                pc, observed = int(pc, 0), int(observed, 16)
                signature = rotate(signature, 7) ^ pc ^ CONSTANT
                if not 0 <= pc <= MASK or signature != observed:
                    raise ValueError("native PC band digest is invalid")
                self.add(row["start"] + ordinal, pc, observed)
            last = int(row["last_pc"], 0)
            if not 0 <= last <= MASK:
                raise ValueError("native last PC is invalid")
            self.add(row["start"] + row["instructions"], last, end)
            previous = end

    def add(self, count, pc, signature):
        value = pc, signature
        if count in self.boundaries and self.boundaries[count] != value:
            raise ValueError("native PC boundary records disagree")
        self.boundaries[count] = value

    def boundary(self, count):
        try:
            return self.boundaries[count]
        except KeyError as error:
            raise ValueError(f"native PC reference has no boundary at instruction {count}") from error

    def verify(self, window, point):
        if (window.get("complete") is not True or window.get("signature_algorithm") != ALGORITHM or
                len(window.get("boundaries", [])) < 2):
            raise ValueError("an accepted ordered-PC hardware window is required")
        if domain_key(window.get("retirement_domain", {"mode": "all"})) != self.domain:
            raise ValueError("hardware window and native PC reference domains differ")
        if int(window["start_pc"], 0) != int(point["start_pc"], 0):
            raise ValueError("hardware measurement starts at a different PC")
        checkpoint = point["checkpoint_start"]
        initial = self.boundary(checkpoint)[1]
        for row in window["boundaries"]:
            count = row["instructions"]
            if type(count) is not int or count < 0:
                raise ValueError("hardware PC boundary count is invalid")
            pc, signature = self.boundary(checkpoint + count) if count else (0, initial)
            # D(a..b) = D(b) XOR rotate(D(a), 7*(b-a)). No full PC trace is needed.
            expected = signature ^ rotate(initial, 7 * count)
            if int(row["last_pc"], 0) != pc or int(row["signature"], 16) != expected:
                raise ValueError(f"hardware PC stream differs from native at instruction {count}")
        return {"complete": True, "sha256": self.sha256,
                "checked_boundary_rows": len(window["boundaries"]), "algorithm": ALGORITHM}
