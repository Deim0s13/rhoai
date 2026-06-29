# RHOAI Presales Lab

A collection of self-contained, redeployable AI use cases built on
Red Hat OpenShift AI (RHOAI). Each use case is designed to be:

- **Reproducible** — rebuilt from scratch in a disposable environment
- **Documented** — handoff-ready without tribal knowledge
- **Relevant** — grounded in regulated industry scenarios, particularly financial services
- **Demo-ready** — structured to support customer conversations as well as personal learning

This repo is maintained by a Red Hat pre-sales architect. It is not an official
Red Hat product or reference architecture.

---

## How this repo is structured

Each use case lives in its own numbered directory and is fully self-contained.
All infrastructure, automation, and application code needed to deploy and run
the use case is inside that directory.

    rhoai/
    ├── README.md                    ← you are here
    ├── .gitignore
    └── 01-sovereign-rag/            ← use case 01
        ├── README.md                ← use case overview and deploy guide
        ├── manifests/               ← RHOAI platform manifests
        ├── gitops/                  ← Argo CD Applications
        ├── minio/                   ← MinIO Operator and Tenant manifests
        ├── terraform/               ← AWS bootstrap
        ├── ansible/                 ← post-deploy automation
        ├── notebooks/               ← Jupyter notebooks
        └── data/                    ← data provenance and download instructions

---

## Use cases

| # | Name | Status | Description |
|---|---|---|---|
| 01 | [Sovereign RAG](./01-sovereign-rag/README.md) | Ready | Air-gapped RAG pipeline on RHOAI using Granite and Milvus |
| 02 | InstructLab Fine-Tuning | Planned | Domain adaptation of Granite using InstructLab and RHOAI distributed training |
| 03 | Model Risk Monitoring | Planned | Model drift and bias monitoring using TrustyAI and RHOAI model monitoring |
| 04 | Agentic Fraud Detection | Planned | LLM-based anomaly reasoning pipeline linked to Ansible remediation |
| 05 | LLM Inference Benchmarking | Planned | vLLM throughput and latency benchmarking on OpenShift with NVIDIA L4 |

---

## Environment and lifecycle approach

### Environments are disposable — the repo is not

RHOAI environments are requested on demand and torn down after use.
Everything needed to reconstruct an environment must live in this repo.
Nothing should require manual steps that aren't documented.

### Lifecycle for each use case

Every use case follows the same four-phase lifecycle:

**Prepare** — done locally, no environment needed.
Design the architecture, author all manifests and automation, curate data,
and write the deploy sequence before requesting an environment.
Local tools (Ollama, iLab) can be used to validate logic where possible.

**Deploy** — target: environment usable in under 15 minutes.
All resources deploy declaratively. No manual dashboard clicks.
Follow the deploy steps in each use case README in order.

**Execute** — run the use case, validate outputs, record evidence.
This is the only phase that requires a live environment.
Demo scripts and queries are prepared in advance.

**Capture** — export notebooks, commit all changes, take screenshots,
then release the environment.
The repo reflects the completed state of the work.

### Tooling rationale

Each tool in this repo is used for what it is actually good at:

| Tool | Role |
|---|---|
| Terraform | Cloud infrastructure prerequisites outside the cluster |
| OpenShift GitOps / Argo CD | Declarative cluster state — operators and tenants |
| Kubernetes / RHOAI manifests | Platform resources — namespaces, workbenches, model serving |
| Ansible | Procedural post-deploy tasks — bucket seeding, credential configuration |
| Jupyter notebooks | Application layer — data pipelines and model interaction |

---

## Prerequisites

These tools must be available on your local machine before working with any use case.
Use case-specific prerequisites are documented in each use case README.

### Required

- `oc` CLI — authenticated to the target OpenShift cluster
- `git` — for cloning and committing
- `terraform` >= 1.6.0
- `ansible` with `community.aws` collection
- `aws` CLI — configured with sufficient permissions for the target account
- `envsubst` — for substituting environment variables into manifests (usually pre-installed on macOS/Linux)

### Required for use case 01

- `mc` — MinIO client, for post-deploy bucket operations
- `huggingface-cli` — for downloading Granite model weights
- A HuggingFace account and token with access to `ibm-granite/granite-3.1-8b-instruct`

### Install on macOS

    brew install openshift-cli terraform ansible awscli minio/stable/mc
    pip install huggingface_hub[cli]

---

## Credential management

No credentials are ever committed to this repo.

Manifests that require credentials use `envsubst` substitution and are applied
with environment variables set in the shell session. See the deploy steps in
each use case README for the exact commands.

AWS credentials for Ansible are stored in AWS SSM Parameter Store and
retrieved at runtime. Terraform provisions the SSM parameters as part of the
bootstrap step.

The `.gitignore` at the repo root excludes:

- `.env` files
- `*.tfvars` files
- Any file matching `*-credentials.yaml` or `*-secret.yaml`
- Model weight files (`.safetensors`, `.bin`, `.gguf`, `.pt`)
- Raw PDF documents (`data/raw/`)

If you believe a credential has been accidentally committed, rotate it
immediately — do not simply delete it from the repo history without also
rotating the credential.

---

## GPU and infrastructure

Use cases in this repo are developed and tested against:

- **Platform** — Red Hat OpenShift AI (RHOAI) on ROSA (AWS)
- **GPU** — NVIDIA L4 Tensor Core (24GB VRAM)
- **Instance family** — AWS `g6` series

Manifests include node selectors and tolerations for the NVIDIA L4.
If your environment uses a different GPU, verify the node label:

    oc get nodes -o json | jq '.items[].metadata.labels' | grep nvidia

Update the `nodeSelector` in the relevant InferenceService manifest
to match your cluster's reported label before deploying.

---

## Contributing and extending

This repo is structured to make it straightforward to add new use cases.
To add a new use case:

1. Create a new numbered directory following the existing naming convention
2. Copy the directory structure from an existing use case as a starting point
3. Write the use case README before writing any code
4. Follow the four-phase lifecycle — Prepare first, deploy second
5. Update the use cases table in this README

---

## References

- [Red Hat OpenShift AI documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)
- [AI on OpenShift community hub](https://ai-on-openshift.io)
- [MinIO Operator documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [Granite model family — HuggingFace](https://huggingface.co/ibm-granite)
- [vLLM documentation](https://docs.vllm.ai)
- [Milvus documentation](https://milvus.io/docs)
