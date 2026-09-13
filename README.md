# DeepSeek V4.1 Flash on FreeToken

Reproducible experimental profile for the official DeepSeek-V4.1-Flash
checkpoint on two RTX 5090s. The dense text backbone stays whole on GPU0;
the 384 routed experts are split 192/192 across both GPUs. The streamed expert
banks and the 196B-parameter Engram memory tier remain pinned in host RAM.

This repository packages the deployment profile, operational checks, and accepted
benchmark evidence. FreeToken's current V4.1 gate is text-only; vision and
DSpark/MTP are outside this profile.

## Pinned stack

- Model: `deepseek-ai/DeepSeek-V4.1-Flash`
- Model revision: `dba1be0a40aa45a94ad051997016db3960a90277`
- FreeToken branch: <https://github.com/Enigmatic331/FreeToken/tree/dsv41-flash>
- Public profile revision: `50696003b7f372369c0e42b7a2662e7e3ec3cdbd`
- Exact live-tested runtime: [`dsv41-flash-64k-v0`](https://github.com/Enigmatic331/FreeToken/tree/dsv41-flash-64k-v0) (`77795eb4736a985b064a1bd2a8e30ee842efff2e`)
- Development base: `qwen38-ep2` at `19634c8e13cfb17eb347ad2a710449922acb8600`

The public profile revision differs from the live-tested runtime only by
documentation, CLI help text, and portable checkpoint-test paths. Exact pins are
also recorded in [`freetoken.lock`](freetoken.lock).

## Accepted topology

```text
GPU0 RTX 5090: complete text backbone, shared experts, routed experts 0..191,
               704 rank-local expert-cache slots, CUDA graph authority
GPU1 RTX 5090: routed experts 192..383, 1,450 rank-local expert-cache slots
CPU RAM:       pinned expert banks plus row-sharded Engram tables (~475 GiB RSS)
Transport:     heterogeneous EP2; accepted service sets NCCL_P2P_DISABLE=1
KV:            65,536-token DSV4.1 paged pool, 512 full pages, 0.28125 SWA ratio
Prefill:       4,096-token scheduler chunks, D2D reuse for resident expert rows
Decode:        one request stream, position-bucketed CUDA graphs, DSpark/MTP off
Sampling:      temperature 1.0, top-p 0.95; explicit request values win
Reasoning:     effort 25 by default; soft prompt control, not a token cap
```

Engram and expert misses are materialized on the GPUs; this profile does not run
any model layer as CPU decode. Host RAM is a pinned weight tier, not a CPU compute
tier. See [`docs/architecture.md`](docs/architecture.md) for the placement and
correctness constraints.

## Accepted performance

The final 64K/cache-704 profile passed the historical exact-output oracle,
official-sampling sentinel, unique 60K prompt, and 64K-near-limit capacity gate.

| Case | Prompt | Prefill tok/s | Decode tok/s | TTFT |
| --- | ---: | ---: | ---: | ---: |
| Exact short oracle | 64 | 11.21 | 13.48 | 5.709 s |
| Warm 4K mean (2) | 4,096 | 776.54 | 14.47 | 5.275 s |
| Unique long prompt | 60,000 | 1,450.57 | 13.17 | 41.363 s |
| Near-limit capacity | 64,000 | 1,404.91 | 13.35 | 45.555 s |
| Long-decode mean (2) | 64 | 13.06 | 16.33 | 4.900 s |

The 64K run generated 31 additional tokens and peaked at 32,120 MiB on GPU0
and 30,560 MiB on GPU1. Driver-visible GPU0 margin was only about 31–93 MiB at
the allocator high-water mark. The 4K profile is approximately 2.2% slower than
the earlier 856-slot reference because GPU0 cache capacity was deliberately traded
for long-prefill workspace.

These numbers are batch-one observations from one host, not portable promises.
Correctness gates precede all performance acceptance. Raw accepted rows are in
[`results/accepted.csv`](results/accepted.csv).

## Cold load and memory

- Checkpoint payload: 510,286,023,000 bytes across 48 safetensor shards.
- Ready time after a clean start: about 9 minutes 40 seconds.
- Each 47.2 GB rank-local Engram shard loaded in about 79 seconds at 640–641 MB/s.
- Stable process RSS: roughly 475 GiB; swap remained unused.
- Clean shutdown and unpin: roughly 1 minute 40 seconds.
- The service requires `LimitMEMLOCK=infinity`; this is why the systemd template
  carries an explicit limit.

## Deploy

1. Clone the pinned FreeToken fork and check out the revision in `freetoken.lock`.
2. Build/install FreeToken using its upstream instructions in the same environment.
3. Download all 48 official checkpoint shards and tokenizer/config files locally.
4. Copy `.env.example` to a host-only `.env` and edit paths and GPU identifiers.
5. Run `scripts/preflight.sh`, then `scripts/run.sh` for a foreground qualification.
6. Run `scripts/smoke-test.sh` before serving requests.
7. If desired, install the reviewed system service template only after replacing
   every `/home/USER` and `User=USER` placeholder.

The launcher binds to `172.17.0.1:8080` by default so a Dockerized frontend can
reach it without exposing the API to the LAN. Review the host firewall. The
launcher does not stop an existing Qwen or other GPU service for you.

## Safety notes

- Keep concurrency at one for this qualified geometry.
- Do not raise the 4,096-token prefill chunk or the 704-slot GPU0 expert cache
  without repeating the 60K and 64K capacity gates.
- Requalify position-bucketed graphs after driver, CUDA, allocator, BIOS, slot,
  topology, or kernel changes.
- Reasoning effort 25 is not a reasoning-token limit. With no request output cap,
  generation continues until EOS or the remaining context boundary.
- `NCCL_P2P_DISABLE=1` is part of this accepted service. Direct-P2P TP experiments
  are documented as controls, not promoted to the production profile.

See [`docs/operations.md`](docs/operations.md) for startup, monitoring, rollback,
and capacity checks.
