# ADR-0003: Gateway layer composition

**Status:** Accepted
**Date:** 29-07-2026

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

**Option 1: platform-native MaaS.** Confirmed by a paper-based evaluation
against the four required demonstrations (2026-07-28), not chosen by
default: MaaS is purpose-built for three of the four (token-based budget
enforcement with real rejection evidence, and a genuine consumption
registry, both weak or absent under a composed-gateway alternative), and
matches on the fourth (kill-switch revocation). Option 2 (composed
gateway via Authorino alone) was the only real alternative considered;
Authorino handles identity and revocation well but has no rate-limiting
capability of its own, that is specifically what Kuadrant adds, so budget
enforcement under option 2 would be a hand-built request-count
approximation, not the token-based budgeting the pillar actually asks
for.

- **Identity and credential issue/revocation:** subscription-bound API
  keys (`sk-oai-` prefix), issued and revoked via the MaaS dashboard or
  `DELETE /maas-api/v1/api-keys/{id}`.
- **Budget enforcement and rejection evidence:** `MaaSSubscription` token
  rate limits, enforced by Kuadrant, produce real `429` responses under
  load. Demo moment: the guide's own verification procedure, rapid
  requests against a low-token-limit subscription, `200`/`429` mix
  confirmed via `curl`.
- **Consumption registry:** the MaaS observability dashboard,
  subscription-level token consumption, exportable CSV for cost
  attribution.
- **Kill-switch demo:** revoke a subscription's API key, next request
  `401`s, Granite and the classification pipeline completely untouched.

## Consequences

**Confirmed live, 2026-07-28, against this environment:**

- Cluster-admin access: confirmed present.
- `kserve` component: already `Managed`.
- `cert-manager-operator`, `servicemeshoperator3`: already installed.
- LWS (LeaderWorkerSet) operator: **not installed**, required.
- User Workload Monitoring: **not confirmed enabled**, required (MaaS
  shows `Degraded` without it).
- Kuadrant/Red Hat Connectivity Link: **not installed** (confirmed
  earlier this session: Authorino present alone, no Kuadrant operator, no
  Kuadrant CRDs).
- `maas-default-gateway`: does not exist. The two Gateways present
  (`data-science-gateway`, `openshift-ai-inference`) are unrelated,
  already-investigated inference-routing Gateways, not a partial MaaS
  setup, this was an incorrect inference earlier in this session,
  corrected here.
- PostgreSQL for MaaS: not yet provisioned. RHOAI does not supply one;
  the existing Llama Stack Postgres instance may be reusable as a
  separate database within it, worth confirming before provisioning a
  new instance from scratch.
- **Granite is deployed via the classic KServe `InferenceService`
  (`serving.kserve.io/v1beta1`), confirmed live.** MaaS requires the
  `LLMInferenceService` architecture (llm-d, or vLLM-on-MaaS as a
  Technology Preview). This is the most consequential finding: making
  Granite MaaS-eligible means redeploying it under a different serving
  architecture, not a gateway configuration change. The current
  `RawDeployment InferenceService` setup has been validated across
  multiple full rebuilds this engagement; this redeployment is real risk
  to that stability, not a side effect to wave through.

**Genuinely new platform, worth stating plainly against the proposal's
own "no new platform to procure or accredit" framing to ANZ**: a new
cluster-scoped operator (Kuadrant), a new database, and a changed model
serving architecture are all real additions, not configuration within
what already exists. This does not invalidate the "control plane, not
migration" narrative, but it does mean the Economics pillar's live
demonstration carries a materially higher build cost than every other
control demonstrated so far in this engagement, worth being upfront about
that asymmetry in any customer conversation, not just in this document.

**Phased implementation plan** (mirrors the companion guide's own phase
structure, each phase independently verifiable before proceeding):

1. Prerequisites: LWS operator, User Workload Monitoring, confirm
   cert-manager/Service Mesh versions meet minimums
2. Platform configuration: Kuadrant/Authorino, `maas-default-gateway`,
   TLS bootstrap
3. RHOAI configuration: `DataScienceCluster` MaaS enablement,
   `OdhDashboardConfig` flags
