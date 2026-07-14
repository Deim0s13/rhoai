# ADR-0005: Secret rendering and the GitOps boundary

**Status:** Accepted
**Date:** 2026-07-14

## Context

The lab holds two principles that collide in practice: no credentials in Git
(secrets are rendered from templates via `envsubst` at deploy time), and GitOps
manages declarative state (Argo CD syncs `manifests/` with `prune: true` and
`selfHeal: true`).

During the first live UC02 deployment the collision cost most of a session.
The secret templates lived inside `manifests/storage/`, `manifests/serving/`
and `manifests/llama-stack/`, which are exactly the paths Argo syncs. Argo does
not run `envsubst`. It applied the template files verbatim, so the cluster
received secrets containing the literal strings `${MINIO_ACCESS_KEY}` and
`${MINIO_SECRET_KEY}`, and MinIO started with those as its root credentials.
Worse, `selfHeal` re-applied the raw templates within seconds of every correct
manual render, so the credentials never survived long enough to be used.

The presenting symptom was misleading: `mc` reported "The Access Key Id you
provided does not exist in our records" while the secret template in Git looked
perfectly correct.

A second instance of the same boundary problem: `oc expose service minio`
copies the Service's labels onto the new Route, including Argo's tracking
label. Argo then saw a tracked resource absent from Git and pruned it within
seconds, producing "route exposed" immediately followed by "route not found".

## Decision

Draw the boundary explicitly and enforce it in the layout.

1. **Secret templates live in `secrets/`, outside every Argo-synced path.**
   Nothing under `manifests/` is ever a template. Argo syncs `manifests/`;
   `scripts/bootstrap.sh` renders `secrets/`.
2. **The bootstrap refuses to apply an unsubstituted render.** It checks that
   `envsubst` exists, that the credential variables are set and non-empty, and
   that no `${...}` survives into the rendered output. A placeholder reaching
   the cluster is now impossible rather than merely unlikely.
3. **In an Argo-managed namespace, resources are created through Git, never
   through `oc expose` or ad-hoc `oc create`.** The MinIO Route is a committed
   manifest (`manifests/storage/minio-route.yaml`), not a command in a runbook.
4. **The bootstrap restarts MinIO after rendering.** `envFrom` reads a secret
   only at container start, so a secret applied after the pod started has no
   effect until a rollout.

## Consequences

- The two principles now coexist: GitOps owns declarative state, the bootstrap
  owns credential rendering, and the paths make the split obvious to anyone
  reading the repo.
- Any future use case mixing GitOps with `envsubst` inherits this layout. This
  is a lab-wide lesson, not a UC02 quirk, and is a candidate for promotion to
  a repo-level convention once UC03 exists.
- Manual `oc expose` is effectively banned in Argo-managed namespaces. Anything
  needed at the network edge must be a manifest.
- Diagnostic aid for the future: "credentials look right in Git but the running
  workload rejects them" should send the reader straight to
  `oc exec deploy/<name> -- env | grep <VAR>`. If it shows a literal `${...}`,
  this ADR is the explanation.
