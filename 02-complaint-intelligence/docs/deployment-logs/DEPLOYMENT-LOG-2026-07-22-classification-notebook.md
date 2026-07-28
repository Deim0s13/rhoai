# Deployment log: 2026-07-22 (RHDP sandbox, RHOAI 3.4.2)

First live run of the classification notebook (01-classify-complaint.ipynb),
against the environment validated on 2026-07-15. Purpose was to prove the
vertical slice end to end: one complaint in, one evidence record out. It
succeeded, but not before surfacing five new findings, three of them
genuinely consequential for anyone rebuilding this environment.

Cluster: same RHDP sandbox as the 2026-07-15 session, no rebuild this time.
RHOAI: 3.4.2 | Namespace: complaint-intelligence

---

## Status at end of session

| Layer                               | Status                                                       |
| ----------------------------------- | ------------------------------------------------------------ |
| Workbench (hand-applied manifest)   | Running, after fixes (see 1, 4)                              |
| Granite InferenceService            | Running, after fix (see 2)                                   |
| Llama Stack model discovery         | Working, after restart (see 3)                               |
| Classification notebook             | Runs clean end to end for one complaint, after fixes (see 5) |
| Retrieval (vector store)            | Routes confirmed present, not yet wired into the pipeline    |
| Workbench external access (Gateway) | BROKEN, controller bug (see 4); port-forward workaround used |

---

## Findings

### 1. `model_fetch` / predictor start is a race, not a sequence

**Expected:** the predictor pod starts only once its model weights are fully
present in MinIO.
**Happened:** the storage-initializer ran and reported success 12 hours
before the large `.safetensors` files finished uploading via `model_fetch`.
It faithfully copied everything that existed at that moment, small config
and tokenizer files only, and exited 0. vLLM then failed with
`RuntimeError: Cannot find any model weights with /mnt/models`, correctly,
since there were none.
**Fix applied:** deleted the predictor pod once the bucket was confirmed
complete; the storage-initializer re-ran against the now-full bucket and
succeeded.
**Implication:** nothing currently gates InferenceService startup on
`model_fetch` completion. On a slow upload (or a large model), this will
recur. Worth a guard, `model_fetch` should verify object sizes or an
explicit completion marker before the InferenceService is allowed to start,
rather than relying on upload speed outrunning pod scheduling by luck.

### 2. Llama Stack's model discovery does not appear to be live

**Expected:** `/v1/models` reflects the current state of registered
providers at any time it's queried.
**Happened:** with Granite in `FailedToLoad` at the time `lsd-complaint-
intelligence` last started, `/v1/models` continued returning only the
embedding model for the ~3 hours the pod had been running, even after
Granite's predictor was fixed and confirmed healthy independently.
Restarting the Llama Stack pod caused it to immediately discover Granite.
**Implication:** treat model discovery as startup-time, not continuous, on
this build. Any workflow (bootstrap, rebuild script, or this notebook's
instructions) that brings up model serving after Llama Stack has already
started should restart Llama Stack afterward, or explicitly document the
dependency order: Llama Stack should start last, once everything it depends
on is already healthy.

### 3. Hand-applied Notebook manifests produce a broken HTTPRoute on RHOAI 3.4.2

