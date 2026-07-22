# Controls Alignment Matrix

## Purpose

This demonstration is a vertical business use case: complaint theme and root-cause
intelligence for a financial services organisation, built deliberately as a **governed
workload** rather than a standalone application. Every capability in the demo is
designed to evidence one or more platform-level AI governance controls of the kind
regulated institutions require before generative AI workloads can move beyond
experimentation.

The matrix below maps demo capabilities to control objectives across four pillars
commonly used to structure enterprise AI governance conversations:

1. **Economics**: cost, consumption and provider governance
2. **Safety and Trust**: data protection, policy enforcement and containment
3. **Quality and Consistency**: evaluation, groundedness and change control
4. **Production Readiness**: evidence, traceability and operability

This document is intentionally organisation-agnostic. Where an engagement requires
mapping to a specific customer's control framework, risk taxonomy or KPI set, that
mapping is maintained separately and generated from this matrix. See
[Per-engagement tailoring](#per-engagement-tailoring).

This use case is designed to pair with a horizontal **AI control-plane evaluation**
(gateway, guardrails and evidence layers proven against a representative RAG pattern).
Where both are shown to the same audience, this demo acts as the governed business
workload running on that foundation: the control plane explains the evidence trail,
and this workload generates it.

## How to read the matrix

Each row answers four questions: what control objective a regulated organisation
holds, which platform capability addresses it, how this demo makes that visible, and
what evidence artefact a risk, compliance or audit stakeholder could take away.

---

## Pillar 1: Economics

| Control objective                                                                           | Platform capability                                                                                                                   | How this demo evidences it                                                                                                                           | Evidence artefact                                                            |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Model provider abstraction, so the application is not coupled to a single model or provider | Unified inference API / model gateway; model selection by configuration                                                               | The classification workload is switched between model backends by configuration change only; the application code is untouched                       | Configuration diff; identical request traced to two different backends       |
| Usage constrained by policy, not goodwill                                                   | Token budgets, quotas and rate limits applied per application at the gateway                                                          | Requests exceeding a defined budget are visibly constrained or rejected during a demo run                                                            | Gateway rejection/constraint log entries tied to the application identity    |
| Consumption attributable to an owner                                                        | Application registration with ownership and service metadata                                                                          | The demo application is registered with owner, business-service and purpose metadata; an administrator view lists it among AI-consuming applications | Gateway/registry view showing application, credential and ownership metadata |
| Model tier matched to task value                                                            | Right-sized self-hosted model for high-volume classification, with a routing pattern for escalating hard cases to a higher-tier model | Classification runs on a small open model served in-cluster; the routing configuration shows where a higher-tier endpoint would attach               | Serving configuration; cost/latency telemetry per request                    |

## Pillar 2: Safety and Trust

| Control objective                                                 | Platform capability                                                                                            | How this demo evidences it                                                                                                                                                               | Evidence artefact                                                                                                  |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Sensitive personal data must not reach models or logs unprotected | Inline guardrails with PII detection and redaction on inputs and outputs                                       | Synthetic complaint records contain planted mock PII (names, card-style numbers, phone patterns); guardrails demonstrably redact or block before persistence and before model invocation | Guardrail decision log; redacted trace spans; before/after comparison                                              |
| Untrusted user content must not steer the system                  | Prompt-injection interception at the input boundary                                                            | Complaint text is treated as untrusted input; a planted injection attempt in the synthetic dataset is intercepted and logged                                                             | Blocked-request record with policy identifier                                                                      |
| Access can be removed centrally and immediately                   | Credential revocation at the gateway, independent of the application                                           | The demo application's credential is revoked live; subsequent requests fail at the gateway with no application change                                                                    | Revocation event; failed-request log post-revocation                                                               |
| Data remains within the controlled boundary                       | Self-hosted model serving, in-cluster vector store, no external inference dependency in the demo configuration | The full pipeline (ingestion, embedding, retrieval, inference, output) runs inside the cluster; the architecture and network posture make the boundary explicit                          | Architecture diagram; deployment manifests; absence of external model endpoints in configuration                   |
| Policies applied consistently across workloads                    | Guardrail policies defined at platform level, versioned separately from any application                        | The policy definition lives outside the application and is applied to it, not embedded in it; the same definition is demonstrably applicable to a second workload without modification   | Policy definition as a standalone versioned artefact; identical guardrail decisions across two consuming workloads |

## Pillar 3: Quality and Consistency

| Control objective                                     | Platform capability                                                                          | How this demo evidences it                                                                                                                                                        | Evidence artefact                                                |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Outputs must be grounded in source data               | Retrieval-augmented classification with mandatory citation                                   | Every theme and root-cause classification carries a citation to the source complaint text that produced it; there is no uncited output path                                       | Output schema; trace linking classification to retrieved context |
| The system must express uncertainty rather than guess | Confidence scoring with a defined human-review threshold                                     | The synthetic dataset includes deliberately ambiguous cases; low-confidence classifications are visibly routed for review rather than silently accepted                           | Confidence distribution across a demo batch; review-queue view   |
| Behaviour is evaluated before change is promoted      | Evaluation workflows against a reference dataset, with baseline comparison across releases   | An evaluation batch runs against a manually labelled reference set; a prompt or model change is then introduced and the evaluation re-run, with results compared against baseline | Evaluation records for both runs; side-by-side comparison        |
| Changes to prompts and models are controlled          | Prompts, taxonomy and model configuration versioned as code; releases tracked through GitOps | Every classification output is stamped with prompt version, model version and taxonomy version; a prompt change is traceable to a specific tracked release                        | Version metadata on outputs; Git history; release record         |
| Degradation is detectable                             | Repeatable evaluation providing a drift/regression signal                                    | The same evaluation set re-run after a configuration change surfaces behavioural difference as a measurable delta                                                                 | Evaluation deltas across runs                                    |

## Pillar 4: Production Readiness

| Control objective                                      | Platform capability                                                                    | How this demo evidences it                                                                                                                                                    | Evidence artefact                                                        |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Interactions can be reviewed end to end                | Structured tracing decomposing each interaction into spans                             | Every classification is traceable through a consistent span structure: application request, input and guardrail decisions, retrieval and context, model invocation and output | Trace records per interaction, following the span structure below        |
| Evidence is reviewable without platform administrators | Self-service access to traces, evaluations and release records for governance personas | A risk/compliance persona locates the trace, guardrail decision and evaluation evidence for a given classification without administrator involvement                          | Walkthrough from the governance persona's view; exported evidence bundle |
| Evidence can be retained externally                    | Export and integration patterns for enterprise logging/SIEM and long-term retention    | Export of trace and evaluation records is demonstrated; the integration pattern and required metadata are documented for assessment                                           | Exported records; integration pattern documentation                      |
| The environment is reproducible                        | Full environment defined as code; GitOps-managed deployment                            | The entire demo (operators, serving, pipelines, policies, application) rebuilds from the repository with no undocumented manual steps                                         | Bootstrap automation; a rebuilt environment producing identical evidence |
| The workload is operable with existing practices       | Standard platform monitoring, alerting and lifecycle management                        | The AI workload appears in the same operational tooling as any other platform workload; no parallel operating model is introduced                                             | Platform monitoring views including the demo workload                    |

---

## Design commitments

The matrix above is a build contract, not retrospective documentation. The following
implementation decisions flow directly from it:

- **Span structure.** All tracing follows a documented four-stage span convention
  (application, input/guardrails, retrieval, model), defined and owned within
  this use case. The convention is shaped so evidence reads naturally alongside
  control-plane style demonstrations, keeping any later convergence with parallel
  work inexpensive.
- **Output schema.** Every classification emits a single structured record:
  `theme`, `root_cause`, `confidence`, `citation`, `prompt_version`,
  `model_version`, `taxonomy_version`, and, when routed for review,
  `review_reason` and `candidate_themes`. No output path bypasses this schema.
- **Mock PII conventions.** Synthetic data uses documented fake-PII patterns
  (names, card-style numbers, phone numbers) defined alongside the data
  generation scripts, so guardrail demonstrations are deterministic and
  repeatable.
- **Deliberate hard cases.** The synthetic dataset includes ambiguous complaints
  (to exercise confidence thresholds) and at least one prompt-injection attempt
  (to exercise input policy) as first-class test fixtures, not afterthoughts.
- **Gateway registration.** The demo application is registered with ownership and
  service metadata from the start, so inventory and attribution demonstrations
  require no staging.
- **Versioning discipline.** Prompts and taxonomy live in Git and are released,
  not edited in place; every output is attributable to a tracked release.

## Per-engagement tailoring

Customer-specific artefacts, such as mappings to a named control framework, numbered
KPI sets, CMDB/service-record field requirements, or regulator-specific obligations,
are **not stored in this repository**. They are maintained privately per engagement
and derived from this matrix: each customer control or KPI is mapped to one or more
rows above, and gaps become explicit scope discussion points rather than silent
assumptions.

Regulatory references in engagement material should be expressed as examples of a
class of obligation (for example conduct regulation, consumer-credit regulation, or
operational resilience expectations in the relevant jurisdiction) rather than as a
fixed list, so the material travels across jurisdictions.
