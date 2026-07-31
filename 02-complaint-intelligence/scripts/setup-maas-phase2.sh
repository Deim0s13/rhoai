#!/usr/bin/env bash
# scripts/setup-maas-phase2.sh
#
# ADR-0003 Phase 2: Kuadrant/RHCL in an ISOLATED namespace, gateway, TLS.
# Requires Phase 1 (scripts/setup-maas-phase1.sh) confirmed clean first.
#
# Structure settled 2026-07-29 after three failed install attempts in
# openshift-operators (see DEPLOYMENT-LOG-2026-07-29):
#
#   1. The Kuadrant stack installs into kuadrant-system with its own
#      OperatorGroup. This is the PREVENTION control: OLM resolution is
#      per-namespace, and plans generated in openshift-operators sweep in
#      the permanently-pending servicemesh v3.4.0 upgrade (the mechanism
#      behind both 2026-07-28 incidents). Plans generated in
#      kuadrant-system cannot.
#   2. The servicemesh subscription in openshift-operators is managed by
#      the cluster ingress operator (Gateway API implementation). It is
#      never touched here: not pinned, not patched, not deleted. Channel
#      pinning was attempted and is reverted by the platform within
#      seconds; it is not a viable control.
#   3. Install plans are approved BY NAME after CONTENT inspection. Any
#      plan bundling servicemesh fails hard. This is the DETECTION layer;
#      in the isolated namespace it should never fire, and firing means
#      something structural has changed.
#
# Package details confirmed live 2026-07-28/29: rhcl-operator
# (Red Hat Operators, channel stable, AllNamespaces-only install mode).

set -euo pipefail

echo "=== ADR-0003 Phase 2: Kuadrant (isolated namespace), Gateway, TLS ==="
echo

echo "--- Verifying platform-managed servicemesh subscription (read-only) ---"
if ! oc get subscription servicemeshoperator3 -n openshift-operators >/dev/null 2>&1; then
  echo "FAIL: servicemesh subscription not found. The platform install may"
  echo "not have settled. Confirm base RHOAI/ingress state before Phase 2."
  exit 1
fi
SM_BEFORE=$(oc get subscription servicemeshoperator3 -n openshift-operators \
  -o jsonpath='{.status.installedCSV}')
echo "Service Mesh installed CSV (platform-managed, not touched): ${SM_BEFORE}"
case "${SM_BEFORE}" in
  servicemeshoperator3.v3.1.*) ;;
  *)
    echo "FAIL: Service Mesh is at ${SM_BEFORE:-<empty>}, outside v3.1.x,"
    echo "BEFORE this script has done anything. Do not proceed."
    echo "See RUNBOOK-servicemesh-recovery.md."
    exit 1
    ;;
esac
echo

echo "--- Guard: gateway TLS certificate ---"
# The listener terminates TLS. Without a resolvable certificateRef the
# gateway accepts TCP then drops the TLS handshake, which surfaces as
# curl exit code 000 rather than an HTTP status (confirmed 2026-07-31).
# cert-manager-ingress-cert is provisioned by the RHDP catalog item, not
# by RHOAI, so a different sandbox may name it differently.
if ! oc get secret cert-manager-ingress-cert -n openshift-ingress >/dev/null 2>&1; then
  echo "FAIL: secret cert-manager-ingress-cert not found in openshift-ingress."
  echo "The gateway listener terminates TLS with this certificate. Check"
  echo "what this catalog item provides:"
  echo "  oc get secret -n openshift-ingress | grep tls"
  echo "  oc get clusterissuer"
  echo "Then update certificateRefs in manifests/maas/gateway.yaml."
  exit 1
fi
echo "OK: gateway TLS certificate present."
echo

echo "--- Applying dedicated GatewayClass and Gateway ---"
oc apply -f manifests/maas/gateway.yaml
echo

echo "--- Creating kuadrant-system namespace and OperatorGroup ---"
oc apply -f manifests/maas/kuadrant-namespace.yaml
echo

echo "--- Applying RHCL subscription (kuadrant-system) ---"
oc apply -f manifests/maas/kuadrant-subscription.yaml
echo

