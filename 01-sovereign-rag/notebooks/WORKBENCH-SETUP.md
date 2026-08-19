# Workbench setup guide

This guide walks through preparing and running the RHOAI workbench for
use case 01 on RHOAI 3.4. Read it before opening JupyterLab.

---

## What changed from the original guide

This guide replaces an earlier version written during the UC01 live session
on RHOAI 2.25.8. The key differences on RHOAI 3.4:

- **Environment variables are now baked into `05-workbench.yaml`** — no
  manual patching via the dashboard or `oc patch` is required. Applying
  the manifest is sufficient.
- **No bearer token is required** — this deployment uses KServe
  RawDeployment mode, which does not involve Knative or Service Mesh
  authentication. The `INFERENCE_TOKEN` variable is not set.
- **The inference endpoint format changed** — on RHOAI 3.4, KServe
  RawDeployment creates a headless predictor service (ClusterIP: None).
  In-cluster clients must target the container port (`:8080`) directly.
  The earlier format targeting service port `:80` does not work on 3.4.
- **Credentials are sourced from a Secret**, not AWS SSM — the Terraform
  and SSM credential retrieval path from the original design does not apply
  to RHDP sandbox environments.

---

## Prerequisites

Before applying the workbench manifest, the `workbench-credentials` Secret
must exist in the namespace. Apply it once with your chosen credentials:

    oc create secret generic workbench-credentials \
      -n sovereign-rag \
      --from-literal=MINIO_ACCESS_KEY=<your-minio-access-key> \
      --from-literal=MINIO_SECRET_KEY=<your-minio-secret-key>

These are the same credentials used when deploying MinIO. If you have
already deployed MinIO and forgotten the credentials, retrieve them from
the cluster:

    oc get secret minio-tenant-credentials -n sovereign-rag \
      -o jsonpath='{.data.accesskey}' | base64 -d && echo
    oc get secret minio-tenant-credentials -n sovereign-rag \
      -o jsonpath='{.data.secretkey}' | base64 -d && echo

---

## Step 1 — Confirm the deployment is ready

Verify all dependent services are running before starting the workbench:

    # All pods in the namespace
    oc get pods -n sovereign-rag

    # Milvus — should show Running
    oc get pods -n sovereign-rag -l app=milvus

    # InferenceService — READY column should show True
    oc get inferenceservice granite-instruct -n sovereign-rag

    # MinIO buckets populated
    mc ls sovereign-rag/models/granite-3.3-8b-instruct | head -5
    mc ls sovereign-rag/documents

Do not proceed until all services are healthy. The InferenceService in
particular takes 3–5 minutes to reach Ready state while the storage
initializer pulls ~15GiB of model weights from MinIO and vLLM loads them
into GPU memory.

---

## Step 2 — Confirm the workbench image tag

The workbench manifest uses a version tag (`2025.2`) rather than a pinned
SHA, because the correct SHA differs between RHOAI versions. On first
deploy, confirm the image resolves correctly by getting the SHA-pinned
reference from the cluster's own imagestream and updating the manifest:

    oc get imagestream jupyter-datascience-cpu-py312-ubi9 \
      -n redhat-ods-applications \
      -o jsonpath='{.status.tags[?(@.tag=="2025.2")].items[0].dockerImageReference}'

If the `2025.2` tag does not exist, list available tags and use the most
recent one:

    oc get imagestream jupyter-datascience-cpu-py312-ubi9 \
      -n redhat-ods-applications \
      -o jsonpath='{.status.tags[*].tag}'

Update the `image:` field in `manifests/05-workbench.yaml` with the
SHA-pinned reference before applying. Using the internal registry
reference is preferred over external Quay tags — it is guaranteed pullable
on the cluster regardless of external registry availability.

---

## Step 3 — Apply the workbench manifest

    oc apply -f manifests/05-workbench.yaml

Watch it come up:

    oc get pods -n sovereign-rag | grep workbench

The pod name follows the pattern `sovereign-rag-workbench-0`. Status
`2/2 Running` confirms both the notebook container and the OAuth proxy
sidecar are healthy.

---

## Step 4 — Verify environment variables

Confirm the variables landed correctly before opening JupyterLab. This
avoids discovering missing variables partway through a notebook run:

    oc exec -n sovereign-rag sovereign-rag-workbench-0 \
      -c sovereign-rag-workbench -- env | grep -E "MINIO|MILVUS|INFERENCE"

You should see the following variables:

