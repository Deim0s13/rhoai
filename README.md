# Red Hat OpenShift AI Presales Lab

A structured, hands-on lab for building and demonstrating enterprise AI patterns on
Red Hat OpenShift AI (RHOAI), with a focus on the realities of regulated industries
such as financial services.

This is a personal learning and demonstration project. It is not an official
Red Hat offering, reference architecture or supported product. Opinions and
design choices are my own.

---

## What this repository is

Each use case in this lab is a complete, self-contained build: infrastructure as
code, deployment automation, application logic, documentation and the lessons
learned from running it against a live environment. The lab exists to do three
things at once:

1. **Prove patterns.** Each use case demonstrates a distinct enterprise AI pattern
   on RHOAI, built the way a regulated organisation would need it built: governed,
   auditable and rebuildable.
2. **Capture reality.** Documentation and vendor examples drift from what live
   environments actually do. Every use case records where reality deviated from
   expectation and what fixed it, so the next build starts further ahead.
3. **Stay reusable.** Everything here is organisation-agnostic. No customer names,
   no engagement-specific detail, no credentials. Per-engagement tailoring lives
   outside this repository by design.

---

## Use cases

The five use cases in this lab are chosen to tell a coherent platform story across
five distinct buyer personas in a regulated financial services organisation. Each one
introduces RHOAI capabilities the previous use cases have not yet exercised, so the
lab builds progressively rather than repeating the same pattern.

