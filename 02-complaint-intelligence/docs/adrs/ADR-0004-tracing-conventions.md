# ADR-0004: Evidence and telemetry are separate layers

**Status:** Accepted
**Date:** 2026-07-15
**Last revised:** 2026-07-23

## Context

The controls alignment matrix commits this use case to several evidence rows:
every classification traceable to its source text, guardrail decisions
observable, outputs stamped with prompt/model/taxonomy versions, evaluation
comparable across releases, and evidence reviewable by a risk or compliance
persona without platform administrator involvement, with an export path.

A draft version of this ADR proposed satisfying these with MLflow experiments
plus a `uc02.`-prefixed span convention. Live validation on RHOAI 2.25.8
(2026-07-15) found:

1. **MLflow is not present.** Not a DataScienceCluster component, no pods, no
   CRDs. The proposed experiment/run structure had no foundation.
2. **Llama Stack telemetry exists and is persistent**, but is APM, not audit.
   The `meta-reference` provider persists traces to the mounted PVC, and every
   completion response carries `trace_id` and `span_id`. But spans are
   internal method calls (`VLLMInferenceAdapter.get_api_key`,
   `VectorIORouter.health`), and `/v1/telemetry/traces` returns only
   `trace_id`, timestamps, and a span tree. Nothing collects traces
   externally; no Jaeger, Tempo, or OTEL collector exists in the cluster.

Satisfying the self-service auditability row with this store would mean
asking a compliance officer to query by timestamp, receive a UUID, walk a
span tree of Python method calls, and infer which complaint it concerned.
The technology is not deficient; it is built for a different reader.

On RHOAI 3.4.2, this reasoning held and strengthened: completion responses no
longer carry a `metrics` block at all, only OpenAI-native `usage`. The
telemetry shape changed across one platform version; the evidence schema
below did not need to. Evidence written deliberately survives platform
churn; inherited telemetry does not.

## Decision

Evidence and telemetry are **two layers with different readers, joined by
`trace_id`**. Neither pretends to be the other.

### Layer 1: Evidence (the audit trail)

The classification record **is** the evidence. The pipeline writes one
durable, structured record per complaint, deliberately, as a first-class
artefact, not a byproduct of tracing:

```json
{
  "complaint_id": "...",
  "timestamp": "...",
  "theme_id": "THM-05",
  "root_cause_id": "RC-02",
  "confidence": 0.83,
  "citation": { "start": 142, "end": 210, "text": "..." },
  "routed_to_review": false,
  "review_reason": null,
  "candidate_themes": [],
  "pii_detected": true,
  "pii_redactions": 2,
  "injection_blocked": false,
  "guardrail_policy_id": "regex",
  "prompt_version": "1.2.0",
  "model_version": "granite-3-3-8b-instruct",
  "taxonomy_version": "0.1.0",
  "trace_id": "033246531d0d397f0c6667a049eba028"
}
```

- **Written to:** JSONL in MinIO (`s3://evidence/classifications/`). Durable,
  trivially exportable, no new infrastructure; export is a bucket copy, which
  satisfies the retention row honestly.
- **Queried by:** the demo application, which loads records and filters by
  theme, confidence, review status, or date. At demo volumes (~200 records)
  this is in-memory and instant. The production path (an evidence store or
  SIEM ingest) is documented, not simulated.
- **Read by:** risk, compliance, audit. No platform administrator required.

### Review routing: what actually works, and what does not

Live testing against the full 200-record synthetic corpus found that Granite
3.3 8B Instruct at `temperature=0.0` does not reliably self-report
classification uncertainty. Three separate approaches were tested and each
failed the same way, on complaints the synthetic dataset deliberately
designed to be genuinely ambiguous:

1. **Raw confidence score** never dropped below 0.8, even on the hardest
   cases.
2. **A ranked candidate-theme score spread**, produced by the model in the
   same call, showed an identical ~80/20 top/second split whether the
   complaint was ambiguous or not, statistically indistinguishable.
3. **An explicit self-reported boolean** (asking the model directly whether
   a different theme was genuinely defensible) returned `false` on every
   tested case, including one where the complainant's own words stated the
   ambiguity outright.

This is a known characteristic of smaller instruction-tuned models under
deterministic decoding, not a defect in any single prompt attempt. It is a
plausible, untested benefit of the customer's originally specified model
(Claude Sonnet or Opus via AWS Bedrock, see the ANZ use case document) that
this architecture's pluggable model tier (ADR-0008) makes available as a
configuration change, not a rebuild, should calibrated self-reported
confidence matter more than cost or data locality for a given deployment.

**Adopted for this PoC: retrieval-similarity delta.** Independent of the
LLM's self-report, the top two THEME-type matches from the taxonomy vector
search are compared. If their similarity scores are within
`AMBIGUITY_DELTA_THRESHOLD` of each other, the complaint routes to review.

