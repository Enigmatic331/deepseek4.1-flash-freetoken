#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${DSV41_CONFIG:-$repo_dir/.env}"
lock_file="$repo_dir/freetoken.lock"

if [[ ! -f "$config_file" ]]; then
  echo "Missing config: $config_file (copy .env.example and edit it)" >&2
  exit 1
fi

set -a
source "$lock_file"
source "$config_file"
set +a

: "${FREETOKEN_CHECKOUT:?}"
: "${FREETOKEN_PYTHON:?}"
: "${MODEL_PATH:?}"

actual_revision="$(git -C "$FREETOKEN_CHECKOUT" rev-parse HEAD)"
if [[ "$actual_revision" != "$FREETOKEN_REVISION" ]]; then
  echo "FreeToken revision mismatch: expected $FREETOKEN_REVISION, got $actual_revision" >&2
  exit 1
fi

if [[ -n "$(git -C "$FREETOKEN_CHECKOUT" status --porcelain --untracked-files=all)" ]]; then
  echo "FreeToken checkout has local changes; use the pinned clean revision" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATH/model.safetensors.index.json" ]]; then
  echo "Checkpoint index is missing: $MODEL_PATH" >&2
  exit 1
fi

shopt -s nullglob
model_shards=("$MODEL_PATH"/model-*.safetensors)
if (( ${#model_shards[@]} != MODEL_SHARDS )); then
  echo "Checkpoint needs $MODEL_SHARDS shards; found ${#model_shards[@]}" >&2
  exit 1
fi

export CUDA_VISIBLE_DEVICES="${DSV41_CUDA_VISIBLE_DEVICES:-0,1,2,3}"
export NCCL_P2P_DISABLE="${DSV41_NCCL_P2P_DISABLE:-0}"
export NCCL_P2P_LEVEL="${DSV41_NCCL_P2P_LEVEL:-SYS}"
export NCCL_IB_DISABLE=1
export PYTHONPATH="$FREETOKEN_CHECKOUT/python"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export FREETOKEN_LOAD_VISION=1
export FREETOKEN_KERNEL_CACHE_DIR="${DSV41_KERNEL_CACHE_DIR:-/tmp/freetoken-dsv41-kernel-cache}"
export TVM_FFI_CACHE_DIR="${DSV41_TVM_FFI_CACHE_DIR:-/tmp/freetoken-dsv41-tvm-cache}"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export MALLOC_ARENA_MAX=4
export LOG_PID=1
export FREETOKEN_DSV41_INDEXER_MAX_LOGITS_MB="${DSV41_INDEXER_MAX_LOGITS_MB:-256}"
export FREETOKEN_DSV41_CUDA_GRAPH="${DSV41_CUDA_GRAPH:-1}"
export FREETOKEN_DSV41_DECODE_REFILL_OVERLAP="${DSV41_DECODE_REFILL_OVERLAP:-1}"
export FREETOKEN_DSV41_FUSED_ROUTE_PREP="${DSV41_FUSED_ROUTE_PREP:-1}"
export FREETOKEN_DSV41_FUSED_DECODE_DISPATCH="${DSV41_FUSED_DECODE_DISPATCH:-1}"
export FREETOKEN_EP_PREFILL_ROUTE_TILE_TOKENS="${DSV41_EP_PREFILL_ROUTE_TILE_TOKENS:-4096}"
mkdir -p "$FREETOKEN_KERNEL_CACHE_DIR" "$TVM_FFI_CACHE_DIR"

extra_args=()
if [[ "${DSV41_MOE_PREFILL_HIT_D2D:-1}" == "1" ]]; then
  extra_args+=(--moe-prefill-hit-d2d)
fi

exec "$FREETOKEN_PYTHON" -m freetoken.cli serve \
  --model "$MODEL_PATH" \
  --served-model-name "${DSV41_SERVED_MODEL_NAME:-DeepSeek (Experimental)}" \
  --host "${DSV41_HOST:-127.0.0.1}" \
  --port "${DSV41_PORT:-8080}" \
  --gpu "${DSV41_TEXT_GPUS:-0,1,2}" \
  --tp-size 3 \
  --disable-pynccl \
  --rank-local-cuda-visibility \
  --rank-local-cuda-peer-visibility \
  --dsv41-backbone-rank 0 \
  --dsv41-expert-shards "${DSV41_DECODE_EXPERT_SHARDS:-80,152,152}" \
  --dsv41-prefill-expert-shards "${DSV41_PREFILL_EXPERT_SHARDS:-128,160,96}" \
  --dsv41-expert-storage-ranges "${DSV41_EXPERT_STORAGE_RANGES:-0:128,80:208,232:152}" \
  --dsv41-engram-ranks "${DSV41_ENGRAM_RANKS:-0,1}" \
  --vision-device "${DSV41_VISION_DEVICE:-3}" \
  --max-running-requests 1 \
  --max-seq-len-override "${DSV41_CONTEXT:-524288}" \
  --max-prefill-length "${DSV41_MAX_PREFILL_LENGTH:-8192}" \
  --num-pages "${DSV41_NUM_PAGES:-4096}" \
  --swa-full-tokens-ratio "${DSV41_SWA_FULL_TOKENS_RATIO:-0.28125}" \
  --memory-ratio "${DSV41_MEMORY_RATIO:-0.90}" \
  --cache-type "${DSV41_CACHE_TYPE:-radix}" \
  --moe-backend offload \
  --moe-cache-sizes "${DSV41_MOE_CACHE_SIZES:-256,1472,2350}" \
  "${extra_args[@]}" \
  --expert-load serial \
  --attention-backend dsv4_sparse \
  --cuda-graph-max-bs 1 \
  --sampling-defaults none \
  --default-temperature "${DSV41_TEMPERATURE:-1.0}" \
  --default-top-p "${DSV41_TOP_P:-0.95}" \
  --reasoning-parser deepseekv32 \
  --default-reasoning-effort "${DSV41_REASONING_EFFORT:-25}" \
  --decode-log-interval "${DSV41_DECODE_LOG_INTERVAL:-8}"
