# Deployment log — 2026-06-30 (RHDP sandbox, whvtj)

First live deployment of use case 01 — Sovereign RAG. This log captures
what actually happened, what changed from the original design, and
exactly where to resume tomorrow.

Cluster: RHDP sandbox, GUID whvtj, us-east-2, single NVIDIA L4 node (g6.xlarge)
RHOAI version: 2.25.8 · OpenShift: 4.18.21

---

## Status at end of session

| Layer | Status |
|---|---|
| Namespace + labelling | Done |
| MinIO (self-hosted, no operator) | Done — running, 4 buckets created |
| Documents seeded | Done — 2 real RBNZ PDFs (BPR100, BPR110) |
| Granite model seeded | Done — 15GiB in MinIO `models` bucket |
| Milvus | Done — running, healthy, PVC bound |
| ServingRuntime + InferenceService | **Done — confirmed working end to end** |
| Workbench | Not yet deployed |
| Notebooks | Not yet run against live environment |

**The model serving layer is fully proven.** Sent a real chat completion
request to Granite 3.1 8B Instruct running on the L4 GPU, got a correct,
coherent answer referencing Basel III. This is the hard part — what's
left (workbench + notebooks) is comparatively low-risk.

---

## What changed from the original design, and why

### 1. Terraform / AWS SSM — dropped entirely
RHDP sandboxes provide OpenShift access only, no AWS IAM credentials.
The bastion host has no AWS CLI config either. Terraform and SSM-based
credential retrieval do not apply to this environment type. Credentials
are now passed directly as environment variables to Ansible at runtime.
**Files affected:** `ansible/inventory.yaml`, `ansible/configure-minio.yaml`

### 2. MinIO Operator (AIStor) — dropped, replaced with plain Deployment
The certified OLM catalog only offers MinIO **AIStor** (`minio-object-store-operator`),
not the open-source MinIO Operator our Tenant manifest was written for.
AIStor uses a different CRD (`ObjectStore`, group `aistor.min.io`) — not
`Tenant`. Rather than learn AIStor's operational model, switched to a
plain Kubernetes Deployment + Service + PVC + Route. Simpler, no
operator dependency, works the same for demo purposes.
**Files affected:** `minio/tenant/tenant.yaml` (now a plain Deployment, not a Tenant CR)
**Files now unused:** `minio/operator/subscription.yaml`, both `gitops/*.yaml` Argo CD Applications — GitOps layer was abandoned for this environment; everything was applied directly with `oc apply`

### 3. `huggingface-cli` — deprecated, replaced with `hf`
`huggingface-cli` is now a no-op stub. Silently "succeeded" while
downloading nothing — classic silent failure. Switched to the `hf` CLI.
**Files affected:** `ansible/roles/minio-setup/tasks/seed-models.yaml`

### 4. Idempotency check bug — `mc ls` exit code
`mc ls` on an empty/nonexistent prefix returns `rc=0`, not a failure
code. Our `model_check.rc != 0` condition was always false, so the
download step was silently skipped on every run. Fixed by checking
`stdout` content instead of exit code (`model_already_seeded` fact).
**Files affected:** `ansible/roles/minio-setup/tasks/seed-models.yaml`
**Lesson:** added explicit `failed_when` verification steps after both
download and upload — don't trust silent success on `mc` commands again.

### 5. DataScienceProject CRD — does not exist
RHOAI has no `DataScienceProject` custom resource. A "project" in the
dashboard is just a namespace labelled `opendatahub.io/dashboard=true`.
**Files affected:** `manifests/01-datascienceproject.yaml` should be
deleted; replaced with `oc label namespace sovereign-rag opendatahub.io/dashboard=true`

