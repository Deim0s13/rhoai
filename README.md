# Red Hat OpenShift AI Presales Lab

A structured, hands-on lab for building and demonstrating enterprise AI patterns on
Red Hat OpenShift AI (RHOAI), with a focus on the realities of regulated industries
such as financial services.

This is a personal learning and demonstration project. It is not an official
Red Hat offering, reference architecture or supported product. Opinions and
design choices are my own.

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
   expectation and what fixed it, so the next build (mine or yours) starts further
   ahead.
3. **Stay reusable.** Everything here is organisation-agnostic. No customer names,
   no engagement-specific detail, no credentials. Per-engagement tailoring lives
   outside this repository by design.

## Use cases

| #        | Use case               | Pattern                                     | Status                                 | What it adds to the lab                                                                                                                                           |
| -------- | ---------------------- | ------------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 01       | Sovereign RAG          | Air-gapped retrieval-augmented generation   | Substantially complete, validated live | Platform foundations: model serving (vLLM / KServe RawDeployment), Milvus, MinIO, GitOps delivery, Ansible seeding, notebook-based RAG                            |
| 02       | Complaint Intelligence | Governed RAG classification (system-to-LLM) | In design                              | Llama Stack unified API, TrustyAI guardrails, Docling ingestion, structured classification with versioned, citation-linked output, controls-to-capability mapping |
| 03 to 05 | To be scoped           |                                             | Planned                                | Each future use case is chosen to introduce capabilities the lab has not yet exercised                                                                            |

Each use case has its own README covering scope, architecture, build steps and
validated learnings. Start there:

- [Use Case 01: Sovereign RAG](use-cases/01-sovereign-rag/)
- [Use Case 02: Complaint Intelligence](use-cases/02-complaint-intelligence/)

## Design principles

These apply across every use case in the lab:

- **Rebuildable from the repo.** Any environment this lab produces can be rebuilt
  from this repository with no undocumented manual steps. If a step is not in Git,
  it did not happen.
- **No credentials in Git.** Secrets are injected at deploy time via environment
  variables. The repository is audited for secrets.
- **Each tool for what it is genuinely good at.** Terraform for cloud bootstrap
  where applicable, GitOps (Argo CD) for declarative state, Ansible for procedural
  post-deploy tasks, notebooks and pipelines for application logic.
- **First live runs are validation exercises, not exploration.** Platform-specific
  drift from documentation is expected. Deviations are fixed and recorded, never
  silently worked around. Use Case 01's learnings table is the model for this.
- **Prepare, deploy, execute, capture.** Structure and documentation come before
  live environments are requested; results and deviations are captured before
  moving on.

## Environment

Use cases are built and validated against Red Hat Demo Platform (RHDP) provisioned
OpenShift clusters with RHOAI installed, typically with a single GPU worker node.
Version details, catalog items and environment-specific findings are recorded per
use case, because they change and because pretending otherwise is how drift tables
get long.

## Synthetic data

All datasets in this repository are synthetically generated. Any resemblance to real
individuals, organisations or records is coincidental. Where mock PII appears, it is
a documented test fixture, obviously fake by design, used to demonstrate guardrail
and policy behaviour.

## Repository structure

```
rhoai/
├── README.md                      # this file
├── 01-sovereign-rag/          # air-gapped RAG: foundations
└── 02-complaint-intelligence/ # governed classification: controls and guardrails
└── ...                            # shared bootstrap/tooling where genuinely shared
```

Structure within each use case follows a common shape (gitops/, manifests/,
ansible/, notebooks/, docs/) so that patterns proven in one use case transfer
directly to the next. Shared conventions are promoted to repo level only once more
than one use case actually uses them.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
