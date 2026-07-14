# ADR-0006: Platform component activation belongs in the bootstrap

**Status:** Accepted
**Date:** 2026-07-14

## Context

RHDP catalog images provision RHOAI with Llama Stack and TrustyAI set to
`managementState: Removed`. Their CRDs
(`llamastackdistributions.llamastack.io`,
`guardrailsorchestrators.trustyai.opendatahub.io`) do not exist until those
components are `Managed`, so `manifests/llama-stack/` and
`manifests/guardrails/` fail to apply on a fresh cluster with "no matches for
kind".

During the first live deployment this was handled as a manual console step,
described in the runbook as "set both to Managed in the RHOAI console". That is
exactly the class of undocumented manual action the lab exists to eliminate:
it does not survive a rebuild, it cannot be reviewed, and it is invisible to
anyone reading the repository.

The console path also proved unreliable in practice (the setting did not take
on the first attempt), whereas patching the DataScienceCluster directly worked
first time and is verifiable.

## Decision

Component activation is part of the build, not part of the operator's memory.

1. `scripts/bootstrap.sh` patches the DataScienceCluster to set
   `llamastackoperator` and `trustyai` to `Managed`.
2. The bootstrap then **waits for the CRDs to appear** before applying any
   manifest that depends on them. Patching is asynchronous; the CRD is the
   real readiness signal, not the patch response.
3. Activation runs before the GitOps bootstrap (or the direct-apply fallback),
   because the llama-stack and guardrails Applications sync manifests that
   require those CRDs.
4. `REBUILD.md` contains no console instructions for activation.

## Consequences

- A fresh environment reaches the same state from the repository alone, with
  no clicking and no tribal knowledge.
- The bootstrap now requires permission to patch the DataScienceCluster
  (cluster-admin on RHDP sandboxes; already assumed by the rest of the script).
- If a future environment ships these components `Managed` already, the patch
  is a no-op and the CRD wait returns immediately. The step is idempotent and
  costs nothing.
- The CRD wait has a bounded timeout (180s) and fails loudly with the two
  diagnostic commands worth running, rather than letting a later manifest
  apply fail with a confusing error.
- Generalises: any RHOAI component a use case depends on should be activated
  and waited for in that use case's bootstrap. Candidate for promotion to a
  lab-wide convention once a second use case needs it.
