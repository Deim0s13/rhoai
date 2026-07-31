#!/usr/bin/env bash
# Proves the full MaaS governance chain end to end. Run this BEFORE a demo
# to confirm the environment behaves, not during one: the audience-facing
# version is docs/demos/DEMO-maas-governance.md.
set -uo pipefail

GW=https://$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')
TOKEN=$(oc whoami -t)
MODEL_PATH="${GW}/maas-models/qwen3-06b/v1/chat/completions"
PAYLOAD='{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Write a paragraph about banking regulation."}],"max_tokens":200}'
FAILED=0

check() { # name expected actual
  if [ "$2" == "$3" ]; then echo "PASS: $1 ($3)"; else echo "FAIL: $1 (expected $2, got $3)"; FAILED=1; fi
}

echo "Gateway: ${GW}"
echo

# 1. Deny by default
CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${MODEL_PATH}" \
  -H "Content-Type: application/json" -d "${PAYLOAD}")
check "unauthenticated is denied" "403" "${CODE}"

# 2. Discovery with an OpenShift token
MODELS=$(curl -sk "${GW}/v1/models" -H "Authorization: Bearer ${TOKEN}")
COUNT=$(echo "${MODELS}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)
check "model discovery lists a model" "1" "${COUNT}"

# 3. k8s tokens are scoped to discovery only
CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${MODEL_PATH}" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${PAYLOAD}")
check "OpenShift token rejected on inference" "401" "${CODE}"

# 4. Issue a key
KEYJSON=$(curl -sk -X POST "${GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"verify-run"}')
KEY=$(echo "${KEYJSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])" 2>/dev/null || echo "")
KEYID=$(echo "${KEYJSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
[ -n "${KEY}" ] && echo "PASS: API key issued" || { echo "FAIL: no API key issued"; exit 1; }

# 5. Authenticated inference
BODY=$(curl -sk -X POST "${MODEL_PATH}" -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hello"}],"max_tokens":20}')
TOKENS=$(echo "${BODY}" | python3 -c "import json,sys; print(json.load(sys.stdin)['usage']['total_tokens'])" 2>/dev/null || echo "")
[ -n "${TOKENS}" ] && echo "PASS: inference succeeded (${TOKENS} tokens)" || { echo "FAIL: inference failed"; FAILED=1; }

# 6. Budget exhaustion
echo "Consuming budget..."
LAST=""
for i in $(seq 1 6); do
  LAST=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${MODEL_PATH}" \
    -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" -d "${PAYLOAD}")
  echo "    call ${i}: ${LAST}"
done
check "budget exhaustion returns 429" "429" "${LAST}"

# 7. Revocation. Bounded by the apiKeyValidation cache TTL (60s).
curl -sk -o /dev/null -X DELETE "${GW}/maas-api/v1/api-keys/${KEYID}" \
  -H "Authorization: Bearer ${TOKEN}"
echo "Key revoked; waiting for the 60s validation cache to expire..."
sleep 65
CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${MODEL_PATH}" \
  -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"max_tokens":10}')
check "revoked key is rejected" "403" "${CODE}"

echo
[ "${FAILED}" -eq 0 ] && echo "=== All checks passed ===" || { echo "=== Some checks FAILED ==="; exit 1; }
