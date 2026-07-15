#!/usr/bin/env bash
# Bootstrap UC02 into a fresh environment. Idempotent; safe to re-run.
#
# Prereqs: oc logged in; envsubst (macOS: brew install gettext && brew link --force gettext)
# Required env: MINIO_ACCESS_KEY, MINIO_SECRET_KEY
#
# Hardened after the 2026-07-14 (RHOAI 2.25.8) and 2026-07-15 (RHOAI 3.4.2)
# sessions. Every guard exists because its absence cost real time; see the
# deployment logs and ADR-0005 / ADR-0006.
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

# --- Pre-flight: RHDP catalog items may ship sample workloads holding the GPU.
# 2026-07-15: a `my-first-model` namespace ran Llama 3.2 3B on the only L4, so
# our predictor sat Pending with "Insufficient nvidia.com/gpu" on a node whose
# GPU looked free. Detect, do not delete: removing namespaces we do not own is
# not this script's job.
echo "==> Pre-flight: checking GPU availability"
gpu_holders=$(oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' \
  | grep -vE "^${NS}/" | awk -F'\t' '$2 != "" {print $1}')
if [ -n "$gpu_holders" ]; then
  echo "    WARNING: other workloads are holding GPUs:"
  echo "$gpu_holders" | sed 's/^/      /'
  echo "    On a single-GPU cluster the predictor will sit Pending."
  echo "    Free the GPU (e.g. oc delete namespace <ns>) then re-run."
fi

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

# --- Guard 6: RHOAI may ship components as `Removed` (2.25.8 shipped Llama
# Stack and TrustyAI that way; 3.4.2 ships MLflow that way). Their CRDs do not
# exist until Managed, so those manifests fail with "no matches for kind".
# Patching is idempotent: already-Managed components are unaffected.
echo "==> Ensuring RHOAI components are Managed (Llama Stack, TrustyAI, MLflow)"
DSC=$(oc get datasciencecluster -o name 2>/dev/null | head -1)
if [ -z "$DSC" ]; then
  echo "ERROR: no DataScienceCluster found. Is RHOAI installed on this cluster?"
  exit 1
fi

oc patch "$DSC" --type=merge -p '{
  "spec": {
    "components": {
      "llamastackoperator": { "managementState": "Managed" },
      "trustyai":           { "managementState": "Managed" },
      "mlflowoperator":     { "managementState": "Managed" }
    }
  }
}'

# --- Guard 7: patching is asynchronous. The operator reconciles and installs
# the CRDs; applying manifests before they exist fails. Wait for the CRDs
# themselves, not for the patch response.
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
fi

# --- Guard 8: MinIO must be running the CURRENT credentials. `envFrom` reads a
# Secret only at container start, so a pod predating a credential change keeps
# the old values (2026-07-14: cost most of a session).
#
# But an unconditional restart is itself harmful: on a fresh deploy it can
# interrupt MinIO's first-time .minio.sys/ init on a single-drive erasure
# backend, leaving a volume it cannot recover from and reporting
# "0 drives online" (2026-07-15).
#
# So: check the running state directly rather than inferring from timestamps
# (`oc apply` on a changed Secret does not update creationTimestamp, so time
# comparison misses the exact case this guard exists for). Restart only if the
# live pod's credentials actually differ.
#
# This guard must run LAST: MinIO does not exist until the apply block above.
echo "==> Verifying MinIO is running the current credentials"
if oc get deploy/minio -n "$NS" >/dev/null 2>&1; then
  oc rollout status deploy/minio -n "$NS" --timeout=180s >/dev/null 2>&1 || true
  live_user=$(oc exec deploy/minio -n "$NS" -- printenv MINIO_ROOT_USER 2>/dev/null || echo "")
  if [ -z "$live_user" ]; then
    echo "    MinIO not reachable yet; skipping restart (check it manually if seeding fails)"
  elif [ "$live_user" != "$MINIO_ACCESS_KEY" ]; then
    echo "    Running pod has stale credentials ($live_user); restarting"
    oc rollout restart deploy/minio -n "$NS"
    oc rollout status deploy/minio -n "$NS" --timeout=180s
  else
    echo "    MinIO already running current credentials; no restart needed"
  fi
fi

cat <<'NEXT'

==> Bootstrap complete. Next:
    1. export HF_TOKEN=<token>
    2. ansible-playbook ansible/site.yml     # discovers the Route itself
    3. After seeding: oc delete pod -l serving.kserve.io/inferenceservice=granite-3-3-8b-instruct

    Do NOT use `oc expose` or port-forward for MinIO: the Route is managed in
    manifests/storage/minio-route.yaml. See ADR-0005.
NEXT
