# Operations checklist

## Before starting

- Confirm the FreeToken checkout exactly matches `freetoken.lock` and has no
  local changes.
- Confirm all 48 checkpoint shards are present and the indexed tensor size is
  510,286,023,000 bytes.
- Confirm the visible order is two qualified RTX 5090s, the 48 GiB RTX 4090, and
  the auxiliary CMP 170HX.
- Confirm no other process owns material VRAM on those devices.
- Provide at least 600 GiB host RAM for the pinned banks and runtime overhead.
- Apply `LimitMEMLOCK=infinity` and keep swap pressure at zero.
- Re-run pairwise P2P integrity after a driver, kernel, BIOS, board, or slot change.
- Keep adequate direct airflow over host memory and every accelerator.

Run:

```bash
DSV41_CONFIG=/etc/deepseek41-flash-freetoken.env scripts/preflight.sh
```

## Acceptance gate

1. `/health` and `/v1/models` respond and advertise 524,288 tokens.
2. A deterministic thinking-disabled sentinel returns exactly once.
3. The accepted short, arithmetic/code, and 8K retrieval hashes match.
4. Native image OCR returns the expected fixture value.
5. A prompt longer than one 8,192-token scheduler chunk completes cleanly.
6. A capacity change passes a unique near-520K prompt plus generation.
7. `/v1/stats` returns to zero active requests and zero used KV after release.
8. Logs contain no OOM, NCCL, peer-access, CUDA, Xid, or backend-death error.

Performance without these gates is diagnostic rather than accepted.

## Qualified defaults

- Context: 524,288 tokens
- Concurrency: one
- Full KV: 4,096 pages of 128 tokens on rank 0 only
- SWA/full ratio: 0.28125
- Scheduler prefill chunk: 8,192 tokens
- Exact EP route tile: 4,096 tokens
- Expert caches: 256 / 1,472 / 2,350
- Decode ownership: 80 / 152 / 152
- Prefill ownership: 128 / 160 / 96
- Stored expert intervals: 0:128 / 80:208 / 232:152
- Engram ranks: 0 and 1
- Native vision: auxiliary device owned by rank 0
- P2P: enabled only after pairwise qualification; expected only on the RTX 5090 pair
- CUDA graphs: batch-size ceiling one
- Prompt cache: radix
- Sampling defaults: temperature 1.0 and top-p 0.95
- Reasoning effort: numeric 25
- DSpark/MTP: disabled

## Startup and shutdown

The qualified cold load is approximately ten minutes because hundreds of GiB of
expert and Engram data are read, registered, and pinned. Weight progress in the
journal is not a failure. The service template deliberately has an unlimited
startup timeout and a five-minute stop timeout.

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

The accepted 520K selective-P2P request peaked at 32,136 MiB on rank 0 and left
approximately 35 MiB free at its tightest point. Do not simultaneously increase
KV pages, the rank-0 cache, prefill chunk, route tile, graph batch size, or
concurrency. Change one variable and repeat the exact, OCR, and capacity gates.

Extra memory on an expert worker cannot extend rank 0's KV without implementing a
new attention/KV ownership protocol. This profile does not claim KV sharding.

## Failure triage

- **Startup peer-access error:** disable P2P, verify visible-device order, and
  rerun pairwise tests. Never force P2P on the RTX 4090 or vision edges.
- **Long-prefill OOM:** restore the 256-slot authority cache, 8,192 scheduler
  chunk, 4,096 route tile, and 256 MiB indexer cap.
- **Slow prefill:** verify RTX 5090 P2P was actually selected and that no stale
  process owns a peer context or VRAM.
- **Image hang:** confirm only rank 0 sees the vision device and all text ranks
  remain in the same ordered control-broadcast sequence.
- **Idle distributed timeout:** verify the scheduler heartbeat path and process
  versions match the pinned revision.
- **Output drift:** stop performance testing and run the exact oracle before
  changing caches, graphs, or transport.

## Rollback

Stop the service and wait for complete GPU and pinned-memory release. Set
`DSV41_NCCL_P2P_DISABLE=1` for the matched transport control. For an optimization
regression, disable one of the following while keeping the accepted geometry:

```text
DSV41_DECODE_REFILL_OVERLAP=0
DSV41_FUSED_ROUTE_PREP=0
DSV41_FUSED_DECODE_DISPATCH=0
```

Do not use DSpark/MTP as a rollback path; target-only decode is the qualified
production behavior.
