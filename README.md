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

Locality-sweep mechanism characterization for two binary trie key derivations: **UBT** (`key = H(addr ‖ slot)` — keys randomly scattered in Pebble) vs **PBT** (`key = zone_prefix ‖ H(addr) ‖ slot` — a contract's storage stems sit adjacent in the keyspace). Both configs use a single binary trie at group depth 5 with state reads served from the flat-state snapshot. Twelve cells (SLOAD / SSTORE / mixed × K∈{1, 10, 100, 256} contracts per block), 20 cold-cache runs per cell × 1 tx-per-block on ~75 GB databases (Intel Xeon 8358, 8 cores, 31 GB RAM).

**Result:** the original "PBT loses 0.54–0.97×" finding was the product of two compounding methodology issues. (1) The PBT geth fork carries a `parallel zone updates` commit that splits the trie at depth 0 and recursively deep-copies both sub-views every block — paying ~30–70 ms of `copyFrom` overhead per block for a parallelism gain that almost never materializes (zone activity is heavily skewed: gas accounting writes only zone 000, sstore workloads write only zone 1). (2) Geth was started with `--cache 0`, disabling Pebble's block cache and suppressing the within-block read locality PBT was designed to exploit. With the parallel-zone code disabled (one-line patch forcing the existing sequential fallback) and Pebble's default cache enabled, the picture flips: PBT lands at parity with UBT overall (ratios 0.94–1.07×), modestly favored on high-clustering workloads (SSTORE_k1 = 1.07×, SSTORE_k10 = 1.07×, mixed_k1 = 1.05×) and marginally slower at full scatter (SSTORE_k256 = 0.94×). The clustering mechanism produces visible savings on both `state_read_ms` (4–8 ms at high K) and `state_hash_ms` (3 ms at low K, because dirty internal nodes' children share Pebble cache lines under clustering).

[Full report](ubt-vs-pbt/index.html) ·
[Raw data](ubt-vs-pbt/data/)
