# Deployment log: 2026-07-15 (RHDP sandbox, cluster-8dvx8)

First live deployment of use case 02, Complaint Intelligence. Same discipline as
UC01: what actually happened, what changed from the design, and where to resume.

Cluster: RHDP sandbox, GUID 8dvx8, us-east-2, 1x NVIDIA L4
RHOAI: 2.25.8 | KServe: v0.14.0 (defaultDeploymentMode Serverless)

---

## Status at end of session

| Layer                                    | Status                                                         |
| ---------------------------------------- | -------------------------------------------------------------- |
| Repo committed, bootstrap run            | Done                                                           |
| Argo CD present                          | Yes, driving sync (fallback path not exercised)                |
| Namespace + labelling                    | Done                                                           |
| MinIO (plain Deployment)                 | Running                                                        |
| Model seeded (Granite 3.3 8B, ~16GiB)    | Done, via Route                                                |
| ServingRuntime + InferenceService        | Running 1/1, inference verified                                |
| Llama Stack distribution                 | Running 1/1, inference verified through unified API            |
| Milvus round trip via Llama Stack        | Provider registered (inline::milvus), on PVC                   |
| Guardrails orchestrator + regex detector | Running 2/2, PII detection verified                            |
| Tracing located and exercised            | Partial: automatic trace_id/span_id observed, not yet designed |
| Gateway / MaaS assessed                  | Not started (deferred)                                         |
| ADR-0002                                 | Accepted                                                       |
| ADR-0005, ADR-0006                       | Written, Accepted                                              |
| ADR-0003, ADR-0004                       | Still Draft (next session)                                     |

---

## Validation items

| #   | Item                                                       | Result                                                                                                                                       |
| --- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| V1  | RHAIIS image tag `3.2.5` current                           | PASS, unchanged                                                                                                                              |
| V2  | `--served-model-name` accepted                             | PASS, model answers to `granite-3-3-8b-instruct`                                                                                             |
| V3  | GPU product label `NVIDIA-L4`                              | PASS, manifest nodeSelector correct as written                                                                                               |
| V4  | In-cluster MinIO Service endpoint for storage initializer  | PASS, failure was NoSuchBucket (connection fine); no Route fallback needed                                                                   |
| V5  | MinIO pinned image pullable                                | PASS                                                                                                                                         |
| V6  | openshift-gitops present                                   | PASS, Argo path used                                                                                                                         |
| V7  | Llama Stack operator available                             | PASS after activation (shipped `Removed`)                                                                                                    |
| V8  | Distribution name `rh-dev` valid                           | PASS                                                                                                                                         |
| V9  | Inline Milvus env correct                                  | FAIL (benign): `MILVUS_DB_PATH` ignored, distribution default used, and it is on the PVC. Env var removed from CR                            |
| V10 | pymilvus/marshmallow conflict sidestepped via Llama Stack? | YES, by construction. Milvus runs inline inside the Llama Stack container; nothing imports pymilvus on our side. Feed back to UC01 close-out |
| V11 | TrustyAI operator + built-in detector sidecar              | PASS after activation, 2/2 pod, detection verified                                                                                           |
| V12 | Tracing location and span model                            | PARTIAL, see finding 10                                                                                                                      |
| V13 | MaaS / gateway capability                                  | Not assessed                                                                                                                                 |

---

## What changed from the original design, and why

### 1. Secret templates were inside Argo-synced paths (the session's biggest cost)

**Expected:** bootstrap renders `*.template.yaml` via envsubst; Argo manages
declarative state.
**Happened:** templates lived in `manifests/storage/`, `manifests/serving/` and
`manifests/llama-stack/`, which Argo syncs. Argo does not run envsubst, so it
applied them verbatim. MinIO started with the literal string
`${MINIO_ACCESS_KEY}` as its root user, and `selfHeal: true` re-clobbered every
correct manual render within seconds.
**Symptom:** `mc: <ERROR> The Access Key Id you provided does not exist in our
records`, while the template in Git looked perfectly correct.
**Fix:** templates moved to `secrets/`, outside every synced path. Bootstrap
updated. Recorded as ADR-0005.
**Files:** `secrets/*.template.yaml` (new), `scripts/bootstrap.sh`,
deleted from `manifests/{storage,serving,llama-stack}/`.

### 2. `oc expose` in an Argo-managed namespace gets pruned

