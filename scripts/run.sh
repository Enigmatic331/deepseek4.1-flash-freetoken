#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${DSV41_CONFIG:-$REPO_DIR/.env}"
LOCK_FILE="$REPO_DIR/freetoken.lock"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config: $CONFIG_FILE (copy .env.example and edit it)" >&2
  exit 1
fi

set -a
source "$LOCK_FILE"
source "$CONFIG_FILE"
set +a

: "${FREETOKEN_CHECKOUT:?}"
: "${FREETOKEN_PYTHON:?}"
: "${MODEL_PATH:?}"

actual_revision="$(git -C "$FREETOKEN_CHECKOUT" rev-parse HEAD)"
if [[ "$actual_revision" != "$FREETOKEN_REVISION" ]]; then
  echo "FreeToken revision mismatch: expected $FREETOKEN_REVISION, got $actual_revision" >&2
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

export CUDA_VISIBLE_DEVICES="${DSV41_CUDA_VISIBLE_DEVICES:-0,1}"
export NCCL_P2P_DISABLE="${DSV41_NCCL_P2P_DISABLE:-1}"
export NCCL_IB_DISABLE=1
export PYTHONPATH="$FREETOKEN_CHECKOUT/python"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export MALLOC_ARENA_MAX=4
export FREETOKEN_DSV41_INDEXER_MAX_LOGITS_MB="${DSV41_INDEXER_MAX_LOGITS_MB:-512}"
export FREETOKEN_DSV41_CUDA_GRAPH="${DSV41_CUDA_GRAPH:-1}"
export TVM_FFI_CACHE_DIR="${DSV41_TVM_FFI_CACHE_DIR:-/tmp/freetoken-dsv41-tvm-cache}"
mkdir -p "$TVM_FFI_CACHE_DIR"

extra_args=()
if [[ "${DSV41_MOE_PREFILL_HIT_D2D:-1}" == "1" ]]; then
  extra_args+=(--moe-prefill-hit-d2d)
fi

exec "$FREETOKEN_PYTHON" -m freetoken.cli serve \
  --model "$MODEL_PATH" \
  --served-model-name "${DSV41_SERVED_MODEL_NAME:-DeepSeek (Experimental)}" \
  --host "${DSV41_HOST:-172.17.0.1}" \
  --port "${DSV41_PORT:-8080}" \
  --gpu 0,1 \
  --tp-size 2 \
  --dsv41-backbone-rank 0 \
  --max-running-requests 1 \
  --max-seq-len-override "${DSV41_CONTEXT:-65536}" \
  --max-prefill-length "${DSV41_MAX_PREFILL_LENGTH:-4096}" \
  --num-pages "${DSV41_NUM_PAGES:-512}" \
  --swa-full-tokens-ratio "${DSV41_SWA_FULL_TOKENS_RATIO:-0.28125}" \
  --memory-ratio "${DSV41_MEMORY_RATIO:-0.90}" \
  --cache-type "${DSV41_CACHE_TYPE:-radix}" \
  --moe-backend offload \
  --moe-cache-sizes "${DSV41_MOE_CACHE_SIZES:-704,1450}" \
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
