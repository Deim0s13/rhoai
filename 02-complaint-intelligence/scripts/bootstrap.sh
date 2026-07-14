#!/usr/bin/env bash
# Bootstrap UC02 into a fresh environment. Idempotent; safe to re-run.
#
# Prereqs: oc logged in; envsubst (macOS: brew install gettext && brew link --force gettext)
# Required env: MINIO_ACCESS_KEY, MINIO_SECRET_KEY
#
# Hardened after the 2026-07-14 session. Each guard below exists because its
# absence cost real time; see DEPLOYMENT-LOG and ADR-0005.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=complaint-intelligence

# --- Guard 1: envsubst must exist. Without it, secrets reach the cluster with
# literal ${VAR} placeholders and every later error is a confusing auth failure.
command -v envsubst >/dev/null 2>&1 || {
  echo "ERROR: envsubst not found. macOS: brew install gettext && brew link --force gettext"
  exit 1
}

# --- Guard 2: credentials must be set AND non-empty.
: "${MINIO_ACCESS_KEY:?set MINIO_ACCESS_KEY (e.g. export MINIO_ACCESS_KEY=minio-admin)}"
: "${MINIO_SECRET_KEY:?set MINIO_SECRET_KEY}"
[ -n "$MINIO_ACCESS_KEY" ] && [ -n "$MINIO_SECRET_KEY" ] || {
  echo "ERROR: MINIO_ACCESS_KEY / MINIO_SECRET_KEY are set but empty."; exit 1; }

# --- Guard 3: logged in, and pin every command to the right namespace.
# Session finding: the active project was 'default' while -n flags pointed
# elsewhere, so resources landed in two places at once.
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in. Run oc login first."; exit 1; }

echo "==> Namespace (must exist before secrets)"
oc apply -f manifests/namespace/namespace.yaml
oc project "$NS" >/dev/null

echo "==> Rendering secrets from secrets/ (deliberately OUTSIDE any Argo-synced path)"
# Session finding: templates under manifests/ were applied verbatim by Argo,
# placeholders and all, and selfHeal re-clobbered every correct render.
for t in secrets/*.template.yaml; do
  rendered=$(envsubst < "$t")
  # --- Guard 4: never let an unsubstituted placeholder reach the cluster.
  if grep -q '\${' <<< "$rendered"; then
    echo "ERROR: unsubstituted variable in $t. Check your exports."
    grep -o '\${[A-Z_]*}' <<< "$rendered" | sort -u
    exit 1
  fi
  echo "$rendered" | oc apply -n "$NS" -f -
done

# --- Guard 5: prove what MinIO will actually run with.
echo "==> Verifying rendered secret (should show your access key, not a placeholder)"
oc get secret minio-credentials -n "$NS" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d; echo

# --- Guard 7: RHOAI ships Llama Stack and TrustyAI as `Removed` on RHDP
# catalog images. Their CRDs do not exist until the components are Managed, so
# manifests/llama-stack and manifests/guardrails fail to apply on a fresh
# cluster. Session finding 2026-07-14: this was a manual console step, which is
# precisely the kind of undocumented action the lab exists to eliminate.
echo "==> Ensuring RHOAI components are Managed (Llama Stack, TrustyAI)"
DSC=$(oc get datasciencecluster -o name 2>/dev/null | head -1)
if [ -z "$DSC" ]; then
  echo "ERROR: no DataScienceCluster found. Is RHOAI installed on this cluster?"
  exit 1
fi

oc patch "$DSC" --type=merge -p '{
  "spec": {
    "components": {
      "llamastackoperator": { "managementState": "Managed" },
      "trustyai":           { "managementState": "Managed" }
    }
  }
}'

# --- Guard 8: patching is asynchronous. The operator reconciles and installs
# the CRDs; applying manifests before they exist fails with
# "no matches for kind". Wait for the CRDs themselves, not for the patch.
echo "==> Waiting for component CRDs to appear (up to 180s)"
for crd in llamastackdistributions.llamastack.io \
           guardrailsorchestrators.trustyai.opendatahub.io; do
  for i in $(seq 1 36); do
    if oc get crd "$crd" >/dev/null 2>&1; then
      echo "    ok: $crd"
      break
    fi
    [ "$i" -eq 36 ] && {
      echo "ERROR: $crd did not appear within 180s."
      echo "       Check: oc get datasciencecluster -o yaml | grep -A2 -iE 'llamastack|trustyai'"
      echo "       and:   oc logs -n redhat-ods-operator deploy/rhods-operator --tail=40"
      exit 1
    }
    sleep 5
  done
done

if oc get ns openshift-gitops > /dev/null 2>&1; then
  echo "==> Argo CD detected: bootstrapping app-of-apps"
  oc apply -f gitops/app-of-apps.yaml
  echo "    Watch: oc get applications.argoproj.io -n openshift-gitops"
  echo "    (note: 'oc get applications' alone may resolve to the wrong CRD)"
else
  echo "==> No Argo CD: direct ordered apply"
  for layer in storage serving llama-stack guardrails; do
    echo "    -> $layer"
    for f in manifests/$layer/*.yaml; do
      [ -e "$f" ] || continue
      oc apply -n "$NS" -f "$f" || true
    done
  done
  echo "    NOTE: llama-stack and guardrails CRs fail until those operators are"
  echo "    set to Managed in RHOAI. Activate them, then re-run this script."
fi

# --- Guard 6: MinIO must be running the CURRENT secret. envFrom is read at
# container start, so a secret applied after the pod started is not in effect.
echo "==> Ensuring MinIO picks up current credentials"
oc rollout restart deploy/minio -n "$NS" >/dev/null 2>&1 || true
oc rollout status deploy/minio -n "$NS" --timeout=180s || true

cat <<'NEXT'

==> Bootstrap complete. Next:
    1. Activate Llama Stack and TrustyAI (Managed) in RHOAI if not already.
    2. export HF_TOKEN=<token>
    3. ansible-playbook ansible/site.yml     # discovers the Route itself
    4. After seeding: oc delete pod -l serving.kserve.io/inferenceservice=granite-3-3-8b-instruct

    Do NOT use `oc expose` or port-forward for MinIO: the Route is managed in
    manifests/storage/minio-route.yaml. See ADR-0005.
NEXT
