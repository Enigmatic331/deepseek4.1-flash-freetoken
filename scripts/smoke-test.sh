#!/usr/bin/env bash
set -euo pipefail

base_url="${DSV41_BASE_URL:-http://127.0.0.1:8080}"
model="${DSV41_MODEL:-DeepSeek (Experimental)}"
context="${DSV41_CONTEXT:-524288}"

curl --fail --silent --show-error "$base_url/health"
echo

models="$(curl --fail --silent --show-error "$base_url/v1/models")"
printf '%s\n' "$models" | python3 -c '
import json, sys
payload, expected_model, expected_context = json.load(sys.stdin), sys.argv[1], int(sys.argv[2])
cards = payload.get("data", [])
assert any(card.get("id") == expected_model and card.get("context_length") == expected_context for card in cards)
' "$model" "$context"

payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: FREETOKEN_OK"}],"thinking":{"type":"disabled"},"temperature":0,"max_tokens":64}' "$model")"
response="$(curl --fail --silent --show-error "$base_url/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data "$payload")"
printf '%s\n' "$response" | python3 -c '
import json, sys
choice = json.load(sys.stdin)["choices"][0]
assert choice["finish_reason"] == "stop"
assert choice["message"]["content"].strip() == "FREETOKEN_OK"
'
echo "Text smoke test passed. Run the documented image OCR gate before promotion."
