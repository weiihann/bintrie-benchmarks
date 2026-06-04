#!/usr/bin/env python3
"""Heterogeneous getter stem-buckets for the locality sweep.

Each target index i is touched with at most ``max_stems(i)`` distinct stems
across the whole K sweep (k_distribution assigns ⌈T/K⌉ or ⌊T/K⌋ stems to the
first K targets). Sizing getter i to exactly ``max_stems(i)`` keeps every cold
SLOAD on a populated stem while avoiding the N×T over-provisioning of uniform
getters (e.g. 4500 getters × 5000 stems = 22.5M writes → ~22k writes).

Because ``max_stems(i)`` is monotonically non-increasing in i, equal values form
contiguous index runs ("buckets"), each deployable as one factorydeploytx call
with a fixed init-code and a contiguous --start-salt range.

Usage: getter_buckets.py <T_TOUCHES> "<space-separated K list>" <NUM_CONTRACTS>
Output: one line per bucket: "<start_index> <count> <stems>"
"""
import sys


def stems_for_target(T: int, K: int, i: int) -> int:
    """Stems assigned to target index i by k_distribution.build_sequence(T, K)."""
    if i >= K:
        return 0
    base, extra = divmod(T, K)
    return base + (1 if i < extra else 0)


def main() -> None:
    T = int(sys.argv[1])
    klist = [int(x) for x in sys.argv[2].split()]
    n = int(sys.argv[3])
    max_stems = [max(stems_for_target(T, K, i) for K in klist) for i in range(n)]

    start = 0
    for i in range(1, n + 1):
        if i == n or max_stems[i] != max_stems[start]:
            print(f"{start} {i - start} {max_stems[start]}")
            start = i


if __name__ == "__main__":
    main()
