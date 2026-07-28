# ADR-0010: Imperative corrective actions live outside the applyable tree

Status: Accepted (2026-07-28)

## Context

ADR-0005 established that secrets do not belong inside GitOps-synced
paths. This incident (DEPLOYMENT-LOG-2026-07-28-servicemesh-recovery.md)
demonstrated the same boundary violated in the other direction: a
one-shot cluster-level corrective manifest (a Service Mesh rollback
subscription from the first incident) was parked in manifests/maas/ for
expediency. A wholesale directory apply on the next fresh environment
turned that targeted, one-time fix into a standing policy, initiating an
OLM downgrade that removed the Service Mesh operator entirely and cost
~45 minutes of recovery.

Applyable paths carry GitOps semantics regardless of the tool that
applies them: "this is true everywhere, always." Corrective actions
carry the opposite semantics: "do this once, here, now." Mixing them
makes the fix for one environment the fault of the next.

## Decision

Directories that are applied wholesale (by Argo, by scripts, or by a
human running `oc apply -f <dir>`) contain steady-state declarative
intent only. One-shot corrective or environment-specific actions are
recorded as runbook steps (docs/runbooks/), applied by explicit human
decision, never committed as applyable manifests inside those paths.

## Consequences

- servicemesh-rollback-subscription.yaml removed from manifests/maas/;
  content preserved in RUNBOOK-servicemesh-recovery.md.
- Any future incident remediation produces a runbook entry, not a
  manifest, unless the fix is genuinely steady-state (in which case it
  belongs in the platform baseline and gets an ADR).
- Scripts continue to apply named files, not directories, where
  practical; directory applies are treated as equivalent to Argo sync.
