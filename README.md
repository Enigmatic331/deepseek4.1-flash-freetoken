# DeepSeek V4.1 Flash on FreeToken

This repository preserves more than one accepted machine topology. The
top-level deployment below is the 2026-10-21 packed-KV 1M RTX profile; it is
kept intact as reproducible engineering history. See the
[`topologies/`](topologies/README.md) catalog for frozen alternatives, including
the 2026-10-30 dual-CMP 512K resident-r3 production topology.

Reproducible deployment profile for the official DeepSeek-V4.1-Flash checkpoint
on two RTX 5090s, one modified 48 GiB RTX 4090, and one modified 32 GiB RTX
4080 SUPER. All four GPUs are text expert-parallel ranks. The 4080 SUPER also
runs the checkpoint's native vision tower. Authoritative expert and Engram banks
remain pinned in host RAM, with bounded CPU expert assistance on ranks 1 and 2.

The selected profile advertises 1,048,576 tokens. DeepSeek V4.1 already rounds
each compressed main-KV row to FP4; the final FreeToken branch stores those
exact rounded values as E2M1 nibbles plus one E4M3 scale per 16 channels instead
of expanding them in the persistent pool. The representation unpacks to the
same BF16 bits, so the capacity gain adds no new numerical approximation. SWA
remains BF16. The profile keeps the public prefill chunk at 8,192 tokens and
admits at most two concurrent requests through the qualified C2 scheduler.
Direct P2P is used only between the qualified RTX 5090 pair. DSpark/MTP is
disabled.

## Pinned stack

- Model: `deepseek-ai/DeepSeek-V4.1-Flash-1017`
- Model revision: `1bae0e1088993b9b82de08f59de5be5a34e42170`
- FreeToken branch: <https://github.com/Enigmatic331/FreeToken/tree/dsv41-final-20261016>
- Qualified FreeToken revision: `5b0a6310e69fdc6752b79bf9b974b66b12347aae`
- Checkpoint: 48 shards, 510,286,023,000 indexed tensor bytes

Exact pins are recorded in [`freetoken.lock`](freetoken.lock).

## Qualified placement

| Role | Rank 0 / RTX 5090 | Rank 1 / RTX 5090 | Rank 2 / RTX 4090 | Rank 3 / RTX 4080 SUPER |
| --- | ---: | ---: | ---: | ---: |
| Decode-owned experts | 16 | 136 | 160 | 72 |
| Prefill-owned experts | 112 | 128 | 112 | 32 |
| Stored expert range | `0:112` | `16:224` | `144:208` | `288:96` |
| MoE cache slots | 240 | 1,536 | 2,494 | 1,552 |
| Dense/attention/KV authority | yes | no | no | no |
| Native vision | no | no | no | yes |

The RTX 5090 ranks own the row-sharded Engram tables. Ranks 1 and 2 each have a
24-thread CPU expert pool with a one-miss background-admission ceiling. Logical
GPU ordering is part of the profile; map it to stable UUIDs in the untracked host
configuration rather than committing device identifiers.

Material runtime geometry:

```text
Context:             1,048,576 tokens
Full KV pages:       8,192 x 128 tokens, authority only
Physical SWA pages:  1,152 x 128 tokens
Scheduler prefill:   8,192 tokens
Internal EP tile:    4,096 tokens
Text ranks:          four
Concurrency:         at most two requests (qualified C2 path)
Main KV / SWA:       exact packed FP4+scale storage / BF16
Vision:              native checkpoint tower on rank 3's 4080 SUPER
MTP:                 disabled
```

## Accepted final-profile results

These are measurements on the qualified host, not portable promises.

| Gate | Previous accepted control | Packed-KV 1M | Change |
| --- | ---: | ---: | ---: |
| Stable single-stream decode mean | 40.222 tok/s | 40.175 tok/s | -0.12% |
| 4,096-token cold prefill TTFT | 3.912 s | 3.905 s | -0.18% |
| 17,490-token cold prefill TTFT | 9.814 s | 9.778 s | -0.37% |
| Near-ceiling prompt | — | 1,040,000 tokens | exact recall |

