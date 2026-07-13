# Deployment log: TO CAPTURE date (RHDP sandbox, TO CAPTURE GUID)

First live deployment of use case 02, Complaint Intelligence. Same discipline
as UC01: this log captures what actually happened, what changed from the
design, and exactly where to resume. Start filling it in from the first
command, not at the end of the session.

Cluster: RHDP sandbox, GUID TO CAPTURE, region TO CAPTURE, GPU node TO CAPTURE
RHOAI version: TO CAPTURE | OpenShift: TO CAPTURE

---

## Status at end of session

| Layer                                                | Status |
| ---------------------------------------------------- | ------ |
| Repo committed, bootstrap run                        |        |
| Argo CD present / fallback path used                 |        |
| Namespace + labelling                                |        |
| MinIO (plain Deployment)                             |        |
| Model seeded (Granite 3.3 8B, ~16GiB, the long pole) |        |
| ServingRuntime + InferenceService                    |        |
| Llama Stack distribution                             |        |
| Milvus round trip via Llama Stack                    |        |
| Guardrails orchestrator + regex detector             |        |
| Tracing located and exercised                        |        |
| Gateway / MaaS assessed                              |        |
| ADR-0002 / 0003 / 0004 drafted from findings         |        |

---

## Known validation items (from the manifests, check each explicitly)

| #   | Item                                                              | Where                                   | Expected / fallback                                                  | Result |
| --- | ----------------------------------------------------------------- | --------------------------------------- | -------------------------------------------------------------------- | ------ |
| V1  | RHAIIS image tag `3.2.5` still current                            | serving/servingruntime-vllm.yaml        | Current, else update tag                                             |        |
| V2  | `--served-model-name` accepted by this RHAIIS version             | serving/servingruntime-vllm.yaml        | Works; fallback: remove flag, set INFERENCE_MODEL=/mnt/models        |        |
| V3  | GPU product label `NVIDIA-L4` on this cluster                     | serving/inferenceservice-granite.yaml   | Matches; else fix nodeSelector (predictor Pending is the symptom)    |        |
| V4  | In-cluster MinIO Service endpoint accepted by storage initializer | serving/storage-secret.template.yaml    | Works; fallback documented in file: Route + https, render after sync |        |
| V5  | MinIO pinned image still pullable                                 | storage/minio-deployment.yaml           | Pulls; else bump pin                                                 |        |
| V6  | openshift-gitops present                                          | bootstrap output                        | Either answer fine; record which path ran                            |        |
| V7  | Llama Stack operator available and activatable                    | OperatorHub / DataScienceCluster        | Available; else ADR-0002 gap treatment                               |        |
| V8  | Distribution name `rh-dev` valid for this version                 | llama-stack/llamastackdistribution.yaml | Valid; else correct per version docs                                 |        |
| V9  | Inline Milvus env (`MILVUS_DB_PATH`) correct for this version     | llama-stack/llamastackdistribution.yaml | Correct; else adjust per version docs                                |        |
| V10 | pymilvus/marshmallow conflict sidestepped via Llama Stack?        | Milvus round trip                       | Either answer: note it and feed back to UC01 close-out               |        |
| V11 | TrustyAI operator + built-in detector sidecar available           | guardrails CRs                          | Available; else ADR-0002 gap treatment                               |        |
| V12 | Where traces land; span model supports ADR-0004 proposal          | tracing session                         | Supports; else amend ADR-0004                                        |        |
| V13 | MaaS / gateway capability present                                 | inventory                               | Determines ADR-0003 option                                           |        |

---

## What changed from the original design, and why

Numbered sections in UC01 format. For each: what was expected, what actually
happened, the fix, files affected. Nothing gets worked around without an
entry here.

### 1. TO CAPTURE

---

## Working endpoint reference

```
InferenceService URL:   TO CAPTURE
Llama Stack URL:        TO CAPTURE
Guardrails endpoint:    TO CAPTURE
Tracing UI/location:    TO CAPTURE
Model name in API call: granite-3-3-8b-instruct (or /mnt/models if V2 fallback used)
MinIO console route:    TO CAPTURE
```

Confirmed working test call(s):

```bash
# TO CAPTURE: the exact curl that worked, UC01 style
```

---

## Resume point for next session

1. TO CAPTURE
2. Remember the UC01 lesson: nothing persists across RHDP teardown; if the
   GUID changes, everything above reapplies from the repo (that being the
   point of the repo).

---

## Files that need committing

- Every manifest reality forced a change to (list them here as they change,
  not from memory afterwards)
- ADR-0002 / 0003 / 0004 status moves from Draft
- This log