4. MaaS platform: PostgreSQL secret, `maas-api` deployment
5. Model deployment: redeploy Granite (or a second, MaaS-only model,
   e.g. the CPU-only `simulator`) under `LLMInferenceService`
6. Verification: API keys, inference through the MaaS gateway, rate
   limiting, revocation, all live-tested per the official verification
   procedure
7. Observability (optional): usage dashboard, cost-attribution export

**Open question carried into implementation**: whether to redeploy
_Granite itself_ under `LLMInferenceService` (higher risk, directly
demonstrates governance over the actual classification model) or
register a _second_, MaaS-only model, the CPU-only `simulator` is a
strong candidate given the single-GPU constraint, and this ADR is also
the second consuming workload ADR-0001 calls for as the policy-consistency
proof. The second option is lower risk to the already-stable pipeline and
arguably serves ADR-0001's own goal better; worth deciding explicitly
before phase 5, not defaulting to redeploying Granite by inertia.

**Resolved 2026-07-28:** the `simulator` model (CPU-only, per the MaaS
companion guide) will be registered as the second MaaS-governed workload,
not Granite. This keeps the classification pipeline's validated serving
setup completely untouched by the MaaS install, avoids GPU contention
entirely, and satisfies ADR-0001's still-open requirement for a second
consuming workload as the policy-consistency proof, closing two backlog
items with one build rather than one. The governance demonstration
(identity, budget enforcement, revocation) applies to the `simulator`
model through the same MaaS mechanism that would govern any model
registered with it, the narrative point, platform-level control across
the estate, doesn't depend on which specific model is behind it.

# ADR-0003 amendment (2026-07-29): Option 1 confirmed viable; namespace isolation prerequisite

Status: Accepted

## Summary

Option 1 (platform-native MaaS via RHCL/Kuadrant) is viable on RHOAI
3.4.2. Three failed install attempts and an intermediate hypothesis that
option 1 was blocked by Service Mesh version incompatibility are recorded
and refuted below. The actual constraint was OLM namespace mechanics, and
the fix (installing the stack into kuadrant-system) is standard practice
rather than a workaround.

## The refuted hypothesis, and why it was plausible

Every RHCL install plan generated in openshift-operators bundled
servicemeshoperator3.v3.4.0, the version RHOAI 3.4.2's gateway controller
deadlocks against (Istio pin v1.26.2, dropped as end-of-life in SM 3.4).
This held across two environments and survived stale-plan deletion,
suggesting RHCL required SM 3.4. Two facts refuted it: the rhcl-operator
packagemanifest declares no servicemesh dependency, and a subscription
created in an isolated namespace generated a plan containing the full
Kuadrant stack and no servicemesh. The bundling was OLM sweeping the
permanently-pending servicemesh upgrade in openshift-operators into any
plan generated there.

## Decisions

1. The RHCL/Kuadrant stack installs into kuadrant-system (own
   OperatorGroup, AllNamespaces mode, the only mode rhcl supports).
   Isolation applies to OLM plan resolution, not the operator's watch
   scope.
2. The servicemesh subscription in openshift-operators is
   platform-managed (cluster ingress operator) and is never modified by
   this build. Verification is read-only.
3. Plan-content inspection before approval is retained as a detection
   control in setup-maas-phase2.sh. Under isolation it should never
   fire; firing indicates a structural change requiring investigation,
   not a retry.

## Findings relevant to the control-plane narrative

- MaaS gateway infrastructure (maas-gateway-class, maas-default-gateway)
  runs on the OpenShift ingress gateway controller and has no dependency
  on the servicemesh operator's health (observed live: the gateway
  served throughout a period when the servicemesh operator was entirely
  absent).
- Operator upgrade governance in shared namespaces is a real production
  risk class: two live incidents, both caused by bundled install plans,
  both invisible from surface signals for hours. Namespace isolation,
  scoped approval, and content inspection are the demonstrated control
  set. This maps directly to the production-readiness pillar of the ANZ
  control-plane evaluation.

## Remaining to close ADR-0003

Kuadrant CR creation, Authorino TLS bootstrap, gateway annotation (run
once live 2026-07-28, scripting pending), then the four Economics-pillar
demonstrations against the simulator workload.