**Happened:** `oc expose service minio` reported success, and the Route was gone
before the next command ran. `oc expose` copies the Service's labels onto the
new Route, including Argo's tracking label; Argo then saw a tracked resource
absent from Git and pruned it.
**Fix:** Route committed as `manifests/storage/minio-route.yaml`. Manual
`oc expose` is now effectively banned in this namespace (ADR-0005).

### 3. port-forward is unusable for the model upload

**Expected:** port-forward sufficient for seeding.
**Happened:** `error: lost connection to pod` mid-transfer; all four safetensors
shards failed with `connection refused` after ~16 minutes of successful small
files. The Route completed the same upload (13.91 GiB in 10m31s) without issue.
**Fix:** Route with `haproxy.router.openshift.io/timeout: 1800s` (the default
router timeout also kills large shard uploads). Ansible discovers the Route
hostname itself; no manual `MINIO_ENDPOINT` export.
**Files:** `manifests/storage/minio-route.yaml`, `ansible/site.yml`.

### 4. `mc cp --recursive` replaced with `mc mirror`

**Rationale:** the failed upload would have restarted from zero. `mc mirror`
resumes and skips what is already uploaded. Also `--exclude ".cache/*"`: the hf
download tree carries lock/metadata files with no business in the model bucket.
**Files:** `ansible/roles/model_fetch/tasks/main.yml`.

### 5. RHOAI components ship `Removed` on RHDP

**Happened:** `llamastackoperator` and `trustyai` both `managementState:
Removed`; their CRDs did not exist, so those manifests could not apply. Console
activation did not take on the first attempt; patching the DataScienceCluster
worked immediately.
**Fix:** bootstrap patches the DSC and waits for the CRDs to appear (patching is
async; the CRD is the readiness signal). Recorded as ADR-0006.
**Files:** `scripts/bootstrap.sh`, `REBUILD.md` (console step deleted).

### 6. KServe RawDeployment predictor service is HEADLESS

