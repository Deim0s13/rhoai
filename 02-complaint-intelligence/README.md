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
