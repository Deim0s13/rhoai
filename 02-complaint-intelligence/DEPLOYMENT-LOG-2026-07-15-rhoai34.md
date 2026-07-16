# Deployment log: 2026-07-15 (RHDP sandbox, RHOAI 3.4.2)

Second live deployment of use case 02, and the first on RHOAI 3.x. Two purposes:
validate the stack on the version a customer would actually deploy, and test
whether the repo genuinely rebuilds. It did both, and found more in the process
than the first session did.

Cluster: RHDP sandbox, single node (control-plane/master/worker), us-east-2
RHOAI: 3.4.2 | OpenShift: 4.20.28 | Kubernetes: v1.33.12
GPU: 1x NVIDIA L4, no taints, 31.5 CPU / 125GB allocatable
Argo CD: absent (fallback direct-apply path used)

Note: this session ran across two clusters. The first was lost to an
environment issue mid-investigation; the second was used for the clean rebuild
test. Findings from both are recorded together.

---

## Status at end of session

| Layer                                      | Status                                                         |
| ------------------------------------------ | -------------------------------------------------------------- |
| Bootstrap (fresh cluster, no manual edits) | Clean                                                          |
| Ansible seeding                            | Clean (after fixes, see 5 and 6)                               |
| MinIO                                      | Running, after two bugs fixed (see 3 and 4)                    |
| PostgreSQL (new)                           | Running                                                        |
| Model seeded (Granite 3.3 8B)              | Done, mirror from local cache, ~10 min                         |
| ServingRuntime + InferenceService          | Running 1/1, inference verified                                |
| Llama Stack distribution                   | Running 1/1, inference verified through unified API            |
| Guardrails orchestrator                    | Running 2/2                                                    |
| Vector store                               | ABSENT: no provider registered by default (see 8)              |
| Embedding model                            | ABSENT: none registered by default (see 9)                     |
| Gateway / MaaS                             | Present as Gateway API, not investigated (ADR-0003 still open) |
| ADR-0005 / 0006                            | Validated in practice                                          |
| ADR-0004                                   | Amended (see 11)                                               |
| ADR-0007                                   | New: thin application                                          |

---

## The rebuild test

The headline result. On a fresh cluster, with the repo as committed, the only
manual actions were:

1. `oc login`
2. `export` of four credentials
3. `./scripts/bootstrap.sh`
4. `ansible-playbook ansible/site.yml`
5. `oc delete namespace my-first-model` (now automated, see 2)
6. `oc delete pod -l serving.kserve.io/inferenceservice=...` after seeding

Steps 5 and 6 are the remaining gaps. Step 5 is now handled by the pre-flight
block; step 6 is still a documented command rather than an automated one.
Neither has been re-tested since being addressed.

Everything else reproduced from the repository, on a different major version of
RHOAI than it was written for. That is a harder test than a like-for-like
rebuild, and it is the evidence behind the claim that the environment is
rebuildable from Git.

---

## What changed from the original design, and why

### 1. PostgreSQL is required for Llama Stack (the headline finding)

**Expected:** Llama Stack uses SQLite on the mounted PVC, as it did on 2.25.8.
**Happened:** the distribution pod exits approximately 2 seconds after start:

```
RuntimeError: Could not connect to PostgreSQL database server
```

Faster than the ~8s vLLM connection failure seen on 2.25, because it fails
before any network call to vLLM is attempted.

**Root cause:** documented, not a bug. From RHOAI 3.2 onward, PostgreSQL is the
default and recommended metadata store for Llama Stack, and Red Hat's
documentation is explicit that provisioning and managing the PostgreSQL
instance is the user's responsibility. Our CR was written against 2.25 docs.

**Investigation dead ends worth recording**, since they cost time:

- `availableDistributions` on 3.4 contains only `rh-dev`. There is no
  SQLite-backed alternative distribution to switch to.
- The CR schema has no database field. The operator does not manage Postgres.
- `LLAMA_STACK_CONFIG=/etc/llama-stack/config.yaml`, but that path does not
  exist in the image: it is created at runtime by the entrypoint. Peeking into
  the image with an overridden command therefore shows nothing, because the
  entrypoint never runs.
- The image's `distributions/` directory contains ci-tests, nvidia, oci,
  open-benchmark, postgres-demo, starter and watsonx. There is no `rh`
  directory; `rh-dev` is a name-to-image mapping, not a packaged distribution.