### 6. KServe webhook — `model:` and `containers:` are mutually exclusive
Original `04-inference-service.yaml` had both `model:` and a sibling
`containers:` block under `predictor:`. KServe's validating webhook
requires exactly one predictor type. Fixed by moving args/resources
into `model:` directly (later moved again — see #9).

### 7. Service Mesh membership — switched to RawDeployment
Default Serverless mode requires the namespace to be enrolled in the
cluster's Istio/Service Mesh member roll. `sovereign-rag` was never
enrolled, and enrolling it was unnecessary complexity for a demo.
Added annotation `serving.kserve.io/deploymentMode: "RawDeployment"`
to skip Knative/Istio entirely — standard Kubernetes Deployment instead.
**Files affected:** `manifests/04-inference-service.yaml` — also removed
the now-irrelevant `serving.knative.openshift.io` / `sidecar.istio.io`
annotations from this file.

### 8. MinIO data connection — doubled HTTPS scheme
`AWS_S3_ENDPOINT` secret value included `https://` AND the
`serving.kserve.io/s3-usehttps: "1"` annotation also triggers KServe's
S3 initializer to prepend `https://` — resulted in `https://https://...`
and DNS resolution failure. Fixed: store bare hostname only in the secret.
**Files affected:** `manifests/06-data-connection.yaml`

### 9. vLLM image — quay.io tag no longer exists
`quay.io/rh-aiservices-bu/vllm-openai-ubi9:0.6.2` returns `manifest
unknown` — community Quay tags aren't stable over time. **Switched to
`registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.2.5`** — Red Hat AI
Inference Server, the supported product. Better fit for the demo
narrative too (named, supported product vs. community image).
**Files affected:** `manifests/03-model-serving-runtime.yaml`

This also surfaced a deeper issue: args were split across both
`03-model-serving-runtime.yaml` and `04-inference-service.yaml`'s
`model.args`. KServe merges both lists, producing duplicated/conflicting
flags (`--model` appearing twice, duplicate `--port` etc.) that the new
RHAIIS CLI rejected outright (the old image's CLI apparently tolerated
this; the new one does not). **Fixed: the ServingRuntime is now the
single source of truth for all serving args.** `04-inference-service.yaml`
no longer sets any args under `model:`.

Also had to add back an explicit positional `/mnt/models` argument —
initial assumption that KServe auto-injects `--model=/mnt/models` for
the `model` predictor type was **wrong** for this KServe/runtime
combination. Without it, vLLM fell through to trying to resolve a
default model from HuggingFace Hub and failed (correctly) because
outgoing traffic is disabled in the container.

---

## Working endpoint reference (for tomorrow)

```
InferenceService URL: http://granite-instruct-predictor.sovereign-rag.svc.cluster.local
Internal service port: 80 → container port 8080
Model name in API calls: /mnt/models
No auth token required (RawDeployment mode, no Service Mesh)
```

Confirmed working test call:
```bash
oc port-forward -n sovereign-rag <pod-name> 8081:8080
curl -s http://localhost:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/mnt/models", "messages": [{"role": "user", "content": "..."}], "max_tokens": 100}'
```

Note: `oc port-forward svc/granite-instruct-predictor 8081:80` failed with
a "lost connection" error despite the Service's targetPort being correctly
set to 8080 — worth a quick re-test tomorrow since it should have worked;
forwarding directly to the pod was used as a workaround and succeeded.

---

## Resume point for tomorrow

1. Confirm whether the new environment retains a fresh GUID/cluster or
   reuses this one — if fresh, **all of the above still needs reapplying**
   (nothing here persists across an RHDP environment teardown unless
   explicitly noted otherwise by the platform).
2. If reapplying from scratch, the manifests/ansible files described
   above are already fixed in the repo (once committed) — should be a
   much faster pass this time since every failure mode is now known.
3. Deploy the Workbench (`manifests/05-workbench.yaml`) — not yet
   attempted today.
4. **Before running notebooks**, `WORKBENCH-SETUP.md` needs updating:
   it currently assumes Serverless mode with a bearer token and external
   Route URL. Actual values needed now:
   - `INFERENCE_ENDPOINT` = `http://granite-instruct-predictor.sovereign-rag.svc.cluster.local`
   - `INFERENCE_TOKEN` = not needed, leave blank
   - `MINIO_ENDPOINT` = the `minio-api` Route host (already correct)
5. Run `01-ingest-and-embed.ipynb`, then `02-rag-query.ipynb`.
6. Once notebooks are confirmed working, do the documentation pass:
   update `01-sovereign-rag/README.md`, `WORKBENCH-SETUP.md`, and the
   manifest files with everything in this log, then capture screenshots
   per the Capture phase before next teardown.

---

## Files that need committing (if not already)

- `manifests/03-model-serving-runtime.yaml` (RHAIIS image, consolidated args)
- `manifests/04-inference-service.yaml` (RawDeployment, no duplicate args)
- `manifests/06-data-connection.yaml` (bare hostname endpoint)
- `manifests/07-serviceaccount.yaml` (new file — minio-sa)
- `minio/tenant/tenant.yaml` (plain Deployment, not AIStor Tenant)
- `ansible/inventory.yaml` (no SSM)
- `ansible/configure-minio.yaml` (no SSM, bucket creation step added)
- `ansible/roles/minio-setup/tasks/seed-models.yaml` (hf CLI, fixed idempotency)
- Delete: `manifests/01-datascienceproject.yaml` (no such CRD)
