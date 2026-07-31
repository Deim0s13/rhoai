#!/usr/bin/env bash
# scripts/setup-maas-phase4.sh
#
# ADR-0003 Phase 4: publish a model through MaaS and attach a subscription.
#   1. Deploy Qwen3-0.6B as an LLMInferenceService opting in to the gateway
#   2. MaaSModelRef publishes it to MaaS
#   3. MaaSSubscription grants a group a token budget against it
#
# Requires Phase 3 complete (Tenant Ready, maas-api running).
#
# GPU note: this model co-tenants on the single L4 with Granite (UC02).
# It requests no nvidia.com/gpu deliberately, and constrains vLLM to ~9%
# of the card. See manifests/maas/model-qwen.yaml.

set -euo pipefail

echo "=== ADR-0003 Phase 4: publish a model and subscribe ==="
echo

echo "--- Guard: Phase 3 prerequisites ---"
READY=$(oc get tenant -A -o json 2>/dev/null | python3 -c "
import json, sys
try: data = json.load(sys.stdin)
except Exception: sys.exit()
for i in data.get('items', []):
    for c in i.get('status', {}).get('conditions', []):
        if c.get('type') == 'Ready':
            print(c.get('status', ''))
" || echo "")
if [ "${READY}" != "True" ]; then
  echo "FAIL: MaaS Tenant not Ready. Run setup-maas-phase3.sh first."
  exit 1
fi
if ! oc get deployment maas-api -n redhat-ods-applications >/dev/null 2>&1; then
  echo "FAIL: maas-api deployment not found. Run setup-maas-phase3.sh first."
  exit 1
fi
echo "OK: Tenant Ready, maas-api present."
echo

echo "--- Publishing the model (namespace, LLMInferenceService, MaaSModelRef) ---"
oc apply -f manifests/maas/model-qwen.yaml
echo

echo "--- Waiting for the model to serve (up to 10 minutes) ---"
# First run pulls weights from Hugging Face, so this is slow. vLLM also
# fails fast and CrashLoopBackOffs if the GPU memory fraction is wrong,
# so a stuck rollout here is usually a memory problem, not a slow pull.
if ! oc rollout status deployment -n maas-models \
     -l serving.kserve.io/inferenceservice=qwen3-06b --timeout=600s; then
  echo "FAIL: model workload did not become available."
  echo "Check:  oc get pods -n maas-models"
  echo "        oc logs -n maas-models -l serving.kserve.io/inferenceservice=qwen3-06b --tail=50"
  echo "If the log shows 'Free memory on device cuda:0 ... less than desired"
  echo "GPU memory utilization', another workload holds the card. Lower"
  echo "--gpu-memory-utilization in manifests/maas/model-qwen.yaml."
  exit 1
fi
echo

echo "--- Gate: LLMInferenceService and MaaSModelRef Ready ---"
for i in $(seq 1 18); do
  LLM_READY=$(oc get llmisvc qwen3-06b -n maas-models \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  REF_PHASE=$(oc get maasmodelref qwen3-06b -n maas-models \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${LLM_READY}" == "True" ] && [ "${REF_PHASE}" == "Ready" ]; then
    echo "PASS: model published (LLMISVC Ready, MaaSModelRef Ready)."
    break
  fi
  sleep 10
done
if [ "${LLM_READY}" != "True" ] || [ "${REF_PHASE}" != "Ready" ]; then
  echo "FAIL: LLMISVC=${LLM_READY:-unknown} MaaSModelRef=${REF_PHASE:-unknown}."
  echo "If the LLMISVC reports HTTPRoutesNotReady, the route is being"
  echo "rejected by the gateway listener. Check:"
  echo "  oc get httproute -n maas-models -o jsonpath='{.items[*].status}' | python3 -m json.tool"
  echo "A NotAllowedByListeners message means the namespace is missing the"
  echo "maas.opendatahub.io/publish=true label."
  exit 1
fi
echo

echo "--- Granting access (MaaSAuthPolicy) ---"
# Publishing a model does not grant access to it. Without this policy the
# model is Ready and subscribed but invisible to callers: /v1/models
# returns {"data":[]} with HTTP 200 and no error.
oc apply -f manifests/maas/authpolicy-demo.yaml
sleep 10
AUTH_PHASE=$(oc get maasauthpolicy demo-access -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${AUTH_PHASE}" != "Active" ]; then
  echo "FAIL: MaaSAuthPolicy phase is '${AUTH_PHASE:-unknown}', expected Active."
  exit 1
fi
if ! oc get authpolicy maas-auth-qwen3-06b -n maas-models >/dev/null 2>&1; then
  echo "FAIL: MaaSAuthPolicy did not reconcile into a Kuadrant AuthPolicy"
  echo "(expected maas-auth-qwen3-06b in maas-models)."
  exit 1
fi
echo "OK: access granted, reconciled into maas-auth-qwen3-06b."
echo

echo "--- Applying the subscription ---"
oc apply -f manifests/maas/subscription-demo.yaml
sleep 10
SUB_PHASE=$(oc get maassubscription demo-subscription -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${SUB_PHASE}" != "Active" ]; then
  echo "FAIL: subscription phase is '${SUB_PHASE:-unknown}', expected Active."
  echo "Check: oc get maassubscription demo-subscription -n models-as-a-service -o yaml"
  exit 1
fi
echo "OK: subscription Active."
echo

echo "--- Gate: subscription reconciled into an enforced policy ---"
if ! oc get tokenratelimitpolicy maas-trlp-qwen3-06b -n maas-models >/dev/null 2>&1; then
  echo "FAIL: no TokenRateLimitPolicy maas-trlp-qwen3-06b in maas-models."
  echo "The subscription did not reconcile into gateway enforcement."
  exit 1
fi
echo "OK: maas-trlp-qwen3-06b present (declarative subscription -> enforced limit)."
echo

echo "=== Phase 4 complete ==="
GW=https://$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')
cat <<EOF

Gateway: ${GW}

Verify deny-by-default (expect 403, no credentials):

  curl -sk -o /dev/null -w "%{http_code}\\n" \\
    -X POST "${GW}/maas-models/qwen3-06b/v1/chat/completions" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'

Model discovery:

  curl -sk "${GW}/v1/models" -H "Authorization: Bearer \$(oc whoami -t)"

-k is required: the wildcard certificate does not match the load balancer
address, and no DNS record exists for this gateway.

echo "=== Phase 4 complete ==="
echo
echo "Verify end to end:  ./scripts/maas-demo-verify.sh"
echo "Demo runbook:       docs/demos/DEMO-maas-governance.md"