**Fix:** deploy PostgreSQL (`manifests/storage/postgres-deployment.yaml`), add
`secrets/postgres-secret.template.yaml`, and add `POSTGRES_HOST`,
`POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER` and `POSTGRES_PASSWORD` to the
CR per the documented example. Secret name and key match the docs
(`postgres-secret` / `password`) deliberately, so the CR reads the same as the
reference material.

**Result:** Llama Stack reached 1/1 in 21 seconds.

**Why this matters beyond this build:** any Llama Stack workload carried from
2.25 to 3.2+ hits this, and the symptom points at Postgres without explaining
why Postgres is suddenly involved. Worth telling anyone else building on RHOAI.

### 2. RHDP catalog items ship a workload holding the GPU

**Happened:** the predictor sat `Pending` with
`0/1 nodes are available: 1 Insufficient nvidia.com/gpu` on a node whose GPU
appeared free. A `my-first-model` namespace, shipped with the catalog item, was
running Llama 3.2 3B on the only L4.

**Confirmed on two consecutive 3.4 clusters**, so this is catalog behaviour,
not chance.

**Diagnosis:** query GPU requests cluster-wide, not just in your own namespace:

```bash
oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' | grep -v '	$'
```

**Fix:** a pre-flight block in the bootstrap detects GPU holders and deletes
only namespaces on an explicit allow-list of known RHDP samples, with
`UC02_FREE_GPU=false` to disable. Deleting arbitrary namespaces we do not own
is deliberately not done: the script must stay safe to run anywhere.

**Note:** `Pending` is a queued state, not a failed one. Once the GPU freed,
the scheduler placed the pod without intervention. No pod deletion needed,
unlike the `Init:CrashLoopBackOff` case where deleting skips the backoff timer.

### 3. MinIO RollingUpdate corrupts first-time initialisation

**Happened:** `mc admin info` reported `0 drives online, 1 drive offline` on a
freshly deployed MinIO whose PVC was correctly mounted and empty. The pod logs
showed a boot loop:

```
Unable to initialize backend: failed to load rebalance data:
Storage resources are insufficient for the read operation .minio.sys/rebalance.bin
```

**Root cause:** Guard 6's unconditional `rollout restart` triggered a
RollingUpdate on a Deployment with an RWO PVC and a single-drive erasure
backend. The bootstrap output showed "1 old replicas are pending termination"
four times. The first pod was killed part-way through writing `.minio.sys/`,
and the replacement inherited a half-written system directory it could not
read or repair.

**Fix, two parts:**

- `strategy: Recreate` on the MinIO Deployment. RollingUpdate starts a second
  pod against the same RWO volume; Recreate does not.
- Guard 8 (renumbered) now checks whether the running pod's credentials
  actually differ before restarting, instead of restarting every run.

**Recovery:** scale to 0, delete the PVC, reapply, scale to 1. The volume held
nothing but the broken init.

**Note:** this bug was latent on 2.25.8 and got away with it by timing luck.
The rebuild test surfaced it.

**Note on the guard:** timestamp comparison was considered and rejected.
`oc apply` on a changed Secret does not update `creationTimestamp`, so
comparing pod start time against it would miss the exact case the guard exists
for. It checks the live pod's environment instead.

### 4. `mc` signature auto-detection fails through the router

**Happened:**

```
mc: <ERROR> Unable to initialize new alias from the provided credentials.
Get "http://.../probe-bsign-.../?location=": Connection closed by foreign host
```

while plain `curl -sI` against the same route returned `server: MinIO` and a
normal 400.

**Diagnosis:** `mc --debug` showed `BuildS3Config(...auto)` then
`probeS3Signature [s3v4, s3v2]`. The connection dies on the s3v2 probe.

**Fix:** `mc alias set --api s3v4`. MinIO has spoken only v4 for years, so the
probe is pointless. Added to both alias tasks in the model_fetch role.

### 5. Ansible reserved variable name

**Happened:** the `seed_taxonomy` role produced:

```
/bin/sh: class: No such file or directory
oc create configmap taxonomy ... -n <class 'jinja2.utils.Namespace'>
```

