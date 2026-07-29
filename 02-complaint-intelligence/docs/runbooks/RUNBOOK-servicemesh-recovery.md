# Runbook: Service Mesh operator recovery (RHOAI 3.4.2)

Two distinct failure modes, two paths. Diagnose first: the same surface
symptoms (Gateways healthy, mesh serving) appear in both, because istiod
and gateway pods are operands and keep coasting without an operator.

## Diagnosis

    oc get csv -n openshift-operators -o json | python3 -c "
    import json, sys
    data = json.load(sys.stdin)
    for i in data['items']:
        if 'servicemesh' in i['metadata']['name'].lower():
            print(i['metadata']['name'], '-', i['status']['phase'], '-', i['status'].get('reason',''))
    "
    oc get deployment -n openshift-operators | grep -i servicemesh
    oc get istio -A -o jsonpath='{.items[0].status.conditions}' | python3 -m json.tool

- CSV Succeeded + deployment Running + Istio CR ReconcileError about an
  unsupported/end-of-life version -> **Path A** (deadlock).
- CSV Pending (RequirementsNotMet) + NO deployment -> **Path B**
  (downgrade damage, operator absent).

Timebox either path to 45 minutes; rebuild-from-repo is always the
escape hatch.

## Path A: two-controller deadlock (NOT yet validated live)

Operator upgraded past RHOAI's pinned Istio version; RHOAI reasserts,
operator refuses. Every action must happen with the reasserting
controller stopped.

1. Quiesce RHOAI: identify the manager of Istio spec.version via
   managedFields, scale that operator deployment to 0. Verify with a
   test annotation that survives 60s.
2. Clean OLM completely: delete subscription, ALL servicemesh CSVs, ALL
   servicemesh-only install plans.
3. Normalise CRs: every Istio/IstioRevision must carry a version the
   target operator's CRD accepts. Patch (nothing reverts now) or
   `oc delete istiorevision <name> --cascade=orphan`.
4. Reinstall pinned (subscription below), approve the ONE fresh plan by
   name.
5. Scale RHOAI back up; it reasserts against an operator that accepts
   the version. Verify Istio CR healthy, Gateways PROGRAMMED.

## Path B: downgrade damage (VALIDATED 2026-07-28)

An OLM downgrade garbage-collected the ServiceAccount/RBAC; stranded
approved plans block recreation. Three stacked blockers; clear in order.
No RHOAI quiesce needed.

1.  **Do not delete the servicemesh subscription, and do not try to re-pin
    it.** It is installed and managed by the cluster ingress operator as
    the platform's Gateway API implementation; deletion is reverted
    within seconds and channel edits are overwritten (confirmed
    2026-07-29 via managedFields). The platform's own spec (stable,
    Manual, startingCSV v3.1.0) is the correct state. Verify it rather
    than fight it:

        oc get subscription servicemeshoperator3 -n openshift-operators \
          -o jsonpath='{.spec.channel}{" "}{.spec.installPlanApproval}{" "}{.spec.startingCSV}{"\n"}'

2.  Delete every stranded servicemesh-only install plan (approved AND
    unapproved; approved ones are the poison, they carry false
    "already created" state) and any Pending/stillborn CSV. Never touch
    plans bundling other operators (LWS, Kuadrant).
3.  If the next plan fails with a CRD stored-version error ("new CRD
    removes version ... stored version"): confirm zero CRs of that kind
    exist (`oc get <kind> -A`), then delete the CRD. Repeat per CRD
    named; OLM reports one per failure.
4.  A fresh plan (never-seen name) generated against the pinned
    subscription creates the full owned set. Approve it by name. Success
    = CSV Succeeded AND deployment Ready AND
    `oc get sa servicemesh-operator3 -n openshift-operators` found.
5.  Verify adoption without churn: Istio CR Reconciled/Ready True,
    IstioRevision Healthy, Gateways PROGRAMMED, operand pod ages
    unchanged. Then prove it with a mutation (label a Gateway, confirm
    it persists) and the UC02 smoke test.

## Reference subscription (one-shot, human-applied only; see ADR-0010)

    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: servicemeshoperator3
      namespace: openshift-operators
    spec:
      channel: stable
      name: servicemeshoperator3
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      startingCSV: servicemeshoperator3.v3.1.0
      installPlanApproval: Manual

## Prevention (supersedes recovery where applicable)

Both failure modes share one root: bundled install plans in
openshift-operators sweeping the fenced servicemesh v3.4.0 upgrade into
an approved plan. Prevention is structural: install the Kuadrant/RHCL
stack in its own namespace (kuadrant-system, empty-spec OperatorGroup,
AllNamespaces mode). Plans generated there cannot bundle servicemesh.
See setup-maas-phase2.sh and
DEPLOYMENT-LOG-2026-07-29-kuadrant-namespace-isolation.md. Plan-content
inspection in the script remains as the detection layer.
