# Operations checklist

## Before starting

- Confirm no other model owns the selected two GPUs or port 8080.
- Confirm FreeToken and model revisions match `freetoken.lock`.
- Confirm all 48 checkpoint shards are present and total 510,286,023,000 bytes.
- Provide substantially more than the approximately 475 GiB stable process RSS;
  the accepted host has 1 TiB RAM.
- Ensure the service has `LimitMEMLOCK=infinity` and swap is unused.
- Run `scripts/preflight.sh` before the foreground launcher or service.
- Keep adequate DIMM and GPU airflow during the ten-minute pinned-bank load.

The launcher never evicts another model automatically. Stop the conflicting model,
wait for its GPU memory and pinned pages to release, then start DeepSeek.

## Acceptance gate

1. `/health` and `/v1/models` respond and publish a 65,536-token context.
2. A thinking-disabled deterministic sentinel returns exactly once.
3. The historical 64-token greedy oracle remains byte-identical.
4. A unique prompt longer than one 4,096-token scheduler chunk completes cleanly.
5. Capacity changes pass unique 60K and 64K-near-limit prompts plus generation.
6. `/v1/stats` returns to zero active requests and zero used KV after release.
7. Only then accept throughput or latency measurements.

Performance without these gates is diagnostic, not an accepted result.

## Qualified runtime defaults

- Batch/concurrency: one
- Advertised context: 65,536 tokens
- Full KV: 512 pages of 128 tokens
- SWA/full-token ratio: 0.28125
- Scheduler prefill chunk: 4,096 tokens
- Expert caches: 704 slots on GPU0, 1,450 on GPU1
- Expert and Engram source: pinned host RAM; zero steady disk reads
- Attention: `dsv4_sparse`
- CUDA graphs: enabled with batch-size ceiling one
- Prompt cache: radix
- Sampling: temperature 1.0, top-p 0.95 when a request omits them
- Reasoning parser: `deepseekv32`; default numeric effort 25
- Output cap: none at server level
- MTP/DSpark and vision: off/not implemented in this profile

Reasoning effort is a soft checkpoint input. It does not reserve or cap KV and it
does not stop a response after a proportional number of tokens. Requests without an
explicit output limit can consume all context remaining after the prompt.

## Startup and shutdown expectations

A clean accepted start took about 9 minutes 40 seconds. Four serialized Engram
source reads dominate roughly five minutes of that interval; each 47.2 GB shard
took about 79 seconds. Stable RSS was approximately 475 GiB. Do not treat the unit
as failed while weights are still progressing unless its logs show a real fault.

Clean shutdown and kernel unpin took about 1 minute 40 seconds. Wait for the process
to exit and pinned pages to fall before starting another large model. A five-minute
systemd stop timeout is intentional.

Useful read-only checks:

```bash
journalctl -u deepseek41-flash-freetoken.service -f
nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv
free -h
curl --fail http://172.17.0.1:8080/health
curl --fail http://172.17.0.1:8080/v1/stats
```

## Capacity guardrails

The accepted near-limit run peaked at 32,120 MiB on GPU0 and left only about
31–93 MiB driver-visible there after allocator high-water reservations. Do not
increase GPU0 cache slots, prefill chunk size, KV pages, graph batch size, or
concurrency together. Change one variable, reload cleanly, and repeat both long
capacity gates.

GPU1 retained more margin because it does not own the dense backbone. Increasing
its cache can only improve coverage for its own 192 experts; it cannot recover
GPU0-owned cache rows.

## Failure triage

- Startup OOM: verify the 704/1,450 cache geometry, 512 KV pages, graph batch one,
  and that no stale process owns either GPU.
- Long-prefill OOM: return to a 4,096-token scheduler chunk and the 704-slot root
  cache. Earlier 808/768-slot candidates failed at 60K.
- Slow first request: distinguish the ten-minute bank load and one-time kernel/JIT
  work from warm request throughput.
- Decode regression: check CUDA graph activation, expert-cache misses, PCIe traffic,
  and whether a driver/topology change invalidated the graph/P2P qualification.
- Host thrash or disk reads: confirm memlock is unlimited, RSS is resident, and swap
  remains zero. This profile is not qualified with disk-offloaded Engram.
- Repetition or changed greedy output: stop performance testing and run the exact
  oracle; do not accept a faster topology before resolving correctness.

## Rollback

Stop the DeepSeek service and allow it to unpin fully. Start the preserved Qwen or
other known-good unit only after the GPUs, port, and pinned-memory tier are free.

For a feature-level rollback, first set `DSV41_CUDA_GRAPH=0` and re-run the eager
oracle. Keep the accepted KV and cache geometry unchanged while isolating the fault.
Do not enable the experimental fused router or dense TP controls in this profile.