**Root cause:** `namespace` is a reserved Ansible variable name. When
`site.yml` was renamed to `uc02_namespace`, the roles were not updated. Because
the name is reserved, `{{ namespace }}` did not fail as undefined: it silently
resolved to jinja2's `Namespace` class.

**Fix:** `{{ uc02_namespace }}` in the role. `grep -rn "{{ namespace }}"
ansible/` confirmed no other occurrences.

**Worth noting:** this is exactly the drift that motivated running the rebuild
test rather than reading the code and assuming.

### 6. The https fallback masked the real error

The model_fetch role's http alias task carries `failed_when: false` so the
https fallback can run. The consequence is that a genuine http failure is
marked `ok` and only the fallback's error is reported, which pointed the
investigation at TLS when the actual problem was elsewhere. Left as-is for now;
worth restructuring so the primary error surfaces.

### 7. Model identifiers are provider-prefixed

`/v1/models` returns `vllm-inference/granite-3-3-8b-instruct`. API calls with
the bare name fail:

```
Model 'granite-3-3-8b-instruct' not found. Use 'client.models.list()' ...
```

The bare name worked on 2.25. `INFERENCE_MODEL` in the secret stays bare: the
provider adds the prefix at registration.

Also: `/v1/openai/v1/chat/completions` returns 404 on 3.4. The API is
OpenAI-native at `/v1/chat/completions`. The `/v1/models` response shape has
correspondingly changed from `identifier`/`provider_resource_id` to
`id`/`object`/`created`/`owned_by`.

### 8. No vector_io provider by default

`/v1/providers` on 3.4 registers: inference (`vllm-inference`), safety
(`trustyai_fms`), responses (`meta-reference`), eval (`trustyai_lmeval`),
datasetio (`huggingface`, `localfs`), scoring (`basic`, `llm-as-judge`,
`braintrust`), tool_runtime, files, batches.

**No vector_io provider at all.** RHOAI 2.25 registered `inline::milvus`
without any configuration. On 3.4 the knowledge layer is an explicit choice:
inline FAISS, inline Milvus, remote Milvus, or remote pgvector. The docs
present these as four deployment examples.

Consequence: `MILVUS_DB_PATH` was already removed from the CR as a no-op on
2.25; on 3.4 there is no inline Milvus to configure in the first place.
Inline Milvus on 3.2+ uses PostgreSQL as its backing metadata store.

### 9. No embedding model by default

RHOAI 2.25 pre-registered `granite-embedding-125m` (768 dims) and
`all-MiniLM-L6-v2` (384 dims) via `sentence-transformers`, for free. On 3.4,
`/v1/models` lists only the LLM.

Per the docs, remote embedding models are the recommended default for
production from 3.2, configurable via `VLLM_EMBEDDING_URL`, with inline
embeddings available for development. The known-issues page documents
`SENTENCE_TRANSFORMERS_HOME`, `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE` and
`HF_DATASETS_OFFLINE` for using an embedded model offline.

This retracts a claim made in the 2026-07-14 log: embeddings do not come free.
On the current platform they are a decision, and on a single-GPU cluster
serving one via vLLM competes with the LLM for the card.

### 10. MaaS is Gateway API, not a DSC component

Not in the component list. Present as CRDs: `gatewayconfigs.services.platform
.opendatahub.io` plus the full Gateway API set. Two gateway classes exist and
are Accepted: `openshift-ai-inference` and `data-science-gateway-class`, with
`default-gateway` ready.

So the Economics pillar is reachable on this version through platform-native
capability rather than composition, which is ADR-0003's preferred option.
Not investigated further this session.

### 11. Telemetry: the 2.25 observation does not hold

On 2.25.8, every completion response carried a `metrics` block with
`trace_id`, `span_id` and token counts attributed to `model_id` and
`provider_id`. On 3.4.2 the response carries OpenAI-native `usage` only.
Whether server-side telemetry persists as it did (sqlite trace store on the
PVC) is unverified on this version.

ADR-0004 amended accordingly. The decision is unchanged and arguably
strengthened: the telemetry story changed across one major version while the
evidence record schema did not. Evidence written deliberately survives
platform churn; telemetry inherited from the platform does not.

### 12. Smaller items

- **RHOAI 3.4 component states:** Llama Stack and TrustyAI ship `Managed`
  (they shipped `Removed` on 2.25). `mlflowoperator` ships `Removed` and is a
  real DSC component, added to the bootstrap patch. ADR-0006's idempotency
  claim held: the patch was a no-op for the two already Managed.
