#!/usr/bin/env bash
# scripts/setup-maas-phase3.sh
#
# ADR-0003 Phase 3: MaaS platform enablement.
#   1. MaaS PostgreSQL (dedicated, maas-platform namespace)
#   2. maas-db-config secret in redhat-ods-applications (BEFORE enabling
#      modelsAsService; otherwise maas-api needs a restart afterwards)
#   3. DataScienceCluster: enable modelsAsService under kserve
#   4. Gate on the Tenant CR reaching Ready / AllComponentsReady
#
# Requires Phase 2 complete AND its manual steps done (Kuadrant CR Ready,
# Authorino TLS bootstrapped), plus User Workload Monitoring (Phase 1).
# Without UWM the MaaS deployment reports Degraded.

set -euo pipefail

echo "=== ADR-0003 Phase 3: MaaS platform ==="
echo

echo "--- Guard: Phase 2 prerequisites ---"
# Namespace-agnostic by design: rhcl, limitador and dns-operator install
# into kuadrant-system, while authorino-operator is the platform's own
# install in openshift-operators. What matters is that each is Succeeded
# as a real (non-copied) install somewhere.
for csv in rhcl-operator authorino-operator limitador-operator dns-operator; do
  FOUND=$(oc get csv -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for i in data['items']:
    if i['metadata'].get('labels', {}).get('olm.copiedFrom'): continue
    if i['metadata']['name'].startswith('${csv}'):
        print(i['metadata']['namespace'], i['status'].get('phase','')); break
")
  case "${FOUND}" in
    *Succeeded) echo "OK: ${csv} (${FOUND%% *})" ;;
    *)
      echo "FAIL: ${csv} not Succeeded anywhere (saw: ${FOUND:-absent})."
      echo "Run setup-maas-phase2.sh first."
      exit 1
      ;;
  esac
done

# The Kuadrant CR is created by the manual steps printed at the end of
# Phase 2, not by the script. Without a Ready Kuadrant there is no
# Authorino instance, so maas-api would come up against a half-built
# control plane.
KUADRANT_READY=$(oc get kuadrant -n kuadrant-system \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "${KUADRANT_READY}" != "True" ]; then
  echo "FAIL: no Ready Kuadrant CR in kuadrant-system."
  echo "Complete the Phase 2 manual steps (Kuadrant CR, Authorino TLS"
  echo "bootstrap) and confirm Ready before running Phase 3."
  exit 1
fi

PROG=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
if [ "${PROG}" != "True" ]; then
  echo "FAIL: maas-default-gateway not Programmed."
  exit 1
fi

MANAGED=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/managed}' 2>/dev/null || echo "")
if [ "${MANAGED}" != "false" ]; then
  echo "FAIL: maas-default-gateway is missing annotation"
  echo "  opendatahub.io/managed: \"false\""
  echo "Without it the ODH Model Controller overrides MaaS-managed"
  echo "authorization, silently. Apply manifests/maas/gateway.yaml."
  exit 1
fi
echo "OK: Kuadrant stack healthy, CR Ready, gateway programmed and annotated."
echo

echo "--- Guard: User Workload Monitoring ---"
if ! oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  echo "FAIL: cluster-monitoring-config not found. MaaS reports Degraded"
  echo "without User Workload Monitoring. Run setup-maas-phase1.sh."
  exit 1
fi
echo "OK: monitoring config present."
echo

echo "--- Guard: credentials ---"
: "${MAAS_DB_PASSWORD:?FAIL: export MAAS_DB_PASSWORD before running (quote it)}"
case "${MAAS_DB_PASSWORD}" in
  *[@/:?\#\<\>]*)
    echo "FAIL: MAAS_DB_PASSWORD contains a character that breaks a"
    echo "postgresql:// connection URL (@ / : ? # < >). The secret embeds"
    echo "the password in DB_CONNECTION_URL. Choose a simpler password."
    exit 1
    ;;
esac
echo "OK."
echo

echo "--- Deploying MaaS PostgreSQL (maas-platform) ---"
oc apply -f manifests/maas/maas-postgres.yaml
envsubst < secrets/maas/maas-secrets.template.yaml | oc apply -f -
oc rollout status deployment/maas-postgres -n maas-platform --timeout=180s
echo

echo "--- Enabling modelsAsService in the DataScienceCluster ---"
# Field path confirmed live on RHOAI 3.4.2 via:
#   oc explain datasciencecluster.spec.components.kserve.modelsAsService
# (object with a single field, managementState, enum Managed/Removed).
# The secret is created first deliberately: if modelsAsService is enabled
# before maas-db-config exists, maas-api needs a manual restart.
oc patch datasciencecluster default-dsc --type merge -p \
  '{"spec":{"components":{"kserve":{"managementState":"Managed","modelsAsService":{"managementState":"Managed"}}}}}'
echo

echo "--- Verifying the DSC accepted the patch (this CR silently drops bad fields) ---"
MAAS_STATE=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "")
if [ "${MAAS_STATE}" != "Managed" ]; then
  echo "FAIL: modelsAsService is '${MAAS_STATE:-absent}' in the live spec after patching."
  echo "The DataScienceCluster CR accepts apply without error but silently"
  echo "drops fields it does not recognise. Check the schema:"
  echo "  oc explain datasciencecluster.spec.components.kserve.modelsAsService"
  exit 1
fi
echo "OK: modelsAsService = Managed in the live resolved spec."
echo

echo "--- Waiting for maas-api (up to 3 minutes) ---"
for i in $(seq 1 18); do
  if oc get deployment maas-api -n redhat-ods-applications >/dev/null 2>&1; then
    oc rollout status deployment/maas-api -n redhat-ods-applications --timeout=120s && break
  fi
  sleep 10
done
echo

echo "--- Gate: Tenant CR Ready ---"
READY=""
for i in $(seq 1 18); do
  READY=$(oc get tenant -A -o json 2>/dev/null | python3 -c "
import json, sys
try: data = json.load(sys.stdin)
except Exception: sys.exit()
for i in data.get('items', []):
    for c in i.get('status', {}).get('conditions', []):
        if c.get('type') == 'Ready':
            print(c.get('status'), c.get('reason', ''))
" || echo "")
  case "${READY}" in
    True*)
      # Reason varies by build: the 3.3 docs describe AllComponentsReady,
      # RHOAI 3.4.2 reports Reconciled. Status is the verdict; reason is
      # logged for the record, not gated on.
      echo "PASS: MaaS Tenant Ready (${READY})."
      break
      ;;
  esac
  sleep 10
done
case "${READY}" in
  True*) ;;
  *)
    echo "FAIL: Tenant did not reach Ready (saw: ${READY:-nothing})."
    echo "Check:  oc get tenant -A -o yaml"
    echo "        oc logs deployment/maas-api -n redhat-ods-applications"
    echo "Common causes: maas-db-config connection string wrong or database"
    echo "unreachable; User Workload Monitoring not enabled; MaaS CRDs not"
    echo "yet available."
    exit 1
    ;;
esac
echo

echo "--- Permitting the MaaS API namespace to publish through the gateway ---"
# maas-default-gateway restricts route attachment to namespaces labelled
# maas.opendatahub.io/publish=true. maas-api-route is created by MaaS
# enablement in redhat-ods-applications, so the label must be applied here
# or the route silently fails to attach and every call to /v1/models
# returns 404 (confirmed 2026-07-31).
oc label namespace redhat-ods-applications maas.opendatahub.io/publish=true --overwrite
echo

echo "=== Phase 3 complete. Next: model registration (Phase 4) ==="