| Variable             | Expected value                                                           |
| -------------------- | ------------------------------------------------------------------------ |
| `MINIO_ENDPOINT`     | `minio.sovereign-rag.svc.cluster.local:9000`                             |
| `MINIO_BUCKET`       | `documents`                                                              |
| `MINIO_USE_SSL`      | `false`                                                                  |
| `MINIO_ACCESS_KEY`   | your chosen access key                                                   |
| `MINIO_SECRET_KEY`   | your chosen secret key                                                   |
| `MILVUS_HOST`        | `milvus.sovereign-rag.svc.cluster.local`                                 |
| `MILVUS_PORT`        | `19530`                                                                  |
| `INFERENCE_ENDPOINT` | `http://granite-instruct-predictor.sovereign-rag.svc.cluster.local:8080` |

If any are missing, confirm the `workbench-credentials` Secret exists and
that the manifest was applied successfully. Additional `MINIO_*` and
`MILVUS_*` entries from Kubernetes service discovery are expected and
harmless.

---

## Step 5 — Open JupyterLab

Get the workbench URL:

    oc get route -n sovereign-rag | grep workbench

Open the URL in your browser and log in via OpenShift OAuth. If prompted
for a notebook token, retrieve it from the running pod:

    oc exec -n sovereign-rag sovereign-rag-workbench-0 \
      -c sovereign-rag-workbench -- jupyter server list

Set a browser session password when prompted — this protects the JupyterLab
session and is only required once per browser session.

---

## Step 6 — Clone the repo and open the notebooks

In JupyterLab, open a terminal (**File → New → Terminal**) and clone the
repo into the persistent volume:

    git clone https://github.com/Deim0s13/rhoai.git /opt/app-root/src/rhoai

Navigate to the notebooks directory in the left-hand file browser:

    /opt/app-root/src/rhoai/01-sovereign-rag/notebooks/

Open `01-ingest-and-embed.ipynb`. Do not open notebook 02 until notebook
01 has completed successfully.

---

## Step 7 — Run the notebooks

Run all cells in sequence from top to bottom. Do not skip cells or run
them out of order.

### Notebook 01 — ingest-and-embed

Runs once per environment, or when the document corpus changes.

| Cell | What it does                            | Watch for                                               |
| ---- | --------------------------------------- | ------------------------------------------------------- |
| 1    | Install dependencies                    | All packages install cleanly — takes 1–2 min            |
| 2    | Load configuration                      | All variables print correctly                           |
| 3    | Download PDFs from MinIO                | Both PDFs appear in the output                          |
| 4    | Parse and chunk PDFs                    | Total chunks reported (expect ~300–400 for 2 docs)      |
| 5    | Load embedding model                    | Model downloads from HuggingFace — takes ~30s first run |
| 6    | Generate embeddings                     | Progress bar completes without error                    |
| 7    | Connect to Milvus and create collection | "Created collection" or "Using existing collection"     |
| 8    | Insert vectors                          | Total vectors inserted matches chunk count              |
| 9    | Build index                             | "Index built and collection loaded into memory"         |
| 10   | Verification query                      | Top 3 results returned with source citations            |
| 11   | Cleanup                                 | Temp directory removed                                  |

Expected total runtime: 5–15 minutes.

**Important — kernel restart if pymilvus import fails:** if Cell 7 raises
an `AttributeError` related to `marshmallow`, restart the kernel
(**Kernel → Restart Kernel**) and re-run from Cell 1. The install in Cell 1
must complete before the kernel loads the packages into memory.

### Notebook 02 — rag-query

Run after notebook 01 has completed successfully.

| Cell | What it does          | Watch for                                          |
| ---- | --------------------- | -------------------------------------------------- |
| 1    | Install dependencies  | All packages install cleanly                       |
| 2    | Load configuration    | `MODEL_NAME` should show `granite-3-3-8b-instruct` |
| 3    | Connect to Milvus     | Vector count matches what notebook 01 inserted     |
| 4    | Connect to Granite    | Model listed as `granite-3-3-8b-instruct`          |
| 5    | Define RAG pipeline   | Functions defined without error                    |
| 6    | Define display helper | Function defined without error                     |
| 7–9  | Example queries       | Coherent, grounded answers with source citations   |

Expected total runtime: 2–3 minutes to set up, then interactive.

---

## Smoke test before running notebooks

Once the InferenceService is `READY: True`, verify the model endpoint is
reachable directly before starting the notebooks. This confirms the serving
layer is working independently of the notebook stack:

    POD=$(oc get pods -n sovereign-rag \
      -l serving.kserve.io/inferenceservice=granite-instruct \
      -o jsonpath='{.items[0].metadata.name}')

    oc port-forward -n sovereign-rag $POD 8081:8080