| #   | Use case                                                            | Pattern                     | Primary audience                | Status                                                                    |
| --- | ------------------------------------------------------------------- | --------------------------- | ------------------------------- | ------------------------------------------------------------------------- |
| 01  | [Sovereign RAG](#uc01--sovereign-rag)                               | Air-gapped RAG              | CISO, Compliance                | Validated on RHOAI 2.25.8. Updated for 3.4, awaiting first 3.4 validation |
| 02  | [Complaint Intelligence](#uc02--complaint-intelligence)             | Governed RAG classification | CCO, Risk, Compliance           | Substantially complete and validated on RHOAI 3.4                         |
| 03  | [Regulatory Change Management](#uc03--regulatory-change-management) | RAG, impact assessment      | CRO, Compliance, Legal          | Planned                                                                   |
| 04  | [Model Risk Governance](#uc04--model-risk-governance)               | Platform governance         | CRO, Model Risk, Internal Audit | Planned                                                                   |
| 05  | [Intelligent Incident Triage](#uc05--intelligent-incident-triage)   | Agentic, decision support   | CTO, Platform Engineering, SRE  | Planned                                                                   |

Each use case has its own README covering scope, architecture, build steps and
validated findings. Start there:

- [Use Case 01: Sovereign RAG](01-sovereign-rag/)
- [Use Case 02: Complaint Intelligence](02-complaint-intelligence/)

---

## UC01 — Sovereign RAG

**Pattern:** Air-gapped retrieval-augmented generation

**The problem:** Regulated organisations need to query large bodies of internal or
regulatory documentation in natural language, without sending that data to an
external model API. Existing tools either require cloud connectivity or don't provide
the governance and audit trail a regulated environment demands.

**What it demonstrates:** A fully self-contained RAG pipeline on RHOAI: regulatory
PDFs ingested and chunked, embedded into Milvus, retrieved against a natural language
query, and answered by Granite via Red Hat AI Inference Server — all on-cluster.
No data leaves the infrastructure. Every answer is traceable to its source document.

**Why it matters in banking:** Data sovereignty is a board-level concern. This use
case demonstrates that AI can be useful without being a data risk. It also establishes
the platform foundations — model serving, vector store, object storage, notebook
workbench — that every subsequent use case builds on.

**RHOAI capabilities introduced:** KServe RawDeployment, vLLM / Red Hat AI Inference
Server, Milvus vector store, MinIO object storage, RHOAI workbench, Ansible seeding.

---

## UC02 — Complaint Intelligence

**Pattern:** Governed RAG classification (System-to-LLM)

**The problem:** Banks receive large volumes of customer complaints managed
inconsistently across teams. Themes and root causes are not systematically
identified, creating regulatory exposure (CCCFA, CoFI) and duplicated manual effort
across teams.

**What it demonstrates:** A classification pipeline that ingests complaint records,
applies PII guardrails, classifies each complaint against a structured theme and
root-cause taxonomy, produces confidence-scored outputs with source citations, and
routes ambiguous cases to human review. A Flask demo application visualises the full
pipeline: theme dashboard, live classification, review queue, guardrails evidence, and
the audit trail.

**Why it matters in banking:** This is the pattern most banks will actually deploy
first — structured data in, structured intelligence out, with humans in the loop for
decisions. The regulatory alignment (CCCFA, CoFI, PACT) is direct. The MaaS
governance chain demonstrates how RHOAI acts as a control plane across the bank's AI
estate, not just a model host.

**RHOAI capabilities introduced:** Llama Stack unified API, TrustyAI guardrails,
Docling document ingestion, inline Milvus and sentence-transformers, MaaS gateway,
MLflow experiment tracking, Flask deployment via BuildConfig.

---

## UC03 — Regulatory Change Management

**Pattern:** RAG, structured impact assessment

**The problem:** Banks receive a continuous stream of regulatory updates, guidance
and consultation papers. Legal and compliance teams manually track, interpret and
assess the impact of these changes against internal policies and controls — a process
that is slow, inconsistent and expensive. A change missed or misinterpreted creates
direct regulatory exposure.

**What it demonstrates:** A pipeline that ingests new regulatory documents (RBNZ,
APRA, BIS, FMA), identifies changes relevant to the bank's control framework,
maps them to affected policies and controls, and produces a structured impact
assessment with source citations. The output is a draft for a compliance analyst
to review and approve — decision support, not automation. The pipeline builds
directly on UC01's RAG foundations and adds a structured output schema, a
control-framework taxonomy, and a review workflow.

**Why it matters in banking:** Every bank has this problem. Regulatory change
management is a significant source of compliance cost and a common audit finding.
The use case maps directly to obligations under CCCFA, CoFI, FMA conduct guidance
and APRA prudential standards. It demonstrates RHOAI delivering value to the
compliance function, not just the data science team — which is a materially
different conversation.

**RHOAI capabilities to introduce:** Structured output schema validation, Docling
pipeline integration, expanded taxonomy management, multi-document retrieval,
review workflow state management.

**Primary audience:** CRO, Head of Compliance, Legal, Internal Audit.

**Status:** Planned. Scope to be finalised.

---

## UC04 — Model Risk Governance

**Pattern:** Platform governance, model lifecycle management

**The problem:** Banks deploying AI models — whether built internally or procured
from vendors — need to demonstrate to their regulators that those models are
validated, monitored and governed. Most are managing this through a combination of
spreadsheets, policy documents and manual reviews. There is no single system of
record. As AI deployments scale, this becomes a material regulatory risk.

**What it demonstrates:** A model governance workflow built on RHOAI's model
registry, TrustyAI and MLflow. A new model enters a documented approval pipeline:
training and validation metrics are captured, bias and fairness checks are run,
approval sign-off is recorded, and ongoing monitoring dashboards track performance,
drift and data quality over time. The demo shows a governance officer's view of
the AI estate — which models are approved, which are under review, and which have
triggered monitoring alerts.

**Why it matters in banking:** Model Risk Management (MRM) is a board-level concern
at every major bank. APRA and RBNZ both have explicit expectations around model
validation, monitoring and governance. This use case reframes RHOAI not as a place
to run models but as a platform for governing them — a materially stronger message
for a CRO or model risk audience than any individual model capability demonstration.

**RHOAI capabilities to introduce:** RHOAI model registry, TrustyAI bias detection
and drift monitoring, MLflow experiment tracking, role-based access control,
explainability, audit trail.

**Primary audience:** CRO, Head of Model Risk, Internal Audit, Risk Committee.

**Status:** Planned. Scope to be finalised.

---

## UC05 — Intelligent Incident Triage

**Pattern:** Agentic reasoning, decision support

**The problem:** Production incidents in complex banking environments trigger a
high-friction manual triage process. Engineers must pull context from multiple
systems — observability platforms, log aggregators, runbooks, past incident records,
configuration management databases — before they can begin reasoning about cause
and remediation. This cognitive load slows resolution and increases MTTR.

**What it demonstrates:** An agentic pipeline that receives an incident alert,
autonomously retrieves relevant context from multiple sources (Dynatrace/Prometheus
metrics, Splunk logs, Confluence runbooks, ServiceNow past incidents), reasons
about the most likely cause and remediation path, and delivers a structured triage
report to the engineer within minutes of the alert firing. The pipeline is
read-only and decision-support only — it does not execute changes or apply
remediation. Human accountability for resolution is preserved.

**Why it matters in banking:** Operational resilience is a regulatory obligation
(APRA CPS 230, RBNZ operational risk guidance). Reducing MTTR and improving
incident quality have direct financial and reputational value. This use case
demonstrates a more sophisticated agentic pattern than the earlier use cases
while maintaining the human-oversight framing that regulated environments require.
It also broadens the conversation beyond the data science team to platform
engineering and SRE audiences.

**RHOAI capabilities to introduce:** Agentic tool use and reasoning, multi-source
retrieval orchestration, structured report generation, guardrails on agentic output,
MaaS gateway for multi-model routing.

**Primary audience:** CTO, Head of Platform Engineering, SRE, Technology Risk.

**Status:** Planned. Scope to be finalised.

---

## Design principles

These apply across every use case in the lab:

- **Rebuildable from the repo.** Any environment this lab produces can be rebuilt
  from this repository with no undocumented manual steps. If a step is not in Git,
  it did not happen.
- **No credentials in Git.** Secrets are injected at deploy time via environment
  variables. The repository is audited before every push.
- **Each tool for what it is genuinely good at.** Terraform for cloud bootstrap
  where applicable, GitOps (Argo CD) for declarative state, Ansible for procedural
  post-deploy tasks, notebooks and pipelines for application logic.
- **First live runs are validation exercises, not exploration.** Platform-specific
  drift from documentation is expected. Deviations are fixed and recorded, never
  silently worked around.
- **Prepare, deploy, execute, capture.** Structure and documentation come before
  live environments are requested; results and deviations are captured before
  moving on.
- **The repo is customer-agnostic.** All datasets are synthetic. No customer names,
  engagement-specific detail or credentials appear anywhere in this repository.

---

## Environment

Use cases are built and validated against Red Hat Demo Platform (RHDP) provisioned
OpenShift clusters with RHOAI installed, typically with a single NVIDIA L4 GPU
worker node on AWS (`g6.xlarge`). Version details, catalog items and
environment-specific findings are recorded per use case, because they change
between RHOAI releases and between RHDP catalog versions.

Current validated baseline: **RHOAI 3.4.2, OpenShift 4.20.28.**

---

## Synthetic data

All datasets in this repository are synthetically generated. Any resemblance to real
individuals, organisations or records is coincidental. Where mock PII appears, it is
a documented test fixture, obviously fake by design, used to demonstrate guardrail
and policy behaviour.

---

## Repository structure

    rhoai/
    ├── README.md                       ← this file
    ├── 01-sovereign-rag/               ← air-gapped RAG: platform foundations
    ├── 02-complaint-intelligence/      ← governed classification: controls and guardrails
    ├── 03-regulatory-change/           ← planned: regulatory impact assessment
    ├── 04-model-risk-governance/       ← planned: model lifecycle governance
    └── 05-incident-triage/             ← planned: agentic incident reasoning

Structure within each use case follows a common shape (`gitops/`, `manifests/`,
`ansible/`, `notebooks/`, `docs/`) so that patterns proven in one use case transfer
directly to the next. Shared conventions are promoted to repo level only once more
than one use case actually uses them.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
