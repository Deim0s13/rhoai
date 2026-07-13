# ADR-0001: Build independently of parallel control-plane work, design for low-cost convergence

**Status:** Accepted
**Date:** 2026-07-14

## Context

A parallel body of work exists that evaluates a horizontal AI control plane
(gateway, guardrails, tracing and evidence layers) against a representative RAG
pattern, structured around the same four governance pillars this use case adopts:
economics, safety and trust, quality and consistency, and production readiness.

Coordinating implementation conventions with that work (span naming, MLflow
structure, guardrail policy definitions, gateway composition) would create
scheduling dependencies and couple this build's pace and design decisions to work
owned elsewhere. It would also blur a useful boundary: that work deliberately
proves controls without a business use case, while this use case proves a governed
business workload.

## Decision

Build this use case independently, with no external alignment as a prerequisite
for any build step. Specifically:

1. The four-stage span convention (application, input/guardrails, retrieval,
   model) is defined and owned within this use case, and settled during platform
   validation.
2. Guardrail policies are authored here as self-contained, versioned,
   platform-level definitions, portable to any workload on the cluster.
3. Gateway layer composition is decided by what the provisioned environment
   actually offers, preferring platform-native capability over composition.
4. All conventions are deliberately shaped so that the evidence this workload
   produces reads naturally alongside control-plane style demonstrations.

## Consequences

- No build step waits on an external conversation. The only remaining gate for
  pipeline code is platform validation of the provisioned environment.
- Some overlap or divergence with the parallel work is accepted as a known cost.
- Convergence, if pursued later, is a merge exercise rather than a rewrite,
  because every convention is documented, versioned and portable.
- Demonstrating platform-level policy consistency requires a second consuming
  workload within this use case (a trivial client is sufficient), since the
  proof can no longer borrow a second consumer from elsewhere.
