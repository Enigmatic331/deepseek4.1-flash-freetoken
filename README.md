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
- Public profile revision: `2f761ac918fd4cf776a87ad190ba3af290fd117c`
- Exact live-tested runtime: [`dsv41-flash-256k-v1`](https://github.com/Enigmatic331/FreeToken/tree/dsv41-flash-256k-v1) (`2f761ac918fd4cf776a87ad190ba3af290fd117c`)
- Development base: `qwen38-ep2` at `19634c8e13cfb17eb347ad2a710449922acb8600`

Exact pins are also recorded in [`freetoken.lock`](freetoken.lock).

## Accepted topology

```text
GPU0 RTX 5090: complete text backbone, shared experts, routed experts 0..191,
               512 rank-local expert-cache slots, CUDA graph authority
GPU1 RTX 5090: routed experts 192..383, 1,250 rank-local expert-cache slots
CPU RAM:       pinned expert banks plus row-sharded Engram tables (~475 GiB RSS)
Transport:     heterogeneous EP2; accepted service sets NCCL_P2P_DISABLE=1
KV:            262,144-token DSV4.1 paged pool, 2,048 full pages, 0.28125 SWA ratio
Prefill:       8,192-token scheduler chunks, D2D reuse for resident expert rows
Decode:        graph-safe authority refill/shared overlap and fused EP route prep
Sampling:      temperature 1.0, top-p 0.95; explicit request values win
Reasoning:     effort 25 by default; soft prompt control, not a token cap
```

Engram and expert misses are materialized on the GPUs; this profile does not run
any model layer as CPU decode. Host RAM is a pinned weight tier, not a CPU compute
tier. See [`docs/architecture.md`](docs/architecture.md) for the placement and
correctness constraints.

## Accepted performance

The final 256K/cache-512 profile passed the historical exact-output oracle,
unique 128K prompt, and 260K-near-limit capacity gate while retaining the
previously qualified sampling defaults.

| Case | Prompt | Prefill tok/s | Decode tok/s | TTFT |
| --- | ---: | ---: | ---: | ---: |
| Exact short oracle | 64 | 11.06 | 12.86 | 5.786 s |
| Unique long prompt | 128,000 | 1,350.01 | 14.21 | 94.814 s |
| Near-limit capacity | 260,000 | 1,309.53 | 12.96 | 198.545 s |
| Post-long decode mean (3) | 64 | 12.72 | 15.14 | 5.033 s |

The 260K run generated 31 additional tokens and peaked at 32,146 MiB on GPU0
and 29,118 MiB on GPU1. Driver-visible GPU0 margin was about 461 MiB at the
allocator high-water mark. The 256K profile's post-long short decode mean is
about 9% below the prior 64K profile because expert-cache capacity was deliberately
traded for a four-times-larger KV pool.

These numbers are batch-one observations from one host, not portable promises.
Correctness gates precede all performance acceptance. Raw accepted rows are in
[`results/accepted.csv`](results/accepted.csv).

The refill-overlap optimization uses the same 127-token outputs as its control and
improved decode by 1.36%; every matched output hash was byte-identical.
The change does not alter prefill, KV capacity, cache sizes, or expert ownership.
Fusing EP localization and cache-safe inactive-id preparation then improved its
fresh matched control from 16.48 to 16.65 tok/s (+1.04%), again with byte-identical
outputs. Those are 64K optimization controls; the accepted 256K capacity profile
retains both code paths but has smaller expert caches.

## Cold load and memory

- Checkpoint payload: 510,286,023,000 bytes across 48 safetensor shards.
- Ready time after a clean start: about 10 minutes 2 seconds.
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
- Do not raise the 8,192-token prefill chunk or the 512-slot GPU0 expert cache
  without repeating the 128K and 260K capacity gates.
- Requalify position-bucketed graphs after driver, CUDA, allocator, BIOS, slot,
  topology, or kernel changes.
- Reasoning effort 25 is not a reasoning-token limit. With no request output cap,
  generation continues until EOS or the remaining context boundary.
- `NCCL_P2P_DISABLE=1` is part of this accepted service. Direct-P2P TP experiments
  are documented as controls, not promoted to the production profile.

See [`docs/operations.md`](docs/operations.md) for startup, monitoring, rollback,
and capacity checks.