- **`routed_to_review`** is `true` when `confidence < CONFIDENCE_THRESHOLD`
  (0.7, kept as a coarse backstop; did not fire on any tested record) **or**
  the retrieval delta is below `AMBIGUITY_DELTA_THRESHOLD` (0.03).
- **`review_reason`** is free text assembled by the pipeline, not the model,
  stating which condition fired, e.g. _"top two taxonomy matches (THM-04:
  0.75, THM-05: 0.65) within 0.03 of each other."_
- **`candidate_themes`** is populated only when `routed_to_review` is true,
  holding the retrieval-identified alternative theme and its similarity
  score.

**Stated limitation, not yet resolved.** `AMBIGUITY_DELTA_THRESHOLD = 0.03`
was set from two confirmed examples in the synthetic dataset, not a
statistically calibrated value; a production implementation would need
calibration against a meaningful labeled set. Three of five known-ambiguous
scenarios in the dataset still do not trigger this signal; their top
taxonomy match scores strongly (0.74-0.77) despite being human-designed as
defensible either way. For one such pair (THM-10 vs THM-07), the taxonomy's
own written exclusion rule ("classify by the substantive theme where one
exists") arguably supports the model's answer over the scenario's intended
ground truth, suggesting the gap may sit in the scenario design, not the
detection mechanism. This is stated plainly rather than smoothed over,
consistent with the standard the rest of this evidence layer holds itself
to.

**Why this belongs in the demo, not just the log.** This is a working
illustration of the control-plane value proposition this engagement is
built around: rather than assuming a model's stated confidence is
trustworthy, the architecture tested it, found a real gap, addressed it with
an independent signal, and documents the remaining bound honestly. The
model's substitutability means this is a configuration decision available to
the customer, not an architectural limitation.

### Layer 2: Telemetry (the engineering view)

Llama Stack's native sqlite trace store, as configured. Persistent on the
PVC, automatic, free. Used for latency and failure debugging. Optionally
OTLP-exported if a collector is ever introduced
(`otel_exporter_otlp_endpoint` is the hook). No further claim is made for it.

### The join

Every evidence record carries the `trace_id` of the interaction that
produced it. The evidence record answers _what was decided and why it is
defensible_; the trace answers _how it executed_. One key connects them, and
the demo can walk from a compliance question to an engineering answer in one
hop.

### Guardrail decisions

Captured in the evidence record by the pipeline, from the orchestrator's
detection response directly, rather than relying on trace correlation. The
`GuardrailsOrchestrator.spec.otelExporter` block (`otlpEndpoint`,
`tracesEndpoint`) is noted as a future option for joining guardrail spans
into the telemetry layer; it is not required for the evidence layer.

### Evaluation

Evaluation runs write the same record shape plus `evaluation_run_id` and
`baseline` (bool), against the 60-record reference set. Comparing two
releases is a filter over evidence records, not a separate system. This
replaces the MLflow experiment structure the draft proposed.

## Consequences

- **The pipeline gains an explicit responsibility:** write the evidence
  record. It is not a byproduct of tracing, and it cannot be skipped.
- **Controls matrix rows are satisfiable as written.** "Reviewable without
  platform administrators" becomes true rather than aspirational, because the
  record is designed for that reader.
- **No dependency on absent infrastructure.** MLflow, Jaeger, Tempo, and OTEL
  collectors are all optional rather than assumed.
- **The four-stage span convention is retired** as a tracing structure. Its
  content survives as fields on the evidence record (`pii_detected`,
  `injection_blocked`, `citation`, versions).
- **`docs/controls-alignment.md` must be updated in the same commit** as any
  further schema change: the "span structure" design commitment is replaced
  by the evidence record schema and the two-layer split.
- **Convergence cost, per ADR-0001**, stays low: the evidence record is
  self-describing JSON with a `trace_id` join. Any control-plane work that
  later wants it can consume it as-is.
- **Review routing is a demo-appropriate simplification, stated as such.**
  Production calibration of `AMBIGUITY_DELTA_THRESHOLD`, and investigation of
  the three unresolved scenario pairs, are open work, not silently deferred.

## Amendment history

- **2026-07-15:** Superseded the draft's MLflow/span-convention proposal
  after live validation; adopted the two-layer evidence/telemetry split.
- **2026-07-15 (RHOAI 3.4.2):** Confirmed the decision holds after the
  platform's telemetry shape changed across versions.
- **2026-07-22:** Added `review_reason` and `candidate_themes` to the schema,
  closing a gap against `docs/demo-experience.md`'s view 3 commitment.
- **2026-07-23:** Replaced confidence-threshold-only review routing (found
  non-discriminating in live testing) with retrieval-similarity delta,
  documented the stated limitation and demo-appropriate threshold, and
  connected the finding to the control-plane demo narrative.
