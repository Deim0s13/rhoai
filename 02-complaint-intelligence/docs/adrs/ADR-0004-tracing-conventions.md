# ADR-0004: Evidence and telemetry are separate layers

**Status:** Accepted
**Date:** 2026-07-15

**Supersedes the draft proposal of the same number**, which assumed MLflow
experiments and proposed layering a four-stage span convention onto platform
tracing. Live validation invalidated both assumptions.

## Context

The controls alignment matrix commits this use case to several evidence rows:
every classification traceable to its source text, guardrail decisions
observable, outputs stamped with prompt/model/taxonomy versions, evaluation
comparable across releases, and evidence reviewable by a risk or compliance
persona without platform administrator involvement, with an export path.

The draft ADR-0004 proposed satisfying these with MLflow experiments plus a
`uc02.`-prefixed span convention. Validation on RHOAI 2.25.8 (2026-07-15) found:

1. **MLflow is not present.** Not a DataScienceCluster component, no pods, no
   CRDs. The proposed experiment/run structure had no foundation.
2. **Llama Stack telemetry exists and is persistent.** The `meta-reference`
   provider runs with `sinks: "console,sqlite"` and
   `sqlite_db_path: /opt/app-root/src/.llama/distributions/rh/trace_store.db`,
   which is on the mounted PVC and therefore survives pod restarts. Every
   completion response carries `trace_id`, `span_id` and token metrics.
3. **Nothing collects traces externally.** `otel_exporter_otlp_endpoint: null`,
   and no Jaeger, Tempo or OTEL collector exists in the cluster.
4. **The traces are APM, not audit.** Spans are internal method calls
   (`VLLMInferenceAdapter.get_api_key`, `VectorIORouter.health`,
   `InferenceRouter.health`). The `/v1/telemetry/traces` query returns
   `trace_id`, `root_span_id`, `start_time`, `end_time` and nothing else;
   business meaning requires drilling span by span.

The decisive observation is (4). Satisfying the self-service auditability row
with this store would mean asking a compliance officer to query by timestamp,
receive a UUID, walk a span tree of Python method calls, and infer which
complaint it concerned. The technology is not deficient; it is built for a
different reader.

## Decision

Evidence and telemetry are **two layers with different readers, joined by
`trace_id`**. Neither pretends to be the other.

### Layer 1: Evidence (the audit trail)

The classification record **is** the evidence. The pipeline writes one durable,
structured record per complaint, deliberately, as a first-class artefact:

```json
{
  "complaint_id": "...",
  "timestamp": "...",
  "theme_id": "THM-05",
  "root_cause_id": "RC-02",
  "confidence": 0.83,
  "citation": { "start": 142, "end": 210, "text": "..." },
  "routed_to_review": false,
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
  trivially exportable, no new infrastructure, and export is a bucket copy,
  which satisfies the retention row honestly.
- **Queried by:** the demo application, which loads records and filters by
  theme, confidence, review status or date. At demo volumes (~200 records) this
  is in-memory and instant. The production path (an evidence store or SIEM
  ingest) is documented, not simulated.
- **Read by:** risk, compliance, audit. No platform administrator required.

### Layer 2: Telemetry (the engineering view)

Llama Stack's native sqlite trace store, as configured. Persistent on the PVC,
automatic, free. Used for latency and failure debugging. Optionally OTLP-exported
if a collector is ever introduced (`otel_exporter_otlp_endpoint` is the hook).
No further claim is made for it.

### The join

Every evidence record carries the `trace_id` of the interaction that produced
it. The evidence record answers _what was decided and why it is defensible_;
the trace answers _how it executed_. One key connects them, and the demo can
walk from a compliance question to an engineering answer in one hop.

### Guardrail decisions

Captured in the evidence record by the pipeline, from the orchestrator's
detection response, rather than relying on trace correlation. The
`GuardrailsOrchestrator.spec.otelExporter` block (`otlpEndpoint`,
`tracesEndpoint`) is noted as a future option for joining guardrail spans into
the telemetry layer; it is not required for the evidence layer.

### Evaluation

Evaluation runs write the same record shape plus `evaluation_run_id` and
`baseline` (bool), against the 60-record reference set. Comparing two releases
is a filter over evidence records, not a separate system. This replaces the
MLflow experiment structure the draft proposed.

## Consequences

- **The pipeline gains an explicit responsibility:** write the evidence record.
  It is not a byproduct of tracing, and it cannot be skipped. This is a
  stronger contract than the draft's, not a weaker one.
- **Controls matrix rows are satisfiable as written.** "Reviewable without
  platform administrators" becomes true rather than aspirational, because the
  record is designed for that reader.
- **No dependency on absent infrastructure.** MLflow, Jaeger, Tempo and OTEL
  collectors are all optional rather than assumed. The evidence layer works on
  what this cluster actually has.
- **The four-stage span convention is retired** as a tracing structure. Its
  content survives as fields on the evidence record (`pii_detected`,
  `injection_blocked`, `citation`, versions), which is where that information
  was always going to be read from.
- **`docs/controls-alignment.md` must be updated in the same commit:** the
  "span structure" design commitment is replaced by the evidence record schema
  and the two-layer split. `docs/architecture.md`'s classification data flow
  keeps its four stages as a _processing_ description, not a tracing one.
- **Honest demo language:** "the platform gives us engineering telemetry for
  free; we built the audit trail deliberately, because a compliance officer and
  an SRE need different things." That is a better story than "we have tracing."
- **Convergence cost, per ADR-0001**, stays low: the evidence record is
  self-describing JSON with a trace_id join. Any control-plane work that later
  wants it can consume it.
