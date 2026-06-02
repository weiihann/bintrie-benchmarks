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

Locality-sweep mechanism characterization for two binary trie key derivations: **UBT** (`key = H(addr ‖ slot)` — keys randomly scattered in Pebble) vs **PBT** (`key = zone_prefix ‖ H(addr) ‖ slot` — a contract's storage stems sit adjacent in the keyspace). Both configs use a single binary trie at group depth 5 with state reads served from the flat-state snapshot. Fifteen cells (SLOAD / SSTORE / mixed × K∈{1, 10, 100, 400, 700} contracts per block), 20 cold-cache runs per cell × 1 tx-per-block, T=700 stem touches per block (~16 M-gas tx at the Osaka per-tx cap), on ~75 GB databases (Intel Xeon 8358, 8 cores, 31 GB RAM). PBT measured with the `noparallel` patch (parallel-zone deep-copy code disabled, sequential fallback).

**Result:** PBT's clustering helps reads at every K (1.00–1.05×), but PBT's sequential commit path scales worse per write than UBT's — at mainnet-realistic block sizes (16 M gas) PBT loses on writes by 15–25% (SSTORE 0.75–0.86×) and on mixed workloads by 2–6%. The earlier T=256 (~6 M-gas blocks) campaign found "PBT at parity, favored at low K (sstore_k1 = 1.07×)"; that result didn't generalize because larger blocks expose a per-write cost in the per-zone commit machinery that smaller blocks hide under per-block fixed overhead. Decomposing the per-block time at sstore_k1 across the two campaigns: UBT's `state_hash_ms` scales sublinearly (2.21× growth for 2.7× more touches); PBT's scales superlinearly (4.28× growth for the same work). The natural fix is the `perf/pbt-parallel-commit` branch's zero-copy + N-way parallel hash, but that binary currently produces invalid state roots; it couldn't be measured at scale.

[Full report](ubt-vs-pbt/index.html) ·
[Raw data](ubt-vs-pbt/data/)
