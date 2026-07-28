#!/usr/bin/env bash
# scripts/setup-maas-phase2.sh
#
# ADR-0003 Phase 2: Kuadrant/Authorino, maas-default-gateway, TLS bootstrap.
# Requires Phase 1 (scripts/setup-maas-phase1.sh) confirmed clean first.
#
# Same discipline as Phase 1 after DEPLOYMENT-LOG-2026-07-28: any operator
# install plan is looked up and approved BY NAME, never blanket-approved.
#
# Package name, catalog source, and GatewayClass controller all confirmed
# live 2026-07-28: rhcl-operator (Red Hat Operators, channel "stable"),
# not kuadrant-operator (Community Operators, unsupported). See
# manifests/maas/kuadrant-subscription.yaml and manifests/maas/gateway.yaml.

set -euo pipefail

echo "=== ADR-0003 Phase 2: Kuadrant, Gateway, TLS ==="
echo

echo "--- Applying dedicated GatewayClass and Gateway ---"
oc apply -f manifests/maas/gateway.yaml
echo

echo "--- Applying Kuadrant/RHCL subscription ---"
oc apply -f manifests/maas/kuadrant-subscription.yaml
echo

echo "--- Locating the RHCL install plan by name (never blanket-approve) ---"
RHCL_PLAN=""
for i in $(seq 1 6); do
    RHCL_PLAN=$(oc get installplan -n openshift-operators -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    csvs = item['spec'].get('clusterServiceVersionNames', [])
    if any('rhcl' in c.lower() for c in csvs) and not item['spec'].get('approved'):
        print(item['metadata']['name'])
        break
")
    if [ -n "${RHCL_PLAN}" ]; then
        break
    fi
    sleep 5
done

if [ -z "${RHCL_PLAN}" ]; then
    echo "FAIL: No unapproved RHCL install plan found after 30s. Check manually:"
    echo "  oc get installplan -n openshift-operators"
    exit 1
fi
echo "Found: ${RHCL_PLAN}"
echo "Approving this plan only:"
oc patch installplan "${RHCL_PLAN}" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
echo

echo "--- Waiting for RHCL operator to install (up to 3 minutes) ---"
for i in $(seq 1 18); do
    PHASE=$(oc get csv -n openshift-operators -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    if item['metadata']['name'].startswith('rhcl-operator'):
        print(item['status']['phase'])
        break
" 2>/dev/null || echo "")
    if [ "${PHASE}" == "Succeeded" ]; then
        echo "PASS: RHCL operator installed."
        break
    fi
    sleep 10
done

if [ "${PHASE}" != "Succeeded" ]; then
    echo "FAIL: RHCL operator did not reach Succeeded within 3 minutes. Current phase: ${PHASE:-unknown}"
    echo "Check manually: oc get csv -n openshift-operators | grep rhcl"
    exit 1
fi
echo

echo "--- Confirming no other operators were touched ---"
echo "Service Mesh CSV (should be untouched):"
oc get csv -n openshift-operators -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    if 'servicemesh' in item['metadata']['name'].lower():
        print(f\"  {item['metadata']['name']} - {item['status']['phase']}\")
"
echo

echo "=== Automated steps complete. Manual steps remaining (per Red Hat docs) ==="
cat <<'EOF'
1. Create the Kuadrant custom resource in kuadrant-system:
   (see docs.redhat.com "Platform and Operator prerequisites for MaaS")

2. Confirm it reaches Ready status:
   oc get kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

3. TLS bootstrap for Authorino:
   oc annotate service authorino-authorino-authorization -n kuadrant-system \
     service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite

   oc patch authorino authorino -n kuadrant-system --type=merge --patch '
   {"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'

   oc -n kuadrant-system set env deployment/authorino \
     SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
     REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

4. Annotate the Gateway to trigger automatic TLS configuration:
   oc annotate gateway maas-default-gateway -n openshift-ingress \
     security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite

5. Verify each step per Red Hat's documented verification commands
   (docs.redhat.com, "Configure TLS for Models-as-a-Service")
EOF
