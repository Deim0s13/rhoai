# Use Case 02: Complaint Intelligence

AI-assisted complaint theme and root-cause classification for a financial services
organisation, built as a **governed workload** on Red Hat OpenShift AI.

**Status: built and validated.** The full pipeline runs end to end on RHOAI 3.4.2,
rebuildable from this repository. Optional Models-as-a-Service phases (ADR-0003)
add token budgets, identity-based access and cost attribution. See
[REBUILD.md](REBUILD.md) to build it and
[docs/demos/PRESENTING.md](docs/demos/PRESENTING.md) to demonstrate it.

## What this use case demonstrates

Financial services organisations hold large volumes of complaint data that is rich in
signal but inconsistent in structure. Teams categorise complaints differently, themes
are identified manually or not at all, and systemic issues surface late. This use case
demonstrates a retrieval-augmented classification pipeline that:

- ingests unstructured complaint records and parses them into consistent, analysable text
- classifies each complaint against a standardised theme and root-cause taxonomy
- attaches a confidence score and a verified citation to the source text for every classification
- routes genuinely uncertain cases to human review instead of guessing
- aggregates individual records into theme trends and cross-theme root cause analysis
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

## Getting started

| I want to...                             | Read                                                 |
| ---------------------------------------- | ---------------------------------------------------- |
| Build the environment                    | [REBUILD.md](REBUILD.md)                             |
| Demonstrate it to an audience            | [docs/demos/PRESENTING.md](docs/demos/PRESENTING.md) |
| Understand the architecture              | [docs/architecture.md](docs/architecture.md)         |
| Understand why a decision was made       | [docs/adrs/](docs/adrs/)                             |
| Recover a broken environment             | [docs/runbooks/](docs/runbooks/)                     |
| See what went wrong and how it was fixed | [docs/deployment-logs/](docs/deployment-logs/)       |

## Stack

Validated live on RHOAI 3.4.2 (OpenShift 4.20, single node, single NVIDIA L4).

| Concern               | Component                                                    | Notes                                                 |
| --------------------- | ------------------------------------------------------------ | ----------------------------------------------------- |
| Platform              | Red Hat OpenShift AI 3.4.2 on OpenShift                      | RHDP-provisioned; also validated on 2.25.8            |
| Inference API         | Llama Stack                                                  | Unified API, OpenAI-native; Technology Preview on 3.4 |
| Model serving         | vLLM (Red Hat AI Inference Server) via KServe RawDeployment  | Self-hosted, single GPU                               |
| Model                 | Granite 3.3 8B Instruct                                      | Runs fully in-cluster; no external inference          |
| Guardrails            | TrustyAI                                                     | PII detection and redaction at the ingestion boundary |
| Vector store          | Inline Milvus, via Llama Stack                               | Opt-in on 3.4 (`ENABLE_INLINE_MILVUS`)                |
| Embeddings            | Inline sentence-transformers (`nomic-embed-text-v1.5`, 768d) | Opt-in on 3.4                                         |
| Metadata store        | PostgreSQL                                                   | Required by Llama Stack from RHOAI 3.2 onward         |
| Object storage        | MinIO                                                        | Complaints, evidence records, model weights           |
| Ingestion             | Docling                                                      | Structure-aware parsing of mixed-format records       |
| Governance (optional) | Kuadrant / MaaS                                              | Token budgets, API keys, cost attribution (ADR-0003)  |
| Delivery              | Ansible (procedural seeding), Argo CD where available        | Direct-apply fallback documented                      |

## Directory structure

02-complaint-intelligence/
├── README.md # this file
├── REBUILD.md # full build from a fresh cluster
├── docs/
│ ├── architecture.md # conceptual and validated architecture
│ ├── controls-alignment.md # capability-to-control mapping (build contract)
│ ├── demos/ # how to present this build
│ ├── adrs/ # architecture decision records
│ ├── runbooks/ # recovery procedures
│ └── deployment-logs/ # dated records of what broke and why
├── scripts/ # bootstrap and MaaS phase scripts
├── manifests/ # namespace, serving, storage, app, job, MaaS
├── secrets/ # envsubst templates (no credentials in Git)
├── ansible/ # post-deploy seeding
├── data/
│ ├── taxonomy/ # generic retail-banking theme and root-cause taxonomy
│ └── synthetic/ # generation scripts and fixtures
├── pipeline/ # shared classification module (ADR-0009)
├── notebooks/ # exploration and validation
└── app/ # demo application (five views)

## Design principles

Inherited from this lab as a whole:

- **Rebuildable from the repo.** No undocumented manual steps. The environment
  rebuilds from Git, and a rebuilt environment produces identical evidence.
- **No credentials in Git.** Secrets are injected via envsubst templates held
  outside any applyable path (ADR-0005).
- **Each tool for what it is genuinely good at.** GitOps for declarative state,
  Ansible for procedural tasks, a shared Python module for application logic.
- **First runs are validation exercises.** Platform-specific drift from
  documentation is expected, fixed, and recorded, not worked around silently.
- **Guards test the condition, not a correlate of it.** An idempotency check that
  passes on partial state turns a transient failure into a permanent one. Presence
  is not completeness; listability is not searchability.

Specific to this use case:

- **The controls matrix is a build contract.** Implementation decisions (span
  structure, output schema, mock-PII conventions, versioning discipline) are
  defined in [controls-alignment.md](docs/controls-alignment.md) and are not
  optional.
- **Customer-agnostic by construction.** Nothing in this repository names or
  identifies any organisation. Per-engagement tailoring lives outside the repo.
- **Demo honesty.** The application reports what it actually did, including
  checks that are not configured. It does not quietly correct or hide a model
  failure (ADR-0007). Quality claims belong to a measured proof of concept
  against a customer's own baseline, not to this demo.

## Synthetic data

All complaint records in this repository are synthetically generated. Any resemblance
to real complaints, individuals or organisations is coincidental. Mock PII patterns
are documented fixtures used to demonstrate guardrail behaviour and are obviously
fake by design.

The dataset is deliberately hard: 200 records across a six-month window, including
designed ambiguity where a reasonable reviewer could file either way, near-duplicates
across channels, PII carriers, injection fixtures, and a shaped upward trend on two
themes. A 60-record reference set carries ground-truth labels for theme and root
cause as an accuracy baseline.

## Relationship to the wider lab

This is the second use case in a structured presales lab on Red Hat OpenShift AI.
Use Case 01 (sovereign RAG) validated the platform foundations this use case builds
on: model serving via vLLM/KServe RawDeployment, MinIO object storage, GitOps
delivery, and the environment-specific fixes recorded in its README. Use Case 02
adds Llama Stack, TrustyAI guardrails, Docling ingestion, a governed model gateway,
and classification-as-a-pattern with structured, versioned, citation-linked output.
