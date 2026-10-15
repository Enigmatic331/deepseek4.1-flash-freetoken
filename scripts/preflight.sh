#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${DSV41_CONFIG:-$repo_dir/.env}"
if [[ ! -f "$config_file" ]]; then
  echo "Missing config: $config_file (copy .env.example and edit it)" >&2
  exit 1
fi

set -a
source "$repo_dir/freetoken.lock"
source "$config_file"
set +a

fail=0
check_path() {
  if [[ ! -e "$1" ]]; then
    echo "MISSING: $1" >&2
    fail=1
  fi
}

check_path "$FREETOKEN_PYTHON"
check_path "$FREETOKEN_CHECKOUT/python/freetoken"
check_path "$MODEL_PATH/config.json"
check_path "$MODEL_PATH/model.safetensors.index.json"
check_path "$MODEL_PATH/tokenizer.json"

actual_revision="$(git -C "$FREETOKEN_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
if [[ "$actual_revision" != "$FREETOKEN_REVISION" ]]; then
  echo "REVISION: expected $FREETOKEN_REVISION, got ${actual_revision:-unknown}" >&2
  fail=1
fi
if [[ -n "$(git -C "$FREETOKEN_CHECKOUT" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
  echo "REVISION: FreeToken checkout has local changes" >&2
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

IFS=',' read -r -a visible_gpu_ids <<< "${DSV41_CUDA_VISIBLE_DEVICES:-0,1,2,3}"
if (( ${#visible_gpu_ids[@]} != 4 )); then
  echo "GPU SET: expected exactly four visible devices" >&2
  fail=1
fi
for gpu in "${visible_gpu_ids[@]}"; do
  if ! nvidia-smi -i "$gpu" --query-gpu=name,memory.total --format=csv,noheader; then
    echo "GPU: unavailable device $gpu" >&2
    fail=1
  fi
done

IFS=',' read -r -a text_gpu_ids <<< "${DSV41_TEXT_GPUS:-0,1,2,3}"
if (( ${#text_gpu_ids[@]} != 4 )); then
  echo "TEXT GPU SET: expected exactly four entries" >&2
  fail=1
fi

mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
if (( mem_total_kib < 943718400 )); then
  echo "RAM: this pinned profile expects at least 900 GiB OS-visible host RAM" >&2
  fail=1
fi

if [[ "$(ulimit -l)" != "unlimited" ]]; then
  echo "MEMLOCK: current shell is not unlimited; systemd must apply LimitMEMLOCK=infinity" >&2
fi

echo "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i "${visible_gpu_ids[0]}" | head -1)"
nvidia-smi topo -m
free -h

if (( fail != 0 )); then
  exit 1
fi
echo "Preflight passed. GPU ordering and pairwise P2P integrity remain separate hardware gates."
