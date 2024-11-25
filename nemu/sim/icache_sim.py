import pandas as pd
import multiprocessing
from multiprocessing import Pool


class ICacheSimulator:
    def __init__(self, cache_size, line_size):
        self.cache_size = cache_size
        self.line_size = line_size
        self.num_lines = cache_size // line_size
        self.cache = [-1] * self.num_lines  # store the tag of each line

    def get_line_index(self, address):
        # calculate the line index
        return (address // self.line_size) % self.num_lines

    def get_tag(self, address):
        # calculate the tag
        return address // self.line_size

    def access_cache(self, address):
        line_index = self.get_line_index(address)
        tag = self.get_tag(address)
        if self.cache[line_index] == tag:
            return True  # hit
        else:
            self.cache[line_index] = tag
            return False  # miss


def simulate_icache(pc_sequence, cache_size, line_size):
    simulator = ICacheSimulator(cache_size, line_size)
    hits = 0
    inst_count = 0
    for address in pc_sequence:
        for addr in range(address[0], address[1], 4):
            inst_count += 1
            if simulator.access_cache(addr):
                hits += 1
    hit_rate = hits / inst_count
    meta = {
        "inst_count": inst_count,
        "hit_count": hits,
        "miss_count": inst_count - hits,
    }
    return hit_rate, meta


def compute_amats(params):
    pc_sequence, cache_size, line_num = params
    line_size = cache_size // line_num
    hit_cost = 0
    miss_cost = 27 + line_size

    hit_rate, meta = simulate_icache(pc_sequence, cache_size, line_size)
    amat = hit_rate * hit_cost + (1 - hit_rate) * miss_cost

    return {
        "cache_size": cache_size,
        "line_num": line_num,
        "line_size": line_size,
        "hit_cost": hit_cost,
        "miss_cost": miss_cost,
        "hit_rate": hit_rate,
        "amat": amat,
    }


def main():
    pc_sequence_file = "./../pc-trace.txt"
    pc_sequence = []
    with open(pc_sequence_file, "r") as f:
        """
        0xa0004534-6
        0xa000453c-8
        0xa0004530-6
        0xa0003938-
        """
        for line in f:
            pc_start, pc_cnt = line.strip().split("-")
            if len(pc_cnt) == 0:
                pc_cnt = 1
            pc_sequence.append([int(pc_start, 16), int(pc_start, 16) + int(pc_cnt) * 4])

    results = []
    cache_size_pool = [2**i for i in range(2, 7 + 1)]
    print(cache_size_pool)
    params_list = [
        (pc_sequence, cache_size, line_num)
        for cache_size in cache_size_pool
        for line_num in range(1, cache_size + 1)
    ]
    params_list = filter(lambda x: x[1] % x[2] == 0, params_list)
    params_list = filter(
        lambda x: x[1] // x[2] >= 4 and (x[1] // x[2] & (x[1] // x[2] - 1)) == 0,
        params_list,
    )

    with Pool(processes=multiprocessing.cpu_count()) as pool:
        results = pool.map(compute_amats, params_list)

    results_df = pd.DataFrame(results)
    results_df.sort_values(by="amat", inplace=True)
    print(results_df.to_markdown(index=False))


if __name__ == "__main__":
    main()
