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

Head-to-head comparison of two binary trie variants at the same group depth: **UBT** (Unified Binary Trie -- bitarray path encoding, single-pass commit) vs **PBT** (Partitioned Binary Trie -- zone-partitioned key derivation across `basic-data`, `code-chunk`, `storage-slot` zones, with parallel per-zone commit). Three ERC20 benchmarks with 10 cold-cache runs each on ~50 GB databases (Intel Xeon 8358, 8 cores, 31 GB RAM).

**Result:** PBT outperforms UBT on every benchmark. **+11.0% on reads** (15.95 → 17.70 Mgas/s, p=9.9e-12), **+20.6% on writes** (46.56 → 56.16 Mgas/s, p=4.5e-7), **+17.5% on mixed** (22.60 → 26.56 Mgas/s, p=1.3e-5). All Mann-Whitney significant; bootstrap 95% CIs for throughput exclude 1.0 on all three. Per-slot decomposition shows the wins come from shorter average path lengths within each zone (-12 to -26% per-slot read cost) and parallel hashing across the three zone subtries (-12 to -19% per-slot hash cost). The same-state guarantee holds (gas-per-slot ratio = 1.0000) -- only the trie shape differs.

[Full report](ubt-vs-pbt/index.html) ·
[Raw data](ubt-vs-pbt/data/)
