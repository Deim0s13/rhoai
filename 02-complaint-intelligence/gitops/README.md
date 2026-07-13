# GitOps

Argo CD app-of-apps for this use case. Apply `app-of-apps.yaml` once; sync
waves order the rest (namespace, storage, serving, then Llama Stack and
guardrails in parallel).

Deliberately excluded from GitOps: Secrets. This repo holds `*.template.yaml`
files only; `scripts/bootstrap.sh` renders and applies them from environment
variables at deploy time. Rendered secrets must never be committed.

Model artefacts are also not GitOps-managed: `ansible/` seeds MinIO with the
model after storage is up (procedural task, Ansible's job, per lab principles).
