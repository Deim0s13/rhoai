# Workbench setup guide

This guide walks through configuring the RHOAI workbench for use case 01
before running the notebooks. Complete all steps before opening a notebook.

---

## Overview

The notebooks require environment variables to connect to MinIO and Milvus,
and to reach the Granite InferenceService. These are set in the RHOAI
workbench configuration — not in the notebooks themselves.

Setting credentials as workbench environment variables means:

- No credentials appear in notebook code or output
- Notebooks are safe to commit to git
- Variables persist across notebook sessions for the lifetime of the workbench

---

## Step 1 — Confirm the deployment is ready

Before configuring the workbench, verify the dependent services are running.
Run these commands from a terminal authenticated to the cluster:

    # Namespace and core resources
    oc get pods -n sovereign-rag

    # MinIO tenant — should show Running
    oc get tenant sovereign-rag-minio -n sovereign-rag

    # Milvus — should show Running
    oc get pods -n sovereign-rag -l app=milvus

    # InferenceService — READY column should show True
    oc get inferenceservice granite-instruct -n sovereign-rag

Do not proceed until all services are healthy. The InferenceService in
particular can take 3–5 minutes to reach Ready state after the model
weights have loaded from MinIO.

---

## Step 2 — Retrieve the values you need

You will need the following values before configuring the workbench.
Retrieve them now and keep them to hand.

### MinIO endpoint

    oc get route -n sovereign-rag -l app=milvus -o jsonpath='{.items[0].spec.host}'

If no route exists, use the internal service URL:

    echo "http://minio.sovereign-rag.svc.cluster.local:9000"

### MinIO credentials

Retrieve from AWS SSM — these were set by the Ansible post-deploy step:

    aws ssm get-parameter \
      --name "/presales-lab/YOUR_CLUSTER_NAME/minio/access-key" \
      --query "Parameter.Value" --output text

    aws ssm get-parameter \
      --name "/presales-lab/YOUR_CLUSTER_NAME/minio/secret-key" \
      --with-decryption \
      --query "Parameter.Value" --output text

Replace `YOUR_CLUSTER_NAME` with the value used during Terraform bootstrap.

### Granite InferenceService URL

    oc get inferenceservice granite-instruct -n sovereign-rag \
      -o jsonpath='{.status.url}'

### Inference bearer token

In the RHOAI dashboard, navigate to:

    Data Science Projects → sovereign-rag → Models → granite-instruct

Select the model, then expand **Token authentication**. Copy the token value.

Alternatively, retrieve it via CLI:

    oc get secret -n sovereign-rag \
      -l serving.knative.openshift.io/service=granite-instruct \
      -o jsonpath='{.items[0].data.token}' | base64 -d

---

## Step 3 — Open the workbench

1. Log in to the RHOAI dashboard
2. Navigate to **Data Science Projects**
3. Select the **sovereign-rag** project
4. Under **Workbenches**, find **sovereign-rag-workbench**
5. If the workbench is stopped, click **Start** and wait for it to reach Running state
6. Click **Open** to launch JupyterLab

---

## Step 4 — Set environment variables

Environment variables are configured before the workbench starts, not inside
JupyterLab. If the workbench is already running, you will need to stop it,
update the variables, and restart it.

### In the RHOAI dashboard

1. Navigate to **Data Science Projects → sovereign-rag → Workbenches**
2. Click the three-dot menu next to **sovereign-rag-workbench**
3. Select **Edit workbench**
4. Scroll down to **Environment variables**
5. Add each variable below using **Add variable**

### Variables to set

| Variable | Type | Value |
|---|---|---|
| `MINIO_ENDPOINT` | Config map | MinIO endpoint retrieved in Step 2 |
| `MINIO_BUCKET` | Config map | `documents` |
| `MINIO_USE_SSL` | Config map | `false` (unless your MinIO route uses TLS) |
| `MILVUS_HOST` | Config map | `milvus.sovereign-rag.svc.cluster.local` |
| `MILVUS_PORT` | Config map | `19530` |
| `INFERENCE_ENDPOINT` | Config map | InferenceService URL retrieved in Step 2 |
| `MINIO_ACCESS_KEY` | Secret | MinIO access key retrieved in Step 2 |
| `MINIO_SECRET_KEY` | Secret | MinIO secret key retrieved in Step 2 |
| `INFERENCE_TOKEN` | Secret | Bearer token retrieved in Step 2 |

Use **Config map** type for non-sensitive values.
Use **Secret** type for credentials — RHOAI will store these in a Kubernetes
Secret rather than a ConfigMap, which is the correct handling for sensitive data.

6. Click **Update workbench**
7. The workbench will restart. Wait for it to return to Running state.

---

## Step 5 — Verify environment variables in JupyterLab