Effective prefill is not one fixed number; it depends strongly on the submitted
prompt size and resulting scheduler batches:

| Submitted prompt | TTFT | Effective prefill |
| ---: | ---: | ---: |
| 4,096 tokens | 3.9054 s | **1,048.8 tok/s** |
| 17,490 tokens | 9.7778 s | **1,788.7 tok/s** |
| 40,000 tokens | 13.8911 s | **2,879.5 tok/s** |
| 1,040,000 tokens | 361.061 s | **2,880.4 tok/s** |

See [`docs/performance.md`](docs/performance.md) for metric definitions, chunk
shapes, decode performance, interpretation limits, and the practical explanation
for why larger submissions achieve higher effective prefill throughput.

The packed profile returned the same short decode hash in three repetitions and
recalled three planted keys exactly and in order at depths through 935,843 tokens.
The 1.04M request used 8,126/8,192 main-KV pages, achieved 2,880.4 prompt tok/s,
and released main KV and SWA immediately afterward. Minimum authority free VRAM
was 2,288.62 MiB; the hottest DIMM reached 59 C, with no thermal throttle,
Xid/AER/MCE/EDAC/OOM event, cache leak, or service restart.

See [`docs/qualification-20261021-packed-kv-1m.md`](docs/qualification-20261021-packed-kv-1m.md)
and [`results/production-packed-kv-1m.csv`](results/production-packed-kv-1m.csv).
The older 512K, 786K, and ownership reports remain as historical evidence, not
as current defaults.

## Deploy

1. Clone the pinned FreeToken fork and check out the revision in
   [`freetoken.lock`](freetoken.lock).
2. Install FreeToken using its upstream instructions in a dedicated environment,
   including the CPU MoE extension required by the qualified hybrid path.
3. Download all 48 official checkpoint shards and tokenizer/config files.
4. Copy [`.env.example`](.env.example) to a host-only file, restrict its
   permissions, and set paths plus stable device ordering.
5. Run [`scripts/preflight.sh`](scripts/preflight.sh).
6. Run [`scripts/run.sh`](scripts/run.sh) in the foreground for qualification.
7. Run [`scripts/smoke-test.sh`](scripts/smoke-test.sh), the deterministic oracle,
   native image, C2 isolation/cancellation, and long-context gates.
8. Install the reviewed systemd template only after adapting its generic service
   user and paths.

The example binds to loopback. Choose a deliberately firewalled internal address
only when a separate frontend must connect from another network namespace.

## Safety notes

- C2 means at most two admitted requests; it does not promise twice the aggregate
  decode throughput or equal latency for arbitrary mixed workloads.
- Do not raise context, KV pages, the 8,192-token scheduler chunk, 4,096-token
  route tile, graph batch size, caches, or concurrency without repeating the full
  correctness, cancellation, memory, and capacity gates.
- Packed main-KV storage, packed-prefill Gluon, and transient packed-decode
  staging are one qualified startup profile. Do not toggle its representation
  while pages or captured graphs are live.
- Do not assume P2P from GPU model names. Reverify pairwise payload integrity and
  bandwidth after any driver, kernel, BIOS, motherboard, riser, or slot change.
- Only the RTX 5090 pair is expected to use P2P. RTX 4090/4080 edges retain the
  shared-memory path.
- Keep `LimitMEMLOCK=infinity`; pinned host banks are part of the runtime design.
- `--moe-collect-stats` is deliberately absent from the final hot path. Turn it
  back on only for a bounded diagnostic run.

See [`docs/architecture.md`](docs/architecture.md) for placement constraints and
[`docs/operations.md`](docs/operations.md) for startup, monitoring, and rollback.
