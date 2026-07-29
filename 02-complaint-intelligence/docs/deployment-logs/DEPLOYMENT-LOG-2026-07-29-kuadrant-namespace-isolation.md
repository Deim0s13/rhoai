# Deployment log: 2026-07-29 (Kuadrant namespace isolation, ADR-0003 unblocked)

Fresh environment, rebuilt clean from repo (smoke test all PASS, batch Job
complete). Phase 2's plan-content guard correctly refused three successive
RHCL install plans, each bundling servicemeshoperator3.v3.4.0. This session
diagnosed why, corrected two misattributions from the 2026-07-28 recovery,
and landed the first clean RHCL install across three attempts. Option 1
(platform-native MaaS) is viable. The fix was namespace isolation.

---

## Finding 1: the servicemesh subscription is managed by the cluster ingress operator

A channel pin (`stable` to `stable-3.1`) patched onto the servicemesh
subscription reverted within 90 seconds, with `status: UpgradePending`.
managedFields attribution:

    olm              Update  2026-07-28T22:31:55Z
    ingress-operator Update  2026-07-29T01:19:59Z
    catalog          Update  2026-07-29T01:23:05Z

The cluster ingress operator owns this subscription: it installs it as the
platform's Gateway API implementation, asserts channel `stable`, Manual
approval, and startingCSV v3.1.0, and reverts foreign edits. This corrects
two conclusions from the 2026-07-28 recovery:

- The "resolver-driven subscription resurrection" was the ingress operator
  recreating its own subscription, not the catalog resolver acting for
  rhcl-operator. The recreated spec matched the rollback manifest because
  both describe the platform's actual desired state.
- "Pin by patching in place" is not a viable control; the ingress operator
  reverts it. The correct posture: the platform pins this subscription
  itself. Leave it alone entirely.

The pending v3.4.0 upgrade plan is permanently fenced by the platform's
own Manual setting. The only route by which v3.4.0 can install is a
bundled plan approved via another subscription in the same namespace,
which is the precise mechanism of both prior incidents.

## Finding 2: rhcl-operator declares no servicemesh dependency

The rhcl-operator packagemanifest (channel stable, rhcl-operator.v1.4.2)
carries no dependencies annotation. The persistent bundling of
servicemesh v3.4.0 into RHCL install plans was OLM namespace mechanics:
plans generated in `openshift-operators` sweep in every pending
resolution in that namespace, including the fenced servicemesh upgrade.
The contamination was positional, not architectural. The earlier
hypothesis (RHCL requires Service Mesh 3.4) is refuted.

## Finding 3: namespace isolation resolves it

rhcl-operator supports only AllNamespaces install mode. Test performed:

1. Created `kuadrant-system` with an empty-spec OperatorGroup
   (AllNamespaces mode).
2. Deleted the stale rhcl-operator subscription from
   `openshift-operators`.
3. Created the rhcl-operator subscription in `kuadrant-system`
   (channel stable, Manual).
4. Generated plan `install-p8fxz`: limitador v1.4.1, authorino v1.4.2,
   rhcl v1.4.2, dns-operator v1.4.1. **No servicemesh.**
5. Cleaned residual Kuadrant-family subscriptions and CSVs from
   `openshift-operators` (authorino real install plus resolver-generated
   dns/limitador subscriptions), preventing duplicate AllNamespaces
   controllers.
6. Approved install-p8fxz by name after content inspection.

Result: four CSVs Succeeded in kuadrant-system; servicemesh untouched
(v3.1.0, deployment undisturbed at 3h6m). Kuadrant-family CSVs visible in
other namespaces carry `olm.copiedFrom: kuadrant-system` (normal
AllNamespaces projections, not duplicate installs).

## End state

- openshift-operators subscriptions: leader-worker-set, pipelines,
  servicemeshoperator3 (platform-managed). Nothing else.
- kuadrant-system: rhcl v1.4.2, authorino v1.4.2, limitador v1.4.1,
  dns-operator v1.4.1, all Succeeded.
- Service Mesh: v3.1.0 Succeeded, operator running, Istio Healthy at
  v1.26.2, all gateways PROGRAMMED.
- Core UC02: smoke test all PASS on this environment.
- Remaining for ADR-0003: Kuadrant CR in kuadrant-system, Authorino TLS
  bootstrap, gateway annotation (the documented manual steps, run once
  live on 2026-07-28's environment).

## Lessons

1. Shared-namespace OLM resolution is the root mechanism of both
   incidents and the phase 2 blockage. Third-party operator stacks get
   their own namespace and OperatorGroup. This is prevention; plan
   content inspection remains the detection layer.
2. Before fighting a controller for a resource, identify the controller.
   managedFields attribution took one command and dissolved two days of
   "resolver" theorising.
3. A refuted hypothesis is recorded, not deleted: the version-conflict
   theory was reasonable on the evidence available and its refutation is
   part of the record.
