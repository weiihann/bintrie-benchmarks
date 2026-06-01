"""Compute the per-iteration (target_idx, stem_idx) sequence for the K-sweep workload.

Given T touches per block and K distinct contracts, distribute touches as evenly as
possible across contracts (first `T mod K` contracts get ⌈T/K⌉ stems; the rest get
⌊T/K⌋). Within each contract, stems are visited 0, 1, 2, ... in order so each touch
hits a distinct stem (slot indices stride 256). Visits to a single contract are
contiguous in the sequence (not interleaved) so PBT's per-contract Pebble clustering
maps to consecutive cold reads.

Output: list of (target_idx, stem_idx) pairs of length T.
"""

from __future__ import annotations


def build_sequence(T: int, K: int) -> list[tuple[int, int]]:
    if T <= 0:
        raise ValueError(f"T must be positive: {T}")
    if K <= 0 or K > T:
        raise ValueError(f"K must be in [1, T={T}]: {K}")

    base = T // K
    extra = T % K  # first `extra` targets get base+1 stems

    seq: list[tuple[int, int]] = []
    for target in range(K):
        stems_for_target = base + (1 if target < extra else 0)
        for stem in range(stems_for_target):
            seq.append((target, stem))
    assert len(seq) == T
    return seq
