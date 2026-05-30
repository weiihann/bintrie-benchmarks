# Binary Trie Benchmarks

Performance benchmarks for Ethereum's binary trie implementation ([EIP-7864](https://eips.ethereum.org/EIPS/eip-7864)).

## Experiments

### [Group Depth Benchmarks](group-depth-benchmarks/)

Compared all eight group-depth configurations (GD-1 through GD-8) on 360 GB databases with ~400M state entries. Five benchmark types -- two synthetic (sequential SLOAD/SSTORE) and three ERC20 contract workloads (balanceOf, approve, mixed) -- each run 9-10 times under a verified cold-cache protocol on a dedicated QEMU VM (8 vCPUs, 30 GB RAM, 3.9 TB SSD).

**Result:** The sweet spot is GD-5 or GD-6, depending on workload. GD-5 is the write champion (6.94 Mgas/s, **+7% over GD-4**, p < 1e-9). GD-6 leads reads (6.39 Mgas/s) and mixed workloads (6.27 Mgas/s, **+19% over GD-4**). GD-7 confirms the inflection -- performance degrades past GD-6 on all benchmarks. The write-read optimum lies at 5--6 bits per node, narrower than the initial GD-8 assumption.

[Full report](group-depth-benchmarks/index.html) ·
[ethresear.ch post](group-depth-benchmarks/ethresearch-post.md) ·
[Raw data](group-depth-benchmarks/data/)

### [MPT vs Binary Trie](mpt-vs-bintrie/)

Head-to-head comparison of production MPT (upstream geth) against optimized BT-GD5 (bintrie fork with 3 merged performance PRs) on bare-metal AMD EPYC (48 cores, 126 GB RAM, 3.5 TB SSD RAID). Three ERC20 benchmarks (balanceOf, approve, mixed) with 100 MPT runs and 10 BT runs under cold-cache protocol on ~1.5 TB databases with ~400M state entries.

**Result:** BT-GD5 is 1.7× slower on reads (19.0 vs 11.2 Mgas/s), 9.6× on writes (99.8 vs 10.4 Mgas/s raw), and 3.0× on mixed workloads (29.8 vs 9.8 Mgas/s). The write gap is inflated by a cache asymmetry artifact (BT 35--73% storage cache hit rate vs MPT 7--15%). Per-cache-miss read cost shows a 2.8× structural penalty. The binary trie is not ready for production today, but the optimization trajectory is encouraging and the snapshot layer -- the largest potential improvement -- remains unexplored.

[Full report](mpt-vs-bintrie/index.html) ·
[ethresear.ch post](mpt-vs-bintrie/ethresearch-post.md) ·
[Raw data](mpt-vs-bintrie/data/)

### [UBT vs PBT](ubt-vs-pbt/)

Head-to-head comparison of two binary trie variants at the same group depth (5), with state reads served from a **flat-state snapshot**: **UBT** (Unified Binary Trie -- a contract's storage scattered across the keyspace by a full hash) vs **PBT** (Partitioned Binary Trie -- zone-partitioned keys that cluster a contract's storage contiguously, plus parallel per-zone commit). Three scattered-access benchmarks where each operation hits a different one of **2000 CREATE2 getter contracts** -- raw `SLOAD` / `SSTORE` / mixed, not real ERC20 semantics -- so PBT cannot stream any single contract's clustered storage. 30 cold-cache runs × 1 tx-per-block (mpt-vs-bintrie-style: identical block structure across configs, no packing asymmetry), on ~72 GB databases (Intel Xeon 8358, 8 cores, 31 GB RAM).

**Result:** PBT's edge decomposes into two distinct effects. **Reads: 0.84×** (174.9 → 146.4 Mgas/s, p=1.2e-6) -- PBT is actually *slower*; the 1.75× concentrated-access win was entirely disk locality, and once scattering removes it the per-block 3-zone-root overhead dominates. **Writes: 1.43×** (46.8 → 67.0 Mgas/s, p=4.6e-10) -- the parallel-zone-commit advantage is structural and survives scattering. **Mixed: 1.05× (NS).** Per-cache-miss ratio on reads is 0.97 (PBT pays the same per cold disk read) and per-slot hash on writes is 0.82 (parallel commit). Same-state holds (aggregate gas-per-slot = 1.0000 all three). So PBT's edge is *one* clean structural win on writes plus a workload-dependent locality bonus on reads that ranges from very large (concentrated) to negative (scattered).

[Full report](ubt-vs-pbt/index.html) ·
[Raw data](ubt-vs-pbt/data/)
