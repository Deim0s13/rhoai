# ADR-0004: Tracing and evaluation conventions

**Status:** Draft (pending day-one validation)
**Date:** TO CAPTURE

## Context

The controls alignment matrix commits every classification to a consistent
four-stage trace (application, input/guardrails, retrieval, model), a fixed
output schema, and evaluation runs comparable across releases. Pipeline and
app instrumentation are gated on this ADR: the convention must be settled
before instrumented code is written, so trace structure is built once, not
retrofitted.

This ADR proposes concrete conventions for the validation session to ratify
or amend against what the provisioned tracing capability actually supports.
Ratifying a written proposal is faster and produces better names than
inventing conventions live at a terminal.

## Proposed conventions (ratify or amend during validation)

### Span structure and naming

One trace per classification, root span carrying the correlation ID:

| Span name               | Stage                 | Key attributes                                                                                  |
| ----------------------- | --------------------- | ----------------------------------------------------------------------------------------------- |
| `uc02.request`          | Application           | `complaint_id`, `channel`, `app_identity`                                                       |
| `uc02.input.guardrails` | Input and policy      | `pii_detected` (bool), `pii_redactions` (count), `policy_id`, `injection_blocked` (bool)        |
| `uc02.retrieval`        | Retrieval and context | `taxonomy_version`, `k`, `retrieved_ids`, `top_similarity`                                      |
| `uc02.model`            | Model invocation      | `model_version`, `prompt_version`, `served_model_name`, `tokens_in`, `tokens_out`, `latency_ms` |

Root-span result attributes mirror the output schema: `theme`, `root_cause`,
`confidence`, `citation`, `routed_to_review` (bool).

### Experiment and run structure

- One MLflow experiment per pipeline stage that produces evaluated output:
  `uc02-classification` (per-record traces) and `uc02-evaluation` (batch
  evaluation runs against the reference set).
- Evaluation runs tagged with `prompt_version`, `model_version`,
  `taxonomy_version`, and `baseline` (bool) so any two runs are comparable
  and the release-comparison demo is a two-tag filter, not archaeology.

### Naming rules

- Prefix everything `uc02.` so evidence from this workload is unmistakable in
  shared tooling and merges cleanly with any parallel work later (ADR-0001).
- Attribute names are snake_case, values are plain scalars or short arrays;
  no nested blobs inside attributes (they defeat filtering, which defeats the
  self-service auditability row).

## To validate in the environment

| Question                                                                                                                               | Finding    |
| -------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| Where do traces physically land in this RHOAI version, and what creates them (automatic via Llama Stack, or explicit instrumentation)? | TO CAPTURE |
| Does the available span model support named child spans with custom attributes as proposed?                                            | TO CAPTURE |
| Are experiments/tags supported as proposed for evaluation runs?                                                                        | TO CAPTURE |
| Can a non-admin persona query traces and evaluations (self-service auditability row)?                                                  | TO CAPTURE |
| Export path for evidence retention (SIEM/logging row): what exists?                                                                    | TO CAPTURE |

## Decision

TO CAPTURE: the conventions above as ratified or amended, and the
instrumentation approach (automatic, explicit, or hybrid).

## Consequences

- Pipeline and app implementation is unblocked the moment this ADR moves to
  Accepted; the output schema and span names above become the build contract
  alongside the controls matrix.
- Any amendment made here must be reflected back into
  docs/controls-alignment.md (span structure commitment) and
  docs/architecture.md (classification data flow) in the same commit, so the
  three documents never disagree.