**Expected:** predictor Service maps port 80 to container 8080 (carried
assumption from UC01's log).
**Happened:** the Service is headless (`ClusterIP: None`). Declared port
mappings are a no-op: DNS resolves straight to the pod IP, so nothing listens on 80. Llama Stack exited ~8s after start with
`ValueError: Failed to connect to vLLM at http://...svc.cluster.local/v1`.
**Fix:** in-cluster clients must target the container port. `VLLM_URL` now
`...svc.cluster.local:8080/v1`.
**Files:** `secrets/inference-secret.template.yaml`.
**Generalises:** applies to anything consuming a RawDeployment predictor.
Belongs in UC01's learnings too.

### 7. Operator names its service `<cr-name>-service`

`lsd-complaint-intelligence-service`, not `lsd-complaint-intelligence`. Small,
costs a minute every time it is not written down.

### 8. `MILVUS_DB_PATH` is ignored; storage is persistent anyway

**Happened:** the CR set `/.llama/milvus.db`; the provider reports
`/opt/app-root/src/.llama/distributions/rh/milvus.db`. The env var does not take.
**Investigated:** the 20Gi PVC is mounted at
`/opt/app-root/src/.llama/distributions/rh` (ext4 on /dev/nvme2n1), which is
exactly where Milvus writes. The vector store survives pod restarts.
**Fix:** env var removed from the CR as a false statement; comment added
recording the real behaviour so it is not re-added.
**Note:** `df -h` on the parent directory reports overlay and is misleading;
check `mount` for the real picture.

### 9. Embedding models ship with the distribution

`granite-embedding-125m` (768 dims) and `all-MiniLM-L6-v2` (384 dims) are
pre-registered via the `sentence-transformers` provider. No separate embedding
model deployment is needed. Removes planned work from the ingestion pipeline.

### 10. Llama Stack emits trace_id and span_id automatically

Every completion response carries a `metrics` block with `trace_id`, `span_id`,
and token counts attributed to `model_id` and `provider_id`. This partially
answers ADR-0004's first question: automatic telemetry exists, so the
instrumentation task is layering the four-stage span structure onto existing
traces, not building tracing from scratch.

Additionally, `GuardrailsOrchestrator.spec` exposes an `otelExporter` block
(`otlpEndpoint`, `tracesEndpoint`, `tracesProtocol`), meaning guardrail
decisions can join the same trace. ADR-0004 needs amending in light of both.

### 11. Guardrails orchestrator is TLS-only on 8032

**Expected:** HTTP on 8033.
**Happened:** service exposes `https` on 8032 and `health` on 8034. Detection
calls require `https://` and, in-cluster, a self-signed cert (curl needs `-k`).
**Implication for pipeline code:** clients must handle TLS trust or skip-verify.
**Also noted:** detector names are loose. A request naming `email` and
`credit-card` matched detections `email_address` and `credit_card`.
**Also noted:** `spec.autoConfig.inferenceServiceToGuardrail` exists as an
alternative to hand-written orchestrator config. Not used; worth evaluating.

### 12. Smaller items

- `oc get applications` can resolve to the wrong CRD. Use
  `oc get applications.argoproj.io`.
- Active project was `default` while `-n` flags pointed elsewhere, so resources
  landed in two places. Bootstrap now pins `oc project` explicitly.
- Ansible warned on every run: `namespace` is a reserved variable name. Renamed
  to `uc02_namespace`.
- macOS tooling: `pip install` is blocked by PEP 668 on Homebrew Python; use
  `pipx`. `envsubst` needs `brew link --force gettext`.
- RHDP tokens expire mid-session. `Unauthorized` on every oc command means
  re-login, not a broken deployment.
- A password ending in `!` needs single-quoting in zsh.

---

## Working endpoint reference

```
vLLM (direct, headless):  granite-3-3-8b-instruct-predictor.complaint-intelligence.svc.cluster.local:8080/v1
Llama Stack:              lsd-complaint-intelligence-service:8321
                          completions: POST /v1/openai/v1/chat/completions
                          models:      GET  /v1/models
                          providers:   GET  /v1/providers
Guardrails detection:     guardrails-orchestrator-service:8032  (HTTPS, self-signed)
                          POST /api/v2/text/detection/content
Guardrails health:        guardrails-orchestrator-service:8034
MinIO (in-cluster):       minio.complaint-intelligence.svc.cluster.local:9000
MinIO (laptop, seeding):  minio-api Route (1800s timeout)
Model name in API calls:  granite-3-3-8b-instruct
```

Confirmed working calls:

```bash
# Inference through Llama Stack
oc port-forward svc/lsd-complaint-intelligence-service 8321:8321 &
curl -s http://localhost:8321/v1/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"granite-3-3-8b-instruct","messages":[{"role":"user","content":"..."}],"max_tokens":80}'

# PII detection
oc port-forward svc/guardrails-orchestrator-service 8032:8032 &
curl -sk https://localhost:8032/api/v2/text/detection/content \
  -H "Content-Type: application/json" \
  -d '{"detectors":{"regex":{"regex":["email","credit-card"]}},"content":"..."}'
```

Detection response confirms both mock PII patterns caught with spans,
`detection_type: pii`, score 1.0. This is the Safety pillar evidence artefact.

---

## Resume point for next session

1. **Phase 7, tracing.** ADR-0004 needs amending, not just ratifying: automatic
   trace_id/span_id exist (finding 10) and the orchestrator has an otelExporter.
   Design the four-stage span structure around what the platform already emits.
2. **Phase 6 remainder / ADR-0003, gateway.** V13 not assessed. Determine whether
   2.25.8 offers a MaaS capability, or whether the Economics pillar is
   demonstrated by composition or as a documented pattern.
3. **Synthetic data.** Unblocked and independent of the platform. The fixture
   conventions were validated indirectly today: the mock card and email patterns
   fire the regex detector cleanly.
4. **Pipeline code** remains gated on ADR-0004.
5. If the environment is reaped, everything above rebuilds from the repo. That
   is the point, and the rebuild has not yet been proven end to end.

---

## Files committed from this session

- `secrets/*.template.yaml` (new location; deleted from `manifests/`)
- `manifests/storage/minio-route.yaml` (new)
- `manifests/llama-stack/llamastackdistribution.yaml` (MILVUS_DB_PATH removed)
- `scripts/bootstrap.sh` (8 guards, operator activation, CRD wait)
- `ansible/site.yml`, `ansible/roles/model_fetch/tasks/main.yml`
- `docs/adrs/ADR-0002` (Accepted), `ADR-0005`, `ADR-0006` (new)
- `REBUILD.md` (new)
- this log
