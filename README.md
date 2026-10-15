# DeepSeek V4.1 Flash on FreeToken

Reproducible deployment profile for the official DeepSeek-V4.1-Flash checkpoint
on two RTX 5090s, one modified 48 GiB RTX 4090, and one modified 32 GiB RTX
4080 SUPER. All four GPUs are text expert-parallel ranks. The 4080 SUPER also
runs the checkpoint's native vision tower. Authoritative expert and Engram banks
remain pinned in host RAM, with bounded CPU expert assistance on ranks 1 and 2.

The selected profile advertises 786,432 tokens with BF16 KV, keeps the public
prefill chunk at 8,192 tokens, and admits at most two concurrent requests through
the qualified C2 scheduler. Direct P2P is used only between the qualified RTX
5090 pair. DSpark/MTP is disabled.

## Pinned stack

- Model: `deepseek-ai/DeepSeek-V4.1-Flash`
- Model revision: `dba1be0a40aa45a94ad051997016db3960a90277`
- FreeToken branch: <https://github.com/Enigmatic331/FreeToken/tree/dsv41-final-20261016>
- Qualified FreeToken revision: `2e5eaf5f96d795af21512c54140ffa5263bfb86d`
- Checkpoint: 48 shards, 510,286,023,000 indexed tensor bytes

Exact pins are recorded in [`freetoken.lock`](freetoken.lock).

## Qualified placement

| Role | Rank 0 / RTX 5090 | Rank 1 / RTX 5090 | Rank 2 / RTX 4090 | Rank 3 / RTX 4080 SUPER |
| --- | ---: | ---: | ---: | ---: |
| Decode-owned experts | 32 | 144 | 144 | 64 |
| Prefill-owned experts | 112 | 128 | 112 | 32 |
| Stored expert range | `0:112` | `32:208` | `144:208` | `288:96` |
| MoE cache slots | 240 | 1,536 | 2,350 | 1,408 |
| Dense/attention/KV authority | yes | no | no | no |
| Native vision | no | no | no | yes |

The RTX 5090 ranks own the row-sharded Engram tables. Ranks 1 and 2 each have a
24-thread CPU expert pool with a one-miss background-admission ceiling. Logical
GPU ordering is part of the profile; map it to stable UUIDs in the untracked host
configuration rather than committing device identifiers.

Material runtime geometry:

```text
Context:             786,432 tokens
Full KV pages:       6,144 x 128 tokens, authority only
Physical SWA pages:  1,152 x 128 tokens
Scheduler prefill:   8,192 tokens
Internal EP tile:    4,096 tokens
Text ranks:          four
Concurrency:         at most two requests (qualified C2 path)
KV / weights:        BF16 KV / native checkpoint quantization
Vision:              native checkpoint tower on rank 3's 4080 SUPER
MTP:                 disabled
```

## Accepted final-profile results

These are measurements on the qualified host, not portable promises.

| Gate | Control | Final candidate | Change |
| --- | ---: | ---: | ---: |
| Sustained single-stream decode median | 35.349 tok/s | 35.875 tok/s | +1.49% |
| 17,490-token cold prefill TTFT | 9.749 s | 9.690 s | -0.60% |
| Production exact smoke decode | — | 35.731 tok/s | — |

The final token-boundary change preserved exact outputs, cache integrity,
cancellation, C2 admission, native vision, and hardware guards. Earlier C2 work
reduced the resident decoder's maximum pause from 9.807 to 5.317 seconds beside
a 17.5K prompt and from 13.285 to 4.200 seconds beside a 40K prompt. A 520K
partner held the resident pause to 4.016 seconds across a 170.91-second prefill.
The 786K geometry passed near-ceiling, retrieval, cancellation, and concurrent
400K/496K gates; its minimum observed authority free memory was 1,576.62 MiB.

See [`docs/qualification-20261016-final.md`](docs/qualification-20261016-final.md)
and [`results/production-final-20261016.csv`](results/production-final-20261016.csv).
The older 512K/EP3 reports remain in the repository as historical evidence, not
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
- Do not assume P2P from GPU model names. Reverify pairwise payload integrity and
  bandwidth after any driver, kernel, BIOS, motherboard, riser, or slot change.
- Only the RTX 5090 pair is expected to use P2P. RTX 4090/4080 edges retain the
  shared-memory path.
- Keep `LimitMEMLOCK=infinity`; pinned host banks are part of the runtime design.
- `--moe-collect-stats` is deliberately absent from the final hot path. Turn it
  back on only for a bounded diagnostic run.

See [`docs/architecture.md`](docs/architecture.md) for placement constraints and
[`docs/operations.md`](docs/operations.md) for startup, monitoring, and rollback.
