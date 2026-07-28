# Deployment log: 2026-07-28 (Service Mesh second incident and validated recovery)

The corrective manifest from the first Service Mesh incident
(servicemesh-rollback-subscription.yaml, parked in manifests/maas/) was
applied to this fresh environment via a wholesale directory apply. It
initiated an OLM downgrade (v3.4.0, installed legitimately as a Kuadrant
dependency, back to v3.1.0) that garbage-collected the operator
ServiceAccount and left the mesh running with no operator at all. Every
surface signal (Gateways PROGRAMMED, pods Running, MaaS working) stayed
green for hours. Recovered by hand in ~45 minutes without rebuild,
amending the first incident's "not cleanly recoverable" conclusion.

Recovery procedure: RUNBOOK-servicemesh-recovery.md. Trigger file removed
from the repo (see ADR-0010); its content is preserved in the runbook as
a documented step, not an applyable manifest.

---

## Anatomy: three stacked persistence mechanisms

Each was invisible from `oc get csv`, and each only surfaced after the
previous one was cleared. This stacking is why the first incident's
hand-recovery "wasn't converging": unknown depth, not impossibility.

1. **Stranded approved install plans (false state).** The downgrade left
   approved v3.1.0 plans whose resources had been created once and then
   partially garbage-collected (CSV deletion removes the ServiceAccount
   and RBAC the CSV owns). OLM trusts plan history over cluster reality:
   every subsequent v3.1.0 CSV was laid down against those plans and
   stuck at RequirementsNotMet (missing ServiceAccount), because an
   already-executed plan never re-creates resources.

2. **Resolver-driven subscription resurrection.** servicemeshoperator3 is
   a dependency of rhcl-operator (Kuadrant). A zero-subscription state is
   unholdable: the catalog operator recreates the subscription within
   seconds of deletion. Delete-and-recreate as a pinning method loses the
   race every time. Pin by patching the live subscription in place.

3. **CRD stored-version guard.** The v3.4.0 install left
   ztunnels.sailoperator.io with `v1` as a stored version; the v3.1.0
   CRD does not serve `v1`, so OLM refused the replacement ("risk of
   data loss"). Verified zero Ztunnel CRs existed, deleted the CRD, and
   the next fresh plan ran clean. Istio/IstioRevision CRDs were
   compatible across versions and untouched.

## What worked

Keep the pinned subscription in place; delete stranded plans and
stillborn CSVs; clear the CRD conflict; let one genuinely fresh install
plan (install-xnz4r) create the full owned set: ServiceAccount,
deployment, CSV to Succeeded. The operator then adopted the running mesh
with zero pod restarts (istiod and all gateway pods retained 7h+ ages).
Validation: Gateway API mutation (label) persisted with Reconciled=True;
UC02 smoke test PASS. No RHOAI operator quiesce was required; that step
remains specific to the (different) two-controller deadlock scenario.

## Finding: Manual approval is not a brake in shared-resolution namespaces

v3.1.0 plans repeatedly arrived pre-approved despite
installPlanApproval: Manual on the servicemesh subscription. Install
plan approval is effectively shared across subscriptions that OLM
resolves together in a namespace; Kuadrant's generated subscriptions
participate in the same resolution. This retroactively explains how
install-kkl59 swept the servicemesh v3.4.0 upgrade through without any
servicemesh plan being individually approved.

Approval-mode sweep of openshift-operators subscriptions:
[PASTE SWEEP OUTPUT]

## Standing fixtures on this environment

- One unapproved v3.4.0 channel-head install plan persists permanently
  (duplicate deleted). It must never be approved.
- Label recovery-validated=2026-07-28 left on data-science-gateway as
  the recovery marker.

## Incidental finding

maas-default-gateway runs on maas-gateway-class (OpenShift ingress
gateway controller), not the RHOAI/Istio controller. The MaaS path has
no dependency on the servicemesh operator's health. Relevant to
ADR-0003.
