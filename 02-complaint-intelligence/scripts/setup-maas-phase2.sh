#!/usr/bin/env bash
# scripts/setup-maas-phase2.sh
#
# ADR-0003 Phase 2: Kuadrant/Authorino, maas-default-gateway, TLS bootstrap.
# Requires Phase 1 (scripts/setup-maas-phase1.sh) confirmed clean first.
#
# Discipline after DEPLOYMENT-LOG-2026-07-28 (both incidents):
#   1. Install plans are approved BY NAME, never blanket-approved.
#   2. A plan's CONTENTS are inspected before approval. Name-targeting is
#      not sufficient: Kuadrant dependency resolution can bundle a
#      servicemesh upgrade inside the RHCL plan (install-kkl59), and
#      approving that bundle by name still upgrades servicemesh into the
#      version RHOAI 3.4.2 deadlocks against.
#   3. Plans may arrive already approved: approval is shared across the
#      namespace resolution set, and dns/limitador/authorino carry
#      Automatic. An already-approved plan is not an error; an approved
#      plan containing servicemesh v3.4+ is.
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

# --- Guard: pin Service Mesh BEFORE Kuadrant dependency resolution acts ---
# rhcl-operator depends on servicemeshoperator3. If a versioned channel
# holding 3.1.x exists, pin to it so resolution bundles 3.1.x at worst;
# otherwise set Manual and rely on plan-content inspection below.
if ! oc get subscription servicemeshoperator3 -n openshift-operators >/dev/null 2>&1; then
  echo "FAIL: servicemesh subscription not found. The platform install may"
  echo "not have settled yet. Confirm base RHOAI state before Phase 2:"
  echo "  oc get subscription -n openshift-operators"
  exit 1
fi
SM_CHANNELS=$(oc get packagemanifest servicemeshoperator3 \
  -n openshift-marketplace -o jsonpath='{.status.channels[*].name}')
echo "Service Mesh channels available: ${SM_CHANNELS}"
if echo "${SM_CHANNELS}" | grep -qw "stable-3.1"; then
  oc patch subscription servicemeshoperator3 -n openshift-operators \
    --type merge -p '{"spec":{"channel":"stable-3.1","installPlanApproval":"Manual"}}'
  echo "Pinned servicemesh subscription to channel stable-3.1"
else
  oc patch subscription servicemeshoperator3 -n openshift-operators \
    --type merge -p '{"spec":{"installPlanApproval":"Manual"}}'
  echo "WARN: no stable-3.1 channel; Manual set, plan-content inspection is the control"
fi
echo

echo "--- Applying Kuadrant/RHCL subscription ---"
oc apply -f manifests/maas/kuadrant-subscription.yaml
echo

echo "--- Locating the RHCL install plan and inspecting its contents ---"
RHCL_PLAN=""
RHCL_APPROVED=""
SM_IN_PLAN=""
for i in $(seq 1 6); do
  RESULT=$(oc get installplan -n openshift-operators -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    csvs = item['spec'].get('clusterServiceVersionNames', [])
    if any('rhcl' in c.lower() for c in csvs):
        sm = [c for c in csvs if 'servicemesh' in c.lower()]
        bad = [c for c in sm if not c.startswith('servicemeshoperator3.v3.1.')]
        print(item['metadata']['name'],
              item['spec'].get('approved', False),
              ','.join(bad) if bad else 'none')
        break
")
  if [ -n "${RESULT}" ]; then
    RHCL_PLAN=$(echo "${RESULT}" | awk '{print $1}')
    RHCL_APPROVED=$(echo "${RESULT}" | awk '{print $2}')
    SM_IN_PLAN=$(echo "${RESULT}" | awk '{print $3}')
    break
  fi
  sleep 5
done

if [ -z "${RHCL_PLAN}" ]; then
  echo "FAIL: No RHCL install plan found after 30s. Check manually:"
  echo "  oc get installplan -n openshift-operators"
  exit 1
fi

if [ "${SM_IN_PLAN}" != "none" ]; then
  echo "FAIL: RHCL plan ${RHCL_PLAN} bundles a Service Mesh version outside"
  echo "v3.1.x: ${SM_IN_PLAN}. Approving it would upgrade servicemesh into"
  echo "the version RHOAI 3.4.2 deadlocks against (Path A)."
  if [ "${RHCL_APPROVED}" == "True" ]; then
    echo "WORSE: the plan is ALREADY approved (shared approval in this"
    echo "namespace). The upgrade may be executing now. Stop and check"
    echo "servicemesh CSV state immediately."
  fi
  echo "See RUNBOOK-servicemesh-recovery.md. Do not re-run until resolved."
  exit 1
fi

echo "Found: ${RHCL_PLAN} (approved: ${RHCL_APPROVED}, servicemesh content: within v3.1.x or none)"
if [ "${RHCL_APPROVED}" == "True" ]; then
  echo "Plan already approved via shared namespace approval; not an error, proceeding to wait."
else
  echo "Approving this plan only:"
  oc patch installplan "${RHCL_PLAN}" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
fi
echo

echo "--- Waiting for RHCL operator to install (up to 3 minutes) ---"
PHASE=""
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

# --- Guard: verify Kuadrant install did not move Service Mesh ---
# Runs BEFORE the manual-steps output: if this fails, nothing below
# should be attempted.
SM_CSV=$(oc get subscription servicemeshoperator3 -n openshift-operators \
  -o jsonpath='{.status.installedCSV}')
SM_DEPLOY=$(oc get deployment -n openshift-operators \
  -o name 2>/dev/null | grep -ci servicemesh || true)
case "${SM_CSV}" in
  servicemeshoperator3.v3.1.*)
    if [ "${SM_DEPLOY}" -ge 1 ]; then
      echo "OK: Service Mesh at ${SM_CSV}, operator deployment present"
    else
      echo "FAIL: Service Mesh CSV ${SM_CSV} but NO operator deployment."
      echo "See RUNBOOK-servicemesh-recovery.md (Path B)."
      exit 1
    fi
    ;;
  *)
    echo "FAIL: Service Mesh moved to ${SM_CSV:-<empty>} during Kuadrant install."
    echo "Do NOT proceed with manual steps. See RUNBOOK-servicemesh-recovery.md (Path A)."
    exit 1
    ;;
esac
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