- **MLflow is a supported component from 3.4**, managed through the MLflow
  Operator. This was the reason for moving off 2.25 in the first place, along
  with MaaS reaching GA.
- **`rh-dev` remains the correct distribution name** on 3.4.
- **Single-node cluster** was not a problem at this capacity: 31.5 CPU,
  125GB memory, no taints, 33% memory requested at rest.
- **The Llama Stack CR's `storage` block is still required** even with
  Postgres; the documented example retains it.
- The `oc project default` mix-up from the previous session did not recur:
  the bootstrap now pins the namespace.
- Guard 4 (unsubstituted placeholder check) stayed quiet throughout, which is
  the first time the secrets pattern has worked first time.

---

## Working endpoint reference (RHOAI 3.4.2)

```
vLLM (direct, headless):  granite-3-3-8b-instruct-predictor.complaint-intelligence.svc.cluster.local:8080/v1
Llama Stack:              lsd-complaint-intelligence-service:8321
                          completions: POST /v1/chat/completions
                          models:      GET  /v1/models
                          providers:   GET  /v1/providers
                          routes:      GET  /v1/inspect/routes
Guardrails detection:     guardrails-orchestrator-service:8032  (HTTPS, self-signed)
                          POST /api/v2/text/detection/content
Guardrails health:        guardrails-orchestrator-service:8034
PostgreSQL:               postgres.complaint-intelligence.svc.cluster.local:5432 (db/user: llamastack)
MinIO (in-cluster):       minio.complaint-intelligence.svc.cluster.local:9000
MinIO (laptop, seeding):  minio-api Route (1800s timeout), mc requires --api s3v4
Model name in API calls:  vllm-inference/granite-3-3-8b-instruct
```

Confirmed working:

```bash
oc port-forward svc/lsd-complaint-intelligence-service 8321:8321 &
curl -s http://localhost:8321/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"vllm-inference/granite-3-3-8b-instruct","messages":[{"role":"user","content":"..."}],"max_tokens":80}'
```

---

## Resume point for next session

1. **Vector store decision.** Blocks everything downstream. Options: inline
   FAISS (lightest, documented as suitable for single-node development RAG),
   inline Milvus (matches the conceptual architecture and the 2.25 build), or
   remote pgvector (reuses the PostgreSQL now deployed, one fewer component).
   ADR required.
2. **Embedding model decision.** Inline sentence-transformers via env vars, or
   served via vLLM (competes for the single GPU). ADR required.
3. **Wireframe the five demo views** (docs/demo-experience.md) before writing
   the pipeline: the views constrain the evidence record schema, and the schema
   constrains what the pipeline writes.
4. **Synthetic data.** Platform-independent, spec written, unblocked.
5. **Pipeline.** Ingestion, classification, evidence record.
6. **ADR-0003 (gateway)** still Draft. MaaS present as Gateway API; worth
   investigating once there is a workload to route.

Two automation gaps remain untested: the GPU pre-flight and the predictor
restart after seeding. Both were added after the rebuild test ran.

---

## Files changed this session

- `manifests/storage/postgres-deployment.yaml` (new)
- `secrets/postgres-secret.template.yaml` (new)
- `manifests/llama-stack/llamastackdistribution.yaml` (Postgres env, per docs)
- `manifests/storage/minio-deployment.yaml` (`strategy: Recreate`)
- `scripts/bootstrap.sh` (GPU pre-flight, `POSTGRES_PASSWORD` guard,
  `mlflowoperator` patch, Postgres rollout wait, Guard 8 rewrite, guard
  renumbering, stale NOTE removed)
- `ansible/roles/model_fetch/tasks/main.yml` (`--api s3v4`)
- `ansible/roles/seed_taxonomy/tasks/main.yml` (`uc02_namespace`)
- `secrets/inference-secret.template.yaml` (provider-prefix note)
- `docs/architecture.md` (validated baseline, deviations table, open decisions)
- `docs/demo-experience.md` (new)
- `docs/adrs/ADR-0004` (amended: telemetry observation retracted)
- `docs/adrs/ADR-0007-thin-application.md` (new)
- `REBUILD.md` (`POSTGRES_PASSWORD` export)
- this log
