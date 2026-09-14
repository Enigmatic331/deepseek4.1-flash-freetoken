#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${DSV41_BASE_URL:-http://172.17.0.1:8080}"
MODEL="${DSV41_MODEL:-DeepSeek (Experimental)}"
CONTEXT="${DSV41_CONTEXT:-262144}"

curl --fail --silent --show-error "$BASE_URL/health"
echo

models="$(curl --fail --silent --show-error "$BASE_URL/v1/models")"
printf '%s\n' "$models" | python3 -c '
import json, sys
payload, expected_model, expected_context = json.load(sys.stdin), sys.argv[1], int(sys.argv[2])
cards = payload.get("data", [])
assert any(card.get("id") == expected_model and card.get("context_length") == expected_context for card in cards)
' "$MODEL" "$CONTEXT"

payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: FREETOKEN_OK"}],"thinking":{"type":"disabled"},"temperature":0,"max_tokens":64}' "$MODEL")"
response="$(curl --fail --silent --show-error "$BASE_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data "$payload")"
printf '%s\n' "$response"
printf '%s\n' "$response" | python3 -c '
import json, sys
choice = json.load(sys.stdin)["choices"][0]
assert choice["finish_reason"] == "stop"
assert choice["message"]["content"].strip() == "FREETOKEN_OK"
'
echo "Smoke test passed."
