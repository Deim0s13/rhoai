#!/usr/bin/env bash
# Bootstrap UC02 into a fresh environment. Idempotent; safe to re-run.
# Prereqs: oc logged in; envsubst.
# Required env: MINIO_ACCESS_KEY, MINIO_SECRET_KEY (UC01 naming convention)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${MINIO_ACCESS_KEY:?set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?set MINIO_SECRET_KEY}"

echo "==> Namespace (needed before secrets)"
oc apply -f manifests/namespace/namespace.yaml

echo "==> Rendering and applying secrets (never committed)"
for t in secrets/minio-secret.template.yaml \
         secrets/storage-secret.template.yaml \
         secrets/inference-secret.template.yaml; do
  envsubst < "$t" | oc apply -f -
done

# UC01 learning: RHDP sandboxes may not ship openshift-gitops. GitOps when
# available; ordered direct apply when not. Same manifests either way.
if oc get ns openshift-gitops > /dev/null 2>&1; then
  echo "==> Argo CD detected: bootstrapping app-of-apps"
  oc apply -f gitops/app-of-apps.yaml
  echo "    Watch sync in the Argo CD console, then run: ansible-playbook ansible/site.yml"
else
  echo "==> No Argo CD (openshift-gitops) found: direct ordered apply (UC01 fallback)"
  for layer in storage serving llama-stack guardrails; do
    echo "    -> $layer"
    for f in manifests/$layer/*.yaml; do
      case "$f" in *.template.yaml) continue ;; esac
      oc apply -f "$f" || true
    done
  done
  echo "    NOTE: llama-stack and guardrails CRs will fail if their operators"
  echo "    are not activated in RHOAI; that is a day-one validation finding,"
  echo "    not a bootstrap bug. Re-run this script after activating them."
  echo "    Then run: ansible-playbook ansible/site.yml"
fi
