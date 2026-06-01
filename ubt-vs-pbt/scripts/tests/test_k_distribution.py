"""Unit tests for the (target_idx, stem_idx) sequence builder."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from k_distribution import build_sequence


def test_k_equals_1_all_same_target():
    seq = build_sequence(T=256, K=1)
    assert len(seq) == 256
    assert all(t == 0 for t, _ in seq)
    # Stem indices are 0..255 sequentially
    assert [s for _, s in seq] == list(range(256))


def test_k_equals_T_one_stem_per_target():
    seq = build_sequence(T=256, K=256)
    assert len(seq) == 256
    assert [t for t, _ in seq] == list(range(256))
    assert all(s == 0 for _, s in seq)


def test_k_10_distribution_is_balanced():
    """T=256, K=10: 256 mod 10 = 6 → first 6 contracts get ⌈256/10⌉=26 stems, rest get 25."""
    seq = build_sequence(T=256, K=10)
    assert len(seq) == 256
    counts = [0] * 10
    for t, _ in seq:
        counts[t] += 1
    assert counts == [26, 26, 26, 26, 26, 26, 25, 25, 25, 25], counts


def test_k_100_distribution_is_balanced():
    """T=256, K=100: 256 // 100 = 2, 256 mod 100 = 56 → first 56 get 3, rest get 2."""
    seq = build_sequence(T=256, K=100)
    counts = [0] * 100
    for t, _ in seq:
        counts[t] += 1
    assert counts[:56] == [3] * 56
    assert counts[56:] == [2] * 44


def test_stem_indices_within_target_are_sequential_and_distinct():
    """For each target, the stem indices visited are 0, 1, 2, ... (no repeats)."""
    seq = build_sequence(T=256, K=10)
    by_target: dict[int, list[int]] = {}
    for t, s in seq:
        by_target.setdefault(t, []).append(s)
    for target, stems in by_target.items():
        assert stems == list(range(len(stems))), (target, stems)


def test_target_visits_are_consecutive_blocks():
    """All accesses to target i are consecutive in the sequence (clustered, not interleaved).

    PBT clustering only helps when the same contract's accesses are temporally adjacent
    in the access stream — otherwise Pebble's hot-block cache won't capture the locality.
    """
    seq = build_sequence(T=256, K=10)
    targets = [t for t, _ in seq]
    seen_order = []
    for t in targets:
        if not seen_order or seen_order[-1] != t:
            seen_order.append(t)
    assert seen_order == list(range(10)), seen_order


def test_rejects_invalid_K():
    import pytest

    with pytest.raises(ValueError):
        build_sequence(T=256, K=0)
    with pytest.raises(ValueError):
        build_sequence(T=256, K=257)
    with pytest.raises(ValueError):
        build_sequence(T=0, K=1)
