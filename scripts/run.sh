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

decode_shards="${DSV41_DECODE_EXPERT_SHARDS:-16,136,160,72}"
prefill_shards="${DSV41_PREFILL_EXPERT_SHARDS:-112,128,112,32}"
storage_ranges="${DSV41_EXPERT_STORAGE_RANGES:-0:112,16:224,144:208,288:96}"
cache_sizes="${DSV41_MOE_CACHE_SIZES:-240,1536,2494,1552}"

validate_four_values() {
  local label="$1" value="$2"
  local -a parts
  IFS=',' read -r -a parts <<< "$value"
  if (( ${#parts[@]} != 4 )); then
    echo "$label must contain exactly four comma-separated entries" >&2
    exit 2
  fi
}

validate_expert_sum() {
  local label="$1" value="$2" sum=0 item
  local -a parts
  IFS=',' read -r -a parts <<< "$value"
  for item in "${parts[@]}"; do
    if [[ ! "$item" =~ ^[0-9]+$ ]]; then
      echo "$label contains a non-integer entry: $item" >&2
      exit 2
    fi
    sum=$((sum + item))
  done
  if (( sum != 384 )); then
    echo "$label must own all 384 routed experts; got $sum" >&2
    exit 2
  fi
}

validate_four_values "decode shards" "$decode_shards"
validate_four_values "prefill shards" "$prefill_shards"
validate_four_values "storage ranges" "$storage_ranges"
validate_four_values "cache sizes" "$cache_sizes"
validate_expert_sum "decode shards" "$decode_shards"
validate_expert_sum "prefill shards" "$prefill_shards"

export CUDA_VISIBLE_DEVICES="${DSV41_CUDA_VISIBLE_DEVICES:-0,1,2,3}"
export NCCL_P2P_DISABLE="${DSV41_NCCL_P2P_DISABLE:-0}"
export NCCL_P2P_LEVEL="${DSV41_NCCL_P2P_LEVEL:-SYS}"
export NCCL_IB_DISABLE=1
export PYTHONPATH="$FREETOKEN_CHECKOUT/python${PYTHONPATH:+:$PYTHONPATH}"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export FREETOKEN_LOAD_VISION=1
export FREETOKEN_KERNEL_CACHE_DIR="${DSV41_KERNEL_CACHE_DIR:-/tmp/freetoken-dsv41-kernel-cache}"
export TVM_FFI_CACHE_DIR="${DSV41_TVM_FFI_CACHE_DIR:-/tmp/freetoken-dsv41-tvm-cache}"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export MALLOC_ARENA_MAX=4
export LOG_PID=1
mkdir -p "$FREETOKEN_KERNEL_CACHE_DIR" "$TVM_FFI_CACHE_DIR"

case "${FREETOKEN_CUDA_MODULE_LOADING:-LAZY}" in
  EAGER|LAZY) export CUDA_MODULE_LOADING="${FREETOKEN_CUDA_MODULE_LOADING:-LAZY}" ;;
  *) echo "FREETOKEN_CUDA_MODULE_LOADING must be EAGER or LAZY" >&2; exit 2 ;;
esac

# Qualified production feature set. Every switch remains independently
# overridable for rollback and controlled A/B work.
export DSPARK_ENABLED="${DSPARK_ENABLED:-0}"
export FREETOKEN_DSV41_DSPARK_CUDA_GRAPH_LENGTHS=""
export FREETOKEN_DSV41_DSPARK_DRAFT_CUDA_GRAPH=0
export FREETOKEN_DSV41_INDEXER_MAX_LOGITS_MB="${FREETOKEN_DSV41_INDEXER_MAX_LOGITS_MB:-256}"
export FREETOKEN_DSV41_CUDA_GRAPH="${FREETOKEN_DSV41_CUDA_GRAPH:-1}"
export FREETOKEN_DSV41_DECODE_REFILL_OVERLAP="${FREETOKEN_DSV41_DECODE_REFILL_OVERLAP:-1}"
export FREETOKEN_DSV41_FUSED_ROUTE_PREP="${FREETOKEN_DSV41_FUSED_ROUTE_PREP:-1}"
export FREETOKEN_DSV41_FUSED_DECODE_DISPATCH="${FREETOKEN_DSV41_FUSED_DECODE_DISPATCH:-1}"
export FREETOKEN_EP_PREFILL_ROUTE_TILE_TOKENS="${FREETOKEN_EP_PREFILL_ROUTE_TILE_TOKENS:-4096}"
export FREETOKEN_CPU_MOE_MAPPED_HANDOFF="${FREETOKEN_CPU_MOE_MAPPED_HANDOFF:-1}"
export FREETOKEN_DSV41_FP8_DECODE_TUNING="${FREETOKEN_DSV41_FP8_DECODE_TUNING:-1}"
export FREETOKEN_DSV41_BACKGROUND_ADMISSION="${FREETOKEN_DSV41_BACKGROUND_ADMISSION:-1}"
export FREETOKEN_DSV41_BACKGROUND_MAX_MISSES="${FREETOKEN_DSV41_BACKGROUND_MAX_MISSES:-1}"
export FREETOKEN_DSV41_CPU_ROUTE_PARALLEL="${FREETOKEN_DSV41_CPU_ROUTE_PARALLEL:-0}"
export FREETOKEN_DSV41_SKIP_EMPTY_CACHE="${FREETOKEN_DSV41_SKIP_EMPTY_CACHE:-1}"
export FREETOKEN_DSV41_CPU_FUSE_PREP="${FREETOKEN_DSV41_CPU_FUSE_PREP:-1}"
export FREETOKEN_DSV41_COMPACT_PREFILL_CANDIDATES="${FREETOKEN_DSV41_COMPACT_PREFILL_CANDIDATES:-1}"
export FREETOKEN_DSV41_NATIVE_BF16_HEAD="${FREETOKEN_DSV41_NATIVE_BF16_HEAD:-1}"
export FREETOKEN_DSV41_PHASE_CACHE_PRIORITY="${FREETOKEN_DSV41_PHASE_CACHE_PRIORITY:-1}"
export FREETOKEN_DSV41_WORKER_ENGRAM_SCRATCH="${FREETOKEN_DSV41_WORKER_ENGRAM_SCRATCH:-1}"
export FREETOKEN_DSV41_PREFILL_SKIP_INACTIVE="${FREETOKEN_DSV41_PREFILL_SKIP_INACTIVE:-1}"
export FREETOKEN_DSV41_CPU_LAYOUT_BANK="${FREETOKEN_DSV41_CPU_LAYOUT_BANK:-0}"
export FREETOKEN_DSV41_CPU_X2="${FREETOKEN_DSV41_CPU_X2:-1}"
export FREETOKEN_DSV41_CPU_WARM_WAIT_US="${FREETOKEN_DSV41_CPU_WARM_WAIT_US:-5000}"
export FREETOKEN_EP_PACKED_GROUPED_P2P="${FREETOKEN_EP_PACKED_GROUPED_P2P:-1}"
export FREETOKEN_EP_PACKED_ASYNC_SEND="${FREETOKEN_EP_PACKED_ASYNC_SEND:-1}"
export FREETOKEN_DSV41_SPARSE_CONSUMER_LOGITS="${FREETOKEN_DSV41_SPARSE_CONSUMER_LOGITS:-1}"
export FREETOKEN_DSV41_DEPENDENCY_CONE="${FREETOKEN_DSV41_DEPENDENCY_CONE:-1}"
export FREETOKEN_DSV41_DEPENDENCY_CONE_MIN_TOKENS="${FREETOKEN_DSV41_DEPENDENCY_CONE_MIN_TOKENS:-32768}"
export FREETOKEN_DSV41_TAIL_PAIRING="${FREETOKEN_DSV41_TAIL_PAIRING:-1}"
export FREETOKEN_DSV41_CONCURRENCY="${FREETOKEN_DSV41_CONCURRENCY:-1}"
export FREETOKEN_CUDA_GRAPH_VERIFY_STEPS="${FREETOKEN_CUDA_GRAPH_VERIFY_STEPS:-8}"
export FREETOKEN_DSV41_C2_PREFILL_INTERLEAVE="${FREETOKEN_DSV41_C2_PREFILL_INTERLEAVE:-1}"
export FREETOKEN_DSV41_AUTHORITY_FUSION="${FREETOKEN_DSV41_AUTHORITY_FUSION:-1}"
export FREETOKEN_DSV41_TOKEN_BOUNDARY_OVERLAP="${FREETOKEN_DSV41_TOKEN_BOUNDARY_OVERLAP:-1}"
export FREETOKEN_DSV41_PACKED_KV="${FREETOKEN_DSV41_PACKED_KV:-1}"
export FREETOKEN_DSV41_PACKED_PREFILL_GLUON="${FREETOKEN_DSV41_PACKED_PREFILL_GLUON:-1}"
export FREETOKEN_DSV41_PACKED_DECODE_STAGE="${FREETOKEN_DSV41_PACKED_DECODE_STAGE:-1}"

hybrid_rank_args=()
if [[ -n "${DSV41_MOE_HYBRID_RANKS:-1,2}" ]]; then
  hybrid_rank_args=(--moe-hybrid-ranks "${DSV41_MOE_HYBRID_RANKS:-1,2}")
fi

extra_args=()
if [[ "${DSV41_MOE_PREFILL_HIT_D2D:-1}" == "1" ]]; then
  extra_args+=(--moe-prefill-hit-d2d)
fi

# Deliberately omit --moe-collect-stats: disabling that hot-path telemetry is
# part of the qualified production profile. Cache reporting remains enabled.
exec "$FREETOKEN_PYTHON" -m freetoken.cli serve \
  --model "$MODEL_PATH" \
  --served-model-name "${DSV41_SERVED_MODEL_NAME:-DeepSeek (Experimental)}" \
  --host "${DSV41_HOST:-127.0.0.1}" \
  --port "${DSV41_PORT:-8080}" \
  --gpu "${DSV41_TEXT_GPUS:-0,1,2,3}" \
  --tp-size 4 \
  --disable-pynccl \
  --rank-local-cuda-visibility \
  --rank-local-cuda-peer-visibility \
  --dsv41-backbone-rank 0 \
  --dsv41-expert-shards "$decode_shards" \
  --dsv41-prefill-expert-shards "$prefill_shards" \
  --dsv41-expert-storage-ranges "$storage_ranges" \
  --dsv41-engram-ranks "${DSV41_ENGRAM_RANKS:-0,1}" \
  --vision-device "${DSV41_VISION_DEVICE:-3}" \
  --max-running-requests "${DSV41_MAX_RUNNING_REQUESTS:-2}" \
  --max-seq-len-override "${DSV41_CONTEXT:-1048576}" \
  --max-prefill-length "${DSV41_MAX_PREFILL_LENGTH:-8192}" \
  --num-pages "${DSV41_NUM_PAGES:-8192}" \
  --swa-full-tokens-ratio "${DSV41_SWA_FULL_TOKENS_RATIO:-0.140625}" \
  --memory-ratio "${DSV41_MEMORY_RATIO:-0.90}" \
  --cache-type "${DSV41_CACHE_TYPE:-radix}" \
  --moe-backend "${DSV41_MOE_BACKEND:-hybrid}" \
  --moe-cpu-threads "${DSV41_MOE_CPU_THREADS:-24}" \
  --moe-hybrid-max-fetch "${DSV41_MOE_HYBRID_MAX_FETCH:-1}" \
  --moe-hybrid-max-bs "${DSV41_MOE_HYBRID_MAX_BS:-2}" \
  "${hybrid_rank_args[@]}" \
  --moe-cache-sizes "$cache_sizes" \
  "${extra_args[@]}" \
  --moe-sparse-prefill-max-tokens "${DSV41_SPARSE_PREFILL_MAX_TOKENS:-256}" \
  --expert-load serial \
  --attention-backend dsv4_sparse \
  --cuda-graph-max-bs 2 \
  --sampling-defaults none \
  --default-temperature "${DSV41_TEMPERATURE:-1.0}" \
  --default-top-p "${DSV41_TOP_P:-0.95}" \
  --reasoning-parser deepseekv32 \
  --default-reasoning-effort "${DSV41_REASONING_EFFORT:-25}" \
  --decode-log-interval "${DSV41_DECODE_LOG_INTERVAL:-8}" \
  --enable-cache-report