Once the workbench is running, open a terminal in JupyterLab
(**File → New → Terminal**) and confirm the variables are present:

    env | grep -E "MINIO|MILVUS|INFERENCE"

You should see all nine variables listed. If any are missing, return to
Step 4 and check the workbench environment variable configuration.

Do not proceed to the notebooks if variables are missing — the notebooks
will fail immediately with a `KeyError` on the missing variable.

---

## Step 6 — Upload notebooks

If the notebooks are not already present in the workbench:

1. In JupyterLab, click the **Upload** button (arrow icon) in the file browser
2. Upload both notebooks from your local clone of this repo:
   - `01-sovereign-rag/notebooks/01-ingest-and-embed.ipynb`
   - `01-sovereign-rag/notebooks/02-rag-query.ipynb`

If you have the repo cloned and accessible from the workbench (e.g. via a
persistent volume or git clone), you can also clone directly:

    cd /opt/app-root/src
    git clone https://github.com/Deim0s13/rhoai.git
    cd rhoai/01-sovereign-rag/notebooks

---

## Step 7 — Run the notebooks

Run notebooks in order. Do not run notebook 02 before notebook 01 has
completed successfully.

### Notebook 01 — ingest-and-embed

1. Open `01-ingest-and-embed.ipynb`
2. Run cells in sequence from top to bottom
3. Cell 1 installs dependencies — this takes 1–2 minutes on first run
4. Cell 3 downloads PDFs from MinIO — confirm files appear in the output
5. Cell 10 runs a verification query against Milvus — confirm results are returned
6. Cell 11 cleans up temporary files

Expected total runtime: 5–15 minutes depending on corpus size and CPU speed.

### Notebook 02 — rag-query

1. Open `02-rag-query.ipynb`
2. Run cells in sequence from top to bottom
3. Cell 1 installs dependencies
4. Cell 4 verifies the Granite model is reachable — check the model name output
5. Cells 7, 8, and 9 run example queries — review outputs for quality
6. Cell 9 (retrieval diagnostic) shows raw Milvus results without LLM generation

Expected total runtime: 2–3 minutes to set up, then interactive.

---

## Troubleshooting

### Milvus connection refused

Confirm Milvus is running and the service name is correct:

    oc get svc -n sovereign-rag | grep milvus

The `MILVUS_HOST` variable should match the service name exactly.
If the workbench is in the same namespace (`sovereign-rag`), the short
hostname `milvus` will resolve. If in a different namespace, use the
fully qualified name `milvus.sovereign-rag.svc.cluster.local`.

### InferenceService returns 401 Unauthorized

The bearer token has likely expired or was copied incorrectly.
Retrieve a fresh token following Step 2 and update the `INFERENCE_TOKEN`
workbench environment variable.

### Model name not found in Cell 4 of notebook 02

vLLM serves the model under the name of the directory it was loaded from.
Run the following to see what name vLLM is reporting:

    curl -s $(oc get inferenceservice granite-instruct -n sovereign-rag \
      -o jsonpath='{.status.url}')/v1/models \
      -H "Authorization: Bearer YOUR_TOKEN" | python3 -m json.tool

Update `MODEL_NAME` in notebook 02 Cell 2 to match the reported name.

### InferenceService not reaching Ready state

The most common causes are:

- Model weights not fully seeded to MinIO — check Ansible completed successfully
- GPU node not available or node selector label mismatch — verify with:

        oc get nodes -o json | jq '.items[].metadata.labels' | grep nvidia

- Insufficient GPU memory — confirm `--gpu-memory-utilization=0.85` is set
  in `04-inference-service.yaml` and that no other InferenceService is
  consuming GPU on the same node

### Notebook 01 finds no PDFs in MinIO

The Ansible seeding step did not complete or failed silently. Verify:

    mc ls sovereign-rag/documents

If the bucket is empty, re-run the Ansible playbook:

    AWS_REGION=us-east-1 \
    CLUSTER_NAME=your-cluster \
      ansible-playbook ansible/configure-minio.yaml --tags seed-documents

---

## Optional — pre-built workbench image

Installing dependencies via `pip install` in Cell 1 of each notebook adds
1–2 minutes to every session start. For repeated use or demos where startup
time matters, consider building a custom workbench image with the dependencies
pre-installed.

A `requirements.txt` covering all notebook dependencies is at:

    01-sovereign-rag/notebooks/requirements.txt

A custom image Dockerfile would extend the RHOAI base image:

    FROM quay.io/opendatahub/notebooks:jupyter-datascience-ubi9-python-3.11-2024b
    COPY requirements.txt /tmp/requirements.txt
    RUN pip install --no-cache-dir -r /tmp/requirements.txt

Build, push to a registry accessible from your cluster, and register the
image in the RHOAI dashboard under **Settings → Notebook images**.
Update `05-workbench.yaml` to reference the new image tag.
