# Architecture and correctness constraints

## Placement

FreeToken starts one process per RTX 5090 and uses a two-rank heterogeneous EP
topology. Rank 0 owns the complete TP1 text backbone and is the authority for
dense layers, attention, shared experts, logits, and sampling. Rank 0 owns routed
experts 0–191; rank 1 owns experts 192–383. The expert banks remain pinned in host
RAM and populate independent rank-local GPU caches on demand.

DeepSeek V4.1's Engram conditional-memory tables account for roughly 196B model
parameters. FreeToken row-shards each table across both ranks, pins the source
shards in RAM, performs lookups on the GPUs, and combines the results through the
rank group. Engram is not CPU decode. Keeping the source resident and pinned avoids
disk reads and was measurably preferable to adding another out-of-core tier.

The final GPU expert-cache geometry is deliberately asymmetric:

```text
rank 0 / GPU0: 704 slots, complete backbone, graph authority, transient prefill work
rank 1 / GPU1: 1,450 slots, peer routed-expert bank, larger spare-VRAM allocation
```

Expert ownership is rank-local. Spare GPU1 memory cannot cache GPU0-owned experts
without changing the sharding and communication protocol.

## CED, sparse attention, and KV

V4.1 uses a 20-layer causal encoder followed by a 20-layer decoder. FreeToken's
`dsv4_sparse` backend implements the CSA2 source/reuse layout and hierarchical
sparse indexer needed by the checkpoint. The accepted 64K geometry has 512
full-token pages, a 0.28125 SWA/full ratio, 128-token pages, and 4,096-token outer
prefill chunks. Persistent V4.1 KV allocation is about 0.91 GiB per rank.

The 64K allocation alone fits comfortably. The tight point is GPU0's combination
of the whole backbone, expert cache, KV, CUDA graphs, and long-prefill temporaries.
GPU0 cache was reduced from 856 to 704 slots after 808- and 768-slot candidates
failed unique 60K prompts. The accepted 704-slot candidate completed unique 60K
and near-limit 64K gates.

## Position-bucketed CUDA graphs

A single maximum-width decode graph is not numerically equivalent to eager sparse
attention: a static split-K topology can change the BF16 reduction order at short
positions. FreeToken captures ranges over which every V4.1 compression ratio uses
the same eager topology:

```text
1–127, 128–255, 256, 257–383, 384–512, 513–768, 769–65535
```

Real-checkpoint shadow replays were byte-identical at the bucket boundaries and
the historical exact-output oracle remained unchanged. The final range retains the
full sequence ceiling; live device counts mask its unused tail. Graphs more than
doubled the accepted warm short decode rate versus the eager control, but remain an
explicit environment opt-in because topology and driver changes require a fresh
qualification.

## Data movement and bottlenecks

Expert miss refill is the principal steady decode cost. An Nsight control attributed
54.3% of summed authority GPU kernel time in later decode steps to
`fast_index_copy_multi`. Unique long-prefill runs reached roughly 62–64 GiB/s of
observed aggregate PCIe receive traffic. Engram injection was only about 1.87 ms per
profiled token and is not the current decode bottleneck.

`--moe-prefill-hit-d2d` lets cache-resident expert rows feed prefill directly on
their owning GPU. It improved an earlier warm 4K fixture by about 5.9% without
changing generated output. It does not turn GPU1 into a global cache for GPU0.

The accepted service sets `NCCL_P2P_DISABLE=1`. Direct-P2P full TP2+EP2 and
attention-only TP2+EP2 controls were tested separately. Full TP added dense
collectives, delayed rank 0 behind rank 1's expert path, changed floating-point
association, and remained slower in matched 4K prefill. Neither sharded-dense
candidate replaced authority EP2.

## Correctness boundary

- Dense backbone, attention, and final reduction authority remain on rank 0.
- Routed experts remain whole-expert EP2; no expert executes on the CPU.
- Engram is row-sharded, pinned in RAM, and evaluated by GPU kernels.
- CUDA graph buckets must match eager sparse-attention topology.
- Cache and KV changes require exact-output and long-capacity gates before speed.
- Vision and DSpark/MTP are not part of the current FreeToken V4.1 implementation.
