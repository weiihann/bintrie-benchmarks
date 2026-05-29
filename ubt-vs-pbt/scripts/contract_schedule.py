#!/usr/bin/env python3
"""Deterministic weighted contract-visit schedule for the UBT vs PBT campaign.

The benchmark visits ERC20 contracts a *weighted* number of times per run: a few
"hot" contracts are hit many times, a long tail once. Counts follow a Zipf
power-law (weight of rank r is 1/(r+1)**exp); which contract is hottest is fixed
by a seeded shuffle. Visits are interleaved (round-robin by remaining count) so a
hot contract is spread across the run rather than fired back-to-back.

The schedule is a pure function of (n, seed, visits, exp), so it is byte-identical
across configs, benchmarks, and runs — the apples-to-apples guarantee.

Usage:
    contract_schedule.py <n_contracts> <seed> <visits_per_run> <powerlaw_exp>

Prints one contract index per line (length == visits_per_run).
"""
import random
import sys


def build_schedule(n, seed, visits, exp):
    """Return a list of `visits` contract indices, power-law weighted + interleaved."""
    if n <= 0 or visits <= 0:
        return []

    # Zipf weights by rank (rank 0 is hottest), then assign ranks to contract
    # indices via a seeded shuffle so the hot contract is deterministic but not
    # always index 0.
    weights = [1.0 / ((r + 1) ** exp) for r in range(n)]
    total_w = sum(weights)
    ranked_indices = list(range(n))
    random.seed(seed)
    random.shuffle(ranked_indices)

    # Largest-remainder rounding of the real-valued allocations to sum == visits.
    raw = [visits * w / total_w for w in weights]
    counts = [int(x) for x in raw]
    shortfall = visits - sum(counts)
    by_remainder = sorted(range(n), key=lambda i: raw[i] - counts[i], reverse=True)
    for i in range(shortfall):
        counts[by_remainder[i]] += 1

    # Map rank-counts onto contract indices.
    total = {ranked_indices[rank]: counts[rank] for rank in range(n)}

    # Interleave with the Sainte-Laguë / highest-averages method: at each slot
    # pick the contract whose share is most "behind", priority = total / (used +
    # 0.5). This spreads each contract's visits evenly across the whole schedule,
    # so even the hottest contract is never clustered (a count-10-of-30 contract
    # lands roughly every third slot). Ties broken by (-total, index) for
    # determinism.
    used = {c: 0 for c in total}
    schedule = []
    for _ in range(sum(total.values())):
        best = max(
            (c for c in total if used[c] < total[c]),
            key=lambda c: (total[c] / (used[c] + 0.5), total[c], -c),
        )
        schedule.append(best)
        used[best] += 1
    return schedule


def main():
    if len(sys.argv) != 5:
        sys.exit(f"usage: {sys.argv[0]} <n_contracts> <seed> <visits_per_run> <powerlaw_exp>")
    n = int(sys.argv[1])
    seed = sys.argv[2]
    visits = int(sys.argv[3])
    exp = float(sys.argv[4])
    print("\n".join(str(c) for c in build_schedule(n, seed, visits, exp)))


if __name__ == "__main__":
    main()