In a separate terminal:

    curl -s http://localhost:8081/v1/models | python3 -m json.tool

A response listing `granite-3-3-8b-instruct` confirms the serving layer is
working. Then run a generation test:

    curl -s http://localhost:8081/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model": "granite-3-3-8b-instruct", "messages": [{"role": "user", "content": "What is capital adequacy in banking, in one sentence?"}], "max_tokens": 100}' \
      | python3 -m json.tool

A coherent answer confirms end-to-end model serving before the notebooks
add Milvus and embedding into the picture.

---

## Troubleshooting

### Workbench pod stays Pending

Most likely the workbench image tag could not be resolved. Check:

    oc describe pod sovereign-rag-workbench-0 -n sovereign-rag | grep -A5 Events

If you see an `ImagePullBackOff` or `ErrImagePull` event, update the image
field in `05-workbench.yaml` with the correct SHA-pinned reference per
Step 2, delete the existing Notebook CR and PVC, and reapply:

    oc delete notebook sovereign-rag-workbench -n sovereign-rag
    oc delete pvc sovereign-rag-workbench-pvc -n sovereign-rag
    oc apply -f manifests/05-workbench.yaml

### Environment variables are missing

Confirm the `workbench-credentials` Secret exists:

    oc get secret workbench-credentials -n sovereign-rag

If it is missing, create it per the Prerequisites section and restart the
workbench pod:

    oc delete pod sovereign-rag-workbench-0 -n sovereign-rag

### pymilvus import fails with AttributeError on marshmallow

This is a known Python 3.12 package version conflict. Restart the kernel
(**Kernel → Restart Kernel**) and re-run Cell 1 before retrying Cell 7.
If the error persists after a restart, open a JupyterLab terminal and run:

    pip install pymilvus==2.5.4 --force-reinstall
    pip install "marshmallow>=3.13,<4.0" --force-reinstall

Then restart the kernel again.

### InferenceService stays at READY: False

Check the predictor pod status and logs:

    oc get pods -n sovereign-rag -l serving.kserve.io/inferenceservice=granite-instruct
    oc logs -n sovereign-rag <pod-name> -c storage-initializer

Common causes:

- **Model weights not in MinIO** — run `mc ls sovereign-rag/models/granite-3.3-8b-instruct`
  and confirm files are present with realistic sizes. If empty, re-run the
  Ansible seeding step.
- **GPU node not available** — confirm the node label matches the nodeSelector:

      oc get nodes -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.product"]' | grep -v null

- **Another workload is holding the GPU** — RHDP catalog items sometimes
  ship a sample model (`my-first-model`) that claims the GPU. Check for
  competing InferenceServices and delete them if present.

### Model name not found in notebook 02 Cell 4

Run the `/v1/models` check via port-forward (see Smoke test above) to see
what name vLLM is actually reporting. Update `MODEL_NAME` in Cell 2 of
notebook 02 to match exactly. The correct name is set via
`--served-model-name` in `manifests/03-model-serving-runtime.yaml`.

### Inference endpoint connection refused in notebook 02

On RHOAI 3.4, the predictor service is headless (ClusterIP: None). The
`INFERENCE_ENDPOINT` must include `:8080` — the service has no port
translation layer. Confirm the variable value:

    oc exec -n sovereign-rag sovereign-rag-workbench-0 \
      -c sovereign-rag-workbench -- env | grep INFERENCE_ENDPOINT

Expected: `http://granite-instruct-predictor.sovereign-rag.svc.cluster.local:8080`

If it shows port `:80` or no port, the manifest was not updated correctly.
Delete the workbench pod so it restarts with the correct variable:

    oc delete pod sovereign-rag-workbench-0 -n sovereign-rag

---

## Optional — pre-built workbench image

Installing dependencies via Cell 1 adds 1–2 minutes to every session start.
For frequent use or demos where startup time matters, build a custom image
with dependencies pre-installed. Use `notebooks/requirements.txt` as the
source:

    FROM registry.redhat.io/rhoai/odh-workbench-jupyter-datascience-cpu-py312-rhel9:2025.2
    COPY requirements.txt /tmp/requirements.txt
    RUN pip install --no-cache-dir -r /tmp/requirements.txt

Build and push to a registry the cluster can pull from, then update the
`image:` field in `manifests/05-workbench.yaml` to reference the new image.
