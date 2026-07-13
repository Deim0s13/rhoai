# Use Case 02: Complaint Intelligence

AI-assisted complaint theme and root-cause classification for a financial services
organisation, built as a **governed workload** on Red Hat OpenShift AI.

**Status: in design.** The controls matrix and architecture are defined; platform
validation and build have not yet started. See [Open decisions](docs/architecture.md#open-decisions).

## What this use case demonstrates

Financial services organisations hold large volumes of complaint data that is rich in
signal but inconsistent in structure. Teams categorise complaints differently, themes
are identified manually or not at all, and systemic issues surface late. This use case
demonstrates a retrieval-augmented classification pipeline that:

- ingests unstructured complaint records and parses them into consistent, analysable text
- classifies each complaint against a standardised theme and root-cause taxonomy
- attaches a confidence score and a citation to the source text for every classification
- routes low-confidence cases to human review instead of guessing
- produces the audit evidence a regulated organisation needs, by construction

The distinguishing feature is not the RAG pattern itself. It is that the workload is
built from the start as a **governed** workload: every capability maps to a
platform-level AI governance control. That mapping is the core design artefact of
this use case: [Controls Alignment Matrix](docs/controls-alignment.md).

This use case is designed to pair with a horizontal AI control-plane evaluation
(gateway, guardrails, evidence layers). Where both are shown together, the control
plane explains the evidence trail and this workload generates it.

## Pattern classification

System-to-LLM, non-agentic, no direct customer interaction. Complaints flow in,
structured intelligence flows out, and humans stay in the loop for decisions. This is
one of the lowest-risk, highest-leverage categories of enterprise generative AI
adoption: the failure modes are measurable classification errors, not customer-facing
incidents.

## Stack

| Concern                | Component                                       | Notes                                                                         |
| ---------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| Platform               | Red Hat OpenShift AI on OpenShift               | RHDP-provisioned environment for the demo                                     |
| Inference API          | Llama Stack                                     | Unified API; model selection by configuration                                 |
| Model serving          | vLLM (Red Hat AI Inference Server)              | Self-hosted open model, single GPU                                            |
| Model                  | Granite 3.x 8B Instruct (or catalog equivalent) | Demo runs fully in-cluster; no external inference                             |
| Guardrails             | TrustyAI                                        | PII detection/redaction on inputs and outputs                                 |
| Vector store           | Milvus                                          | Via Llama Stack                                                               |
| Ingestion              | Docling                                         | Structure-aware parsing of complaint records                                  |
| Tracing and evaluation | MLflow (platform-embedded)                      | Span structure per the controls matrix; pending alignment, see open decisions |
| Delivery               | Argo CD (GitOps), Ansible (procedural seeding)  | Follows the conventions established in Use Case 01                            |

## Directory structure

```
02-complaint-intelligence/
├── README.md                  # this file
├── docs/
│   ├── architecture.md        # conceptual and demo architecture
│   ├── controls-alignment.md  # capability-to-control mapping (build contract)
│   ├── demo-guide.md          # environment, build steps, demo flow (pending)
│   └── adrs/                  # architecture decision records for this use case
├── gitops/                    # Argo CD Applications
├── manifests/                 # namespace, serving, storage manifests
├── ansible/                   # post-deploy seeding (taxonomy, synthetic data, policies)
├── data/
│   ├── taxonomy/              # generic retail-banking theme and root-cause taxonomy
│   └── synthetic/             # generation scripts and fixture conventions
├── pipelines/                 # ingestion, embedding, classification
├── notebooks/                 # exploration and validation notebooks
└── app/                       # thin demo UI
```

## Design principles

Inherited from this lab as a whole:

- **Rebuildable from the repo.** No undocumented manual steps. The environment
  rebuilds from Git, and a rebuilt environment produces identical evidence.
- **No credentials in Git.** Secrets are injected via environment variables at
  deploy time.
- **Each tool for what it is genuinely good at.** GitOps for declarative state,
  Ansible for procedural tasks, pipelines and notebooks for application logic.
- **First runs are validation exercises.** Platform-specific drift from
  documentation is expected, fixed, and recorded, not worked around silently.

Specific to this use case:

- **The controls matrix is a build contract.** Implementation decisions (span
  structure, output schema, mock-PII conventions, versioning discipline) are
  defined in [controls-alignment.md](docs/controls-alignment.md) and are not
  optional.
- **Customer-agnostic by construction.** Nothing in this repository names or
  identifies any organisation. Per-engagement tailoring lives outside the repo.
- **Demo honesty.** The demo runs a small open model in-cluster. It demonstrates
  architecture and controls, not frontier-model classification quality. Quality
  claims belong to a measured proof of concept against a customer's own baseline,
  not to this demo.

## Synthetic data

All complaint records in this repository are synthetically generated. Any resemblance
to real complaints, individuals or organisations is coincidental. Mock PII patterns
are documented fixtures used to demonstrate guardrail behaviour and are obviously
fake by design.

## Relationship to the wider lab

This is the second use case in a structured presales lab on Red Hat OpenShift AI.
Use Case 01 (sovereign RAG) validated the platform foundations this use case builds
on: model serving via vLLM/KServe RawDeployment, MinIO object storage, GitOps
delivery, and the environment-specific fixes recorded in its README. Use Case 02
adds Llama Stack, TrustyAI guardrails, Docling ingestion, and
classification-as-a-pattern with structured, versioned, citation-linked output.
