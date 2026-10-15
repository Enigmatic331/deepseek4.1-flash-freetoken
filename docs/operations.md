# Operations checklist

## Before starting

- Confirm the FreeToken checkout exactly matches `freetoken.lock` and is clean.
- Confirm all 48 checkpoint shards are present and the indexed tensor size is
  510,286,023,000 bytes.
- Confirm logical order: authority RTX 5090, worker RTX 5090, modified 48 GiB RTX
  4090, modified 32 GiB RTX 4080 SUPER.
- Confirm all four are text ranks and logical device 3 is also the vision device.
- Confirm no unrelated process owns material VRAM.
- Provide at least 900 GiB OS-visible host RAM for pinned banks and overhead.
- Apply `LimitMEMLOCK=infinity` and keep swap pressure at zero.
- Re-run pairwise P2P integrity after a driver, kernel, BIOS, board, riser, or
  slot change.
- Keep adequate direct airflow over host memory and every accelerator.

Run:

```bash
DSV41_CONFIG=/etc/deepseek41-flash-freetoken.env scripts/preflight.sh
```

## Acceptance gate

1. `/health` and `/v1/models` respond and advertise 786,432 tokens.
2. A deterministic thinking-disabled sentinel returns exactly once.
3. Accepted short, arithmetic/code, and retrieval outputs match exactly.
4. Native image OCR returns the expected fixture value.
5. Prompts spanning multiple 8,192-token chunks complete cleanly.
6. A near-ceiling unique prompt plus generation passes without OOM.
7. Two-request text, text+vision, cancellation, and long-prefill/resident-decode
   gates preserve isolation and bounded progress.
8. `/v1/stats` returns to zero active requests and zero used KV/SWA pages.
9. Logs contain no OOM, NCCL, peer-access, CUDA, Xid, AER/BadTLP, MCE/EDAC UE,
   or backend-death error.

Performance without these gates is diagnostic rather than accepted.

## Qualified defaults

- Context: 786,432 tokens
- Concurrency: at most two requests
- Full KV: 6,144 pages of 128 tokens on rank 0 only
- SWA: 1,152 physical pages (`swa_full_tokens_ratio=0.1875`)
- KV dtype: BF16
- Scheduler prefill chunk: 8,192 tokens
- Exact EP route tile: 4,096 tokens
- Expert caches: 240 / 1,536 / 2,350 / 1,408
- Decode ownership: 32 / 144 / 144 / 64
- Prefill ownership: 112 / 128 / 112 / 32
- Stored intervals: 0:112 / 32:208 / 144:208 / 288:96
- Engram ranks: 0 and 1
- CPU assistance: ranks 1/2, 24 threads each, one-fetch/one-miss ceiling
- Native vision: logical device 3, also text rank 3
- P2P: expected only on the RTX 5090 pair after pairwise qualification
- Prompt cache: radix
- Sampling defaults: temperature 1.0, top-p 0.95, numeric reasoning effort 25
- DSpark/MTP: disabled
- MoE statistics: disabled in the hot path; cache reporting enabled

## Startup and shutdown

Cold loading maps, registers, and pins hundreds of GiB of weights, then performs
kernel warmup. On the qualified host this can take roughly 15–20 minutes. Weight
progress in the journal is not by itself a failure. The service template uses an
unlimited startup timeout and a five-minute stop timeout.

Useful read-only checks:

```bash
journalctl -u deepseek41-flash-freetoken.service -f
nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv
free -h
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/v1/stats
```

Wait for every worker to exit and pinned pages to release before starting another
large model.

## Capacity guardrails

The qualified 786K complex run reached 1,576.62 MiB minimum authority free memory.
Do not simultaneously increase KV pages, authority cache, prefill chunk, route
tile, graph batch size, or concurrency. Change one variable and repeat exact,
image, cancellation, C2-isolation, and capacity gates.

Extra memory on an expert worker cannot extend rank 0's KV without a new
attention/KV ownership protocol. This profile does not claim KV sharding.

## Failure triage

- **Startup peer-access error:** disable P2P, verify visible-device order, and
  rerun pairwise tests. Never force P2P on RTX 4090/4080 edges.
- **Long-prefill OOM:** restore the documented caches, 8,192 scheduler chunk,
  4,096 route tile, 256 MiB indexer cap, and 6,144 pages.
- **Slow prefill:** verify RTX 5090 P2P was selected, grouped packed transport is
  enabled, and no stale process owns a peer context or VRAM.
- **C2 stall:** check the interleave/tail/cone startup fingerprints and ordered
  rank-control messages; do not increase admission while diagnosing.
- **Image hang:** confirm rank 3 owns vision and all ranks remain in the same
  ordered control-broadcast sequence.
- **Output drift:** stop performance testing and run the exact oracle before
  changing caches, graphs, quantization, or transport.

## Rollback

The immediately preceding production revision is pinned in `freetoken.lock` as
`FREETOKEN_PREVIOUS_PRODUCTION_REVISION`. For a feature-specific A/B, override
one switch at a time in the host-only environment and retain the same geometry.
For a full rollback, stop the service, wait for GPU and pinned-memory release,
check out the previous revision in a clean FreeToken tree, then restart and run
the exact smoke/capacity gates.

Do not use DSpark/MTP as a rollback path; target-only decode is the qualified
production behavior. Do not add `--moe-collect-stats` to normal production.
