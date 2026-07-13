#!/usr/bin/env bash
# Bootstrap UC02 into a fresh environment. Idempotent; safe to re-run.
# Prereqs: oc logged in with cluster-admin; envsubst; Argo CD (openshift-gitops) present.
# Required env: MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."

: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD}"

echo "==> Namespace (needed before secrets)"
oc apply -f manifests/namespace/namespace.yaml

echo "==> Rendering and applying secrets (never committed)"
for t in manifests/storage/minio-secret.template.yaml \
         manifests/serving/storage-secret.template.yaml \
         manifests/llama-stack/inference-secret.template.yaml; do
  envsubst < "$t" | oc apply -f -
done

echo "==> Bootstrapping Argo CD app-of-apps"
oc apply -f gitops/app-of-apps.yaml

echo "==> Done. Watch sync: argocd app list | grep uc02  (or the Argo CD console)"
echo "    Then run: ansible-playbook ansible/site.yml"
