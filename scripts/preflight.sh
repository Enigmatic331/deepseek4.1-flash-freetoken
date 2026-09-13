#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${DSV41_CONFIG:-$REPO_DIR/.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config: $CONFIG_FILE (copy .env.example and edit it)" >&2
  exit 1
fi

set -a
source "$REPO_DIR/freetoken.lock"
source "$CONFIG_FILE"
set +a

fail=0
check_file() {
  if [[ ! -e "$1" ]]; then
    echo "MISSING: $1" >&2
    fail=1
  fi
}

check_file "$FREETOKEN_PYTHON"
check_file "$FREETOKEN_CHECKOUT/python/freetoken"
check_file "$MODEL_PATH/config.json"
check_file "$MODEL_PATH/model.safetensors.index.json"
check_file "$MODEL_PATH/tokenizer.json"

actual_revision="$(git -C "$FREETOKEN_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
if [[ "$actual_revision" != "$FREETOKEN_REVISION" ]]; then
  echo "REVISION: expected $FREETOKEN_REVISION, got ${actual_revision:-unknown}" >&2
  fail=1
fi

shopt -s nullglob
shards=("$MODEL_PATH"/model-*.safetensors)
if (( ${#shards[@]} != MODEL_SHARDS )); then
  echo "SHARDS: expected $MODEL_SHARDS, found ${#shards[@]}" >&2
  fail=1
fi

if [[ -f "$MODEL_PATH/model.safetensors.index.json" ]]; then
  actual_bytes="$("$FREETOKEN_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["total_size"])' "$MODEL_PATH/model.safetensors.index.json")"
  if [[ "$actual_bytes" != "$MODEL_TOTAL_BYTES" ]]; then
    echo "MODEL SIZE: expected $MODEL_TOTAL_BYTES, got $actual_bytes" >&2
    fail=1
  fi
fi

IFS=',' read -r -a gpu_ids <<< "${DSV41_CUDA_VISIBLE_DEVICES:-0,1}"
if (( ${#gpu_ids[@]} != 2 )); then
  echo "GPU SET: expected exactly two CUDA devices" >&2
  fail=1
fi
for gpu in "${gpu_ids[@]}"; do
  if ! nvidia-smi -i "$gpu" --query-gpu=name,memory.total --format=csv,noheader; then
    echo "GPU: unavailable device $gpu" >&2
    fail=1
  fi
done

mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
if (( mem_total_kib < 629145600 )); then
  echo "RAM: this accepted pinned profile expects at least 600 GiB host RAM" >&2
  fail=1
fi

if [[ "$(ulimit -l)" != "unlimited" ]]; then
  echo "MEMLOCK: current shell is not unlimited; the service must apply LimitMEMLOCK=infinity" >&2
fi

echo "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i "${gpu_ids[0]}" | head -1)"
nvidia-smi topo -m
free -h

if (( fail != 0 )); then
  exit 1
fi
echo "Preflight passed. Stop conflicting GPU services before launching."