**Expected:** a `kubeflow.org/v1` Notebook object, applied via `oc apply`,
provisions working external access the same way a dashboard-created
workbench does.
**Happened:** the notebook controller auto-generates both a Service
(`port: 80`, `targetPort: 8888`, correct) and an `HTTPRoute`
(`backendRefs[].port: 8888`, incorrect, should reference the Service's
exposed port, 80) from the same reconcile. The mismatch produces
`cluster_not_found` at the Gateway (Envoy/Istio terminology: no endpoint
resolves for a Service port that doesn't exist) and a 500 on every request
to the workbench URL.
**Also found:** manually patching the HTTPRoute's port is not durable, the
controller reconciles it back to 8888 on its own schedule, independent of
any change to the Notebook object.
**Also found:** the dashboard's "migration required, image unknown, deleted"
message on the Workbenches tab is a separate, likely cosmetic symptom of the
same root cause, hand-applied Notebook objects lack an image reference the
dashboard's own tracking can resolve, distinct from the HTTPRoute bug but
easy to conflate with it.
**Workaround used:** `oc port-forward svc/<workbench-name> 8888:80`,
bypassing the Gateway/HTTPRoute path entirely. JupyterLab is then reachable
at `http://localhost:8888`, gated by a token (see Cell logs, not the
Gateway-level OAuth).
**Not yet fixed:** this needs either a genuine platform fix (worth filing as
a bug given how reproducible and well-understood the mechanism now is) or a
documented, permanent workaround in REBUILD.md. Every rebuild that hand-
applies the workbench manifest, rather than creating it via the dashboard,
will hit this.

### 4. Notebook object indentation is easy to get silently wrong

**Expected:** an `env` block added to the workbench manifest either applies
correctly or fails the `oc apply`.
**Happened:** `env` was nested one level too deep (a child of `resources`
rather than a sibling), which the Notebook CRD's schema validation silently
dropped rather than rejecting. `oc apply` reported success, the pod
restarted, and the environment variables were simply absent, discovered only
by explicitly checking `oc exec ... -- env`, not from any error message.
**Implication:** `oc apply` succeeding is not sufficient evidence that a
manifest change took effect as intended, particularly for fields a CRD's
schema doesn't strictly require. Worth checking the live object's actual
resolved spec after any manifest change to this Notebook CR specifically,
not just the apply exit code.

### 5. Two notebook bugs, both from assumptions not checked against the actual data/naming

**Bucket vs. alias:** the notebook's first draft used `MINIO_BUCKET = "uc02"`,
conflating the `mc` alias name (arbitrary, chosen locally when running
`mc alias set --api s3v4 uc02 ...`) with an actual bucket name. The real
buckets are `complaints` and `evidence`; `uc02` is not a bucket and never
was. Fixed by splitting into `COMPLAINTS_BUCKET` and `EVIDENCE_BUCKET`.

**Field name:** the notebook assumed complaint records carried a `text`
field. `generate.py`'s actual `public_fields` list (`complaint_id`,
`channel`, `received_date`, `body`) confirms the field is `body`. Fixed
across all cells that read the complaint content.

**Implication:** neither of these was caught by any validation step before
live testing, both were plausible-sounding assumptions that happened to be
wrong. Worth a brief schema comment at the top of any future ingestion code
pointing directly at `generate.py`'s `public_fields` definition as the
source of truth, rather than each new consumer re-guessing the shape.

### 6. Vector store file listing paginates at 20 with a silently-ignored `limit`

**Expected:** `GET /v1/vector_stores/{id}/files` returns all attached files,
or at least respects a `limit` query parameter to expand the page.
**Happened:** defaults to 20 results per page; passing `limit=250` was
silently ignored (returned 0 results, not an error). The real pagination
mechanism is a cursor: pass `after=<last_file_id_from_previous_page>` to
get the next page.
**Implication:** any code listing vector store files (population idempotency
checks, admin/debug tooling) must paginate properly via `after`/`has_more`,
not assume a single call returns everything. Two findings now share this
shape (this one, and the filters flat-dict issue): parameters that don't
match this API's actual expected schema tend to fail silently rather than
with an error, worth treating with suspicion generally on this stack.

---

## Working endpoint reference (addendum to 2026-07-15)

\## Addendum: automation fixes validated live

Both fixes from the "resume point" above were implemented and tested in the
same session, not left as untested proposals:

- `model_fetch`'s new predictor-readiness guard correctly skipped restarting
  an already-healthy predictor (idempotent, as intended).
- `sync_llama_stack` restarted Llama Stack and it discovered Granite
  without any manual intervention.
- Full notebook re-run (`01-classify-complaint.ipynb`, Cells 1-11) completed
  with no errors, no manual restarts, no live debugging. First genuinely
  clean unattended run this session.

Status table above should read: workbench access, model serving, and
notebook execution all now reproducible from `ansible-playbook
ansible/site.yml` alone, no follow-up commands required.
