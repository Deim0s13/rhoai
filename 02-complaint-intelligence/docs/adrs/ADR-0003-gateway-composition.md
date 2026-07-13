# ADR-0003: Gateway layer composition

**Status:** Draft (pending day-one validation)
**Date:** TO CAPTURE

## Context

The controls alignment matrix commits the Economics pillar to four
demonstrations: model provider abstraction, usage constrained by policy
(budgets, quotas, rate limits), consumption attributable to an owner, and
credential revocation independent of the application (which also serves the
Safety pillar's containment row).

Where these are demonstrated from depends on what the provisioned environment
offers. RHOAI has been converging on a models-as-a-service capability, but its
presence and maturity vary by version. The design preference (recorded in
architecture.md) is platform-native capability over composition; the fallback
ladder below exists so the pillar is never silently dropped.

## Options

1. **Platform-native MaaS / gateway.** Use the RHOAI capability directly:
   register the application identity, apply limits, demonstrate revocation.
   Preferred: it is the story we want to tell (platform-level control, not
   bespoke assembly) and the least code to maintain.
2. **Composed gateway.** A thin, declarative gateway in front of the Llama
   Stack endpoint providing key-based identity, rate limiting and revocation.
   Acceptable for the demo, but it must be presented honestly as a pattern the
   platform is productising, not as the product.
3. **Documented pattern only.** No live gateway demonstration in this
   environment; the Economics rows are evidenced by configuration walkthrough
   and documentation. Last resort: it weakens the pillar from "watch it
   happen" to "trust the slide", so choosing this must be a recorded
   consequence of a real platform gap, not convenience.

## Decision

TO CAPTURE. Record which option, and specifically:

- what provides application identity and credential issue/revocation
- where token budgets / rate limits are enforced and what evidence a rejected
  request produces
- what registry or view answers "which applications consume AI services"
- the exact demo moment for the kill-switch row (revoke, show failure, no app
  change)

## Consequences

TO CAPTURE. At minimum: which controls-matrix Economics rows are demonstrated
live versus documented; what (if anything) was added to manifests/ and
gitops/ as a result; and whether the second consuming workload (required by
ADR-0001 for the policy-consistency proof) also registers through this
gateway, which would strengthen the attribution demonstration.