echo "--- Locating the RHCL install plan in kuadrant-system and inspecting contents ---"
RHCL_PLAN=""
RHCL_APPROVED=""
SM_IN_PLAN=""
for i in $(seq 1 12); do
  RESULT=$(oc get installplan -n kuadrant-system -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    csvs = item['spec'].get('clusterServiceVersionNames', [])
    if any('rhcl' in c.lower() for c in csvs):
        sm = [c for c in csvs if 'servicemesh' in c.lower()]
        print(item['metadata']['name'],
              item['spec'].get('approved', False),
              ','.join(sm) if sm else 'none')
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
  echo "FAIL: No RHCL install plan appeared in kuadrant-system after 60s."
  echo "Check: oc get installplan -n kuadrant-system"
  echo "and:   oc get subscription -n kuadrant-system"
  exit 1
fi

if [ "${SM_IN_PLAN}" != "none" ]; then
  echo "FAIL: RHCL plan ${RHCL_PLAN} bundles servicemesh (${SM_IN_PLAN})"
  echo "DESPITE namespace isolation. This should be impossible under the"
  echo "validated 2026-07-29 model; something structural has changed."
  echo "Do not approve. Investigate before re-running."
  exit 1
fi

echo "Found: ${RHCL_PLAN} (approved: ${RHCL_APPROVED}, servicemesh content: none)"
if [ "${RHCL_APPROVED}" == "True" ]; then
  echo "Plan already approved; proceeding to wait."
else
  echo "Approving this plan only:"
  oc patch installplan "${RHCL_PLAN}" -n kuadrant-system --type merge -p '{"spec":{"approved":true}}'
fi
echo

echo "--- Waiting for the Kuadrant stack to install (up to 5 minutes) ---"
EXPECTED="rhcl-operator limitador-operator dns-operator"
ALL_UP=""
for i in $(seq 1 30); do
  ALL_UP=$(oc get csv -n kuadrant-system -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
# authorino-operator excluded: it installs in openshift-operators (platform,
# for kserve) and OLM resolves rhcl's dependency against it, so it never
# produces a CSV in kuadrant-system. Phase 3's guard verifies it cluster-wide.
want = ['rhcl-operator', 'limitador-operator', 'dns-operator']
phases = {}
for item in data['items']:
    if item['metadata'].get('labels', {}).get('olm.copiedFrom'):
        continue
    for w in want:
        if item['metadata']['name'].startswith(w):
            phases[w] = item['status'].get('phase', '')
print('yes' if all(phases.get(w) == 'Succeeded' for w in want) else 'no')
")
  if [ "${ALL_UP}" == "yes" ]; then
      echo "PASS: rhcl, limitador, dns-operator all Succeeded in kuadrant-system."
      echo "      (authorino-operator is the platform install in openshift-operators.)"
      break
    fi
  sleep 10
done

if [ "${ALL_UP}" != "yes" ]; then
  echo "FAIL: Kuadrant stack did not fully reach Succeeded within 5 minutes."
  echo "Check: oc get csv -n kuadrant-system"
  exit 1
fi
echo

echo "--- Guard: verify Service Mesh was untouched ---"
SM_AFTER=$(oc get subscription servicemeshoperator3 -n openshift-operators \
  -o jsonpath='{.status.installedCSV}')
SM_DEPLOY=$(oc get deployment -n openshift-operators \
  -o name 2>/dev/null | grep -ci servicemesh || true)
if [ "${SM_AFTER}" == "${SM_BEFORE}" ] && [ "${SM_DEPLOY}" -ge 1 ]; then
  echo "OK: Service Mesh unchanged at ${SM_AFTER}, operator deployment present."
else
  echo "FAIL: Service Mesh state changed during Kuadrant install"
  echo "(before: ${SM_BEFORE}, after: ${SM_AFTER:-<empty>}, deployment count: ${SM_DEPLOY})."
  echo "Do NOT proceed with manual steps. See RUNBOOK-servicemesh-recovery.md."
  exit 1
fi
echo

echo "--- Guard: no duplicate Kuadrant controllers in openshift-operators ---"
# authorino-operator is deliberately excluded: the platform installs it in
# openshift-operators for kserve. Because it is AllNamespaces, OLM resolves
# rhcl's authorino dependency against that existing install rather than
# creating a second one. A resolver-generated authorino subscription may
# exist in kuadrant-system with no CSV; that is correct, not a fault.
# (Confirmed on a virgin cluster 2026-07-29.)
DUPES=$(oc get csv -n openshift-operators -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    n = item['metadata']['name'].lower()
    if any(x in n for x in ('rhcl', 'limitador', 'dns-operator')):
        if not item['metadata'].get('labels', {}).get('olm.copiedFrom'):
            print(item['metadata']['name'])
")
if [ -n "${DUPES}" ]; then
  echo "FAIL: real (non-copied) Kuadrant-family installs exist in"
  echo "openshift-operators alongside kuadrant-system:"
  echo "${DUPES}"
  echo "Duplicate AllNamespaces controllers will conflict. Remove the"
  echo "openshift-operators copies (subscriptions first, then CSVs)."
  exit 1
fi
echo "OK: no duplicate controllers."
echo

echo "=== Automated steps complete. Manual steps remaining (per Red Hat docs) ==="
cat <<'EOF'
Run once live on 2026-07-28; not yet scripted.

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
