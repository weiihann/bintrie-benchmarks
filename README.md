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

Head-to-head comparison of two binary trie variants at the same group depth (5), now that state reads are served from a **flat-state snapshot** instead of trie traversal: **UBT** (Unified Binary Trie -- single key-derivation, a contract's storage scattered across the keyspace by a full hash) vs **PBT** (Partitioned Binary Trie -- zone-partitioned keys that cluster a contract's storage contiguously, plus parallel per-zone commit). Three ERC20 benchmarks visited on a power-law weighted schedule (5 runs × 30 weighted visits across 10 contracts, cold-cache) on ~73 GB databases (Intel Xeon 8358, 8 cores, 31 GB RAM).

**Result:** PBT outperforms UBT on every benchmark, by a wide margin: **1.75× on reads** (31.1 → 54.4 Mgas/s, p=1.5e-147), **2.83× on writes** (31.9 → 90.2 Mgas/s, p=1.6e-128), **2.41× on mixed** (28.8 → 69.3 Mgas/s, p≈0). All Mann-Whitney significant; bootstrap 95% CIs exclude 1.0 by a wide margin; same-state holds (aggregate gas-per-slot = 1.0000). The result flips the original hypothesis: flat-state was expected to *erase* PBT's read advantage, but it *grew* (+11% → 1.75×). The cause is disk locality -- PBT's zone-partitioned keys place a contract's flat-state blobs contiguously in Pebble (near-sequential reads), while UBT's full-hash keys scatter them (random seeks): each cold read is ~2.4× cheaper for PBT. Parallel zone commit adds a smaller write-side win.

[Full report](ubt-vs-pbt/index.html) ·
[Raw data](ubt-vs-pbt/data/)
