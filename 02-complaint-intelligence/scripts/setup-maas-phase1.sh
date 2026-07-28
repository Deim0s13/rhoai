#!/usr/bin/env bash
# scripts/setup-maas-phase1.sh
#
# ADR-0003 Phase 1: LWS operator + User Workload Monitoring.
# NOT part of the core rebuild (ansible/site.yml); run manually, once,
# when starting MaaS evaluation on a fresh environment.
#
# Built 2026-07-28 after a blanket install-plan approval accidentally
# upgraded Service Mesh three minor versions and broke Gateway API
# reconciliation cluster-wide (see DEPLOYMENT-LOG-2026-07-28). This
# script never approves an install plan it hasn't first confirmed, by
# name, belongs to LWS specifically. Every other pending plan is listed,
# not touched, so nothing unexpected is silently approved alongside it.

set -euo pipefail

NAMESPACE="openshift-operators"
LWS_CSV_PREFIX="leader-worker-set"

echo "=== ADR-0003 Phase 1: LWS + User Workload Monitoring ==="
echo

echo "--- Applying manifests ---"
oc apply -f manifests/maas/lws-subscription.yaml
oc apply -f manifests/maas/user-workload-monitoring.yaml
echo

echo "--- Pending install plans in ${NAMESPACE} (informational, nothing touched yet) ---"
oc get installplan -n "${NAMESPACE}" -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    approved = item['spec'].get('approved')
    if not approved:
        csvs = item['spec'].get('clusterServiceVersionNames', [])
        print(f\"  {item['metadata']['name']}: {csvs} (approved={approved})\")
"
echo "(Review the list above. This script only acts on the LWS plan below.)"
echo

echo "--- Locating the LWS install plan specifically ---"
LWS_PLAN=$(oc get installplan -n "${NAMESPACE}" -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    csvs = item['spec'].get('clusterServiceVersionNames', [])
    if any('${LWS_CSV_PREFIX}' in c for c in csvs) and not item['spec'].get('approved'):
        print(item['metadata']['name'])
        break
")

if [ -z "${LWS_PLAN}" ]; then
    echo "No unapproved install plan found for ${LWS_CSV_PREFIX}."
    echo "Either it's already approved, or the subscription hasn't produced a plan yet (wait a few seconds and re-run)."
else
    echo "Found: ${LWS_PLAN}"
    echo "Approving this plan only:"
    oc patch installplan "${LWS_PLAN}" -n "${NAMESPACE}" --type merge -p '{"spec":{"approved":true}}'
fi
echo

echo "--- Waiting for LWS subscription to settle (up to 2 minutes) ---"
for i in $(seq 1 12); do
    STATE=$(oc get subscription leader-worker-set -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    CSV=$(oc get subscription leader-worker-set -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    if [ "${STATE}" == "AtLatestKnown" ] && [ -n "${CSV}" ]; then
        echo "PASS: LWS installed (${CSV})"
        break
    fi
    sleep 10
done

if [ "${STATE}" != "AtLatestKnown" ]; then
    echo "FAIL: LWS did not reach AtLatestKnown within 2 minutes. Current state: ${STATE:-unknown}"
    echo "Check manually: oc get subscription leader-worker-set -n ${NAMESPACE}"
    exit 1
fi
echo

echo "--- Verifying User Workload Monitoring ---"
UWM=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep enableUserWorkload || echo "")
if [ -n "${UWM}" ]; then
    echo "PASS: ${UWM}"
else
    echo "FAIL: enableUserWorkload not found in cluster-monitoring-config"
    exit 1
fi
echo

echo "--- Confirming no other operators were touched ---"
echo "Service Mesh CSV (should be untouched, whatever version ships out-of-box):"
oc get csv -n "${NAMESPACE}" -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    if 'servicemesh' in item['metadata']['name'].lower():
        print(f\"  {item['metadata']['name']} - {item['status']['phase']}\")
"
echo

echo "=== Phase 1 complete ==="
