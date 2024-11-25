import pandas as pd
import multiprocessing
from multiprocessing import Pool
from typing import Tuple, List


class CacheLine:
    def __init__(self, tag):
        self.tag = tag
        self.dirty = False  # If written to, mark the line as dirty for write-back.
        self.last_used = 0  # For LRU replacement policy.


class DCacheSimulator:
    def __init__(self, cache_size, block_size, associativity):
        self.cache_size = cache_size  # Total cache size in bytes.
        self.block_size = block_size  # Size of a block in bytes.
        self.associativity = (
            associativity  # Number of ways (e.g., 4-way set associative).
        )

        self.num_sets = self.cache_size // (
            self.block_size * self.associativity
        )  # Number of cache sets.
        self.cache = [
            [] for _ in range(self.num_sets)
        ]  # Initialize cache as list of sets.
        self.time = 0  # For LRU tracking.

        self.total_accesses = 0
        self.hits = 0

    def get_set_index_and_tag(self, address):
        # Calculate the index of the set and the tag for a given address.
        block_offset_bits = self.block_size.bit_length() - 1
        index_bits = (self.num_sets).bit_length() - 1

        # Shift the address to get rid of the block offset bits.
        set_index = (address >> block_offset_bits) & ((1 << index_bits) - 1)
        tag = address >> (block_offset_bits + index_bits)

        return set_index, tag

    def access_cache(self, address, is_write):
        self.time += 1  # Increment time for LRU purposes.
        self.total_accesses += 1

        set_index, tag = self.get_set_index_and_tag(address)
        cache_set = self.cache[set_index]

        # Check if the tag is already in the cache (cache hit).
        for line in cache_set:
            if line.tag == tag:
                line.last_used = self.time  # Update usage time for LRU.
                if is_write:
                    line.dirty = True  # Mark the line as dirty on write.
                self.hits += 1
                return "Hit"

        # Cache miss, so we need to add a new cache line.
        new_line = CacheLine(tag)
        if is_write:
            new_line.dirty = True

        # If the set is full, we need to evict a line (use LRU).
        if len(cache_set) >= self.associativity:
            # Find the least recently used (LRU) cache line to evict.
            lru_line = min(cache_set, key=lambda line: line.last_used)
            cache_set.remove(lru_line)

        # Add the new line to the set.
        new_line.last_used = self.time
        cache_set.append(new_line)

        return "Miss"

    def print_stats(self):
        print(f"DCache: {self.cache_size:4d} bytes", end=", ")
        print(f"Block: {self.block_size} bytes", end=", ")
        print(f"Associativity: {self.associativity}-way", end=", ")

        print(f"Accesses: {self.total_accesses}", end=", ")
        print(f"Hits: {self.hits:8d}", end=", ")
        hit_rate = self.hits / self.total_accesses if self.total_accesses > 0 else 0
        print(f"Hit Rate: {hit_rate:.2f}")


def parse_mem_trace(filename):
    trace = []
    with open(filename, "r") as file:
        """
        0f001ffc-w
        3000008c-r
        30000090-r
        a0000000-w
        """
        for line in file:
            line = line.strip()
            if not line:
                continue

            pc_target, mem_type = line.split("-"), line[-1]
            addr = int(pc_target[0], 16)

            trace.append((addr, mem_type))

    return trace


def simulate_trace(params: Tuple[DCacheSimulator, List[Tuple[int, str]]]):
    dcache, trace = params
    # Simulate a trace of memory accesses.
    for address, access_type in trace:
        is_write = access_type == "w"
        result = dcache.access_cache(address, is_write)
        # print(f"Access: {address:08x}, Type: {'Write' if is_write else 'Read'}, Result: {result}")

    # dcache.print_stats()
    hit_rate = dcache.hits / dcache.total_accesses if dcache.total_accesses > 0 else 0
    return {
        "cache_size": dcache.cache_size,
        "block_size": dcache.block_size,
        "associativity": dcache.associativity,
        "accesses": dcache.total_accesses,
        "hits": dcache.hits,
        "acc": round(hit_rate, 3),
    }


def main():
    trace = parse_mem_trace("./../mem-trace.txt")

    dcache_size = [2**i for i in range(4, 10)]

    with Pool(multiprocessing.cpu_count()) as p:
        result = p.map(
            simulate_trace,
            [
                (
                    DCacheSimulator(
                        cache_size=cache_size, block_size=8, associativity=1
                    ),
                    trace,
                )
                for cache_size in dcache_size
            ],
        )
        result = sorted(result, key=lambda x: x["acc"], reverse=True)
        result_df = pd.DataFrame(result)
        print(result_df)


if __name__ == "__main__":
    main()
