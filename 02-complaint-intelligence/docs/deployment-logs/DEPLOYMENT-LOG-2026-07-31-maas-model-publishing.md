# Deployment log: 2026-07-31 (MaaS model publishing, ADR-0003 Phase 4)

Published Qwen3-0.6B through MaaS on a clean environment (fourth build,
phases 1 to 3 reproduced without incident). Reached deny-by-default
enforcement proven at the gateway and a subscription reconciled into a
Kuadrant TokenRateLimitPolicy. Five blockers resolved on the way, all now
encoded in manifests or guards.

---

## The governance chain, end to end

1. `LLMInferenceService` (serving.kserve.io/**v1alpha2**) opts in via
   `router.gateway.refs` pointing at maas-default-gateway. Without that ref
   the model uses the default KServe gateway and no MaaS policy applies.
2. Publishing auto-creates an HTTPRoute (`qwen3-06b-kserve-route`) in the
   model namespace, bound to the gateway. No route authoring required.
   Paths are `/{namespace}/{model}/v1/chat/completions` (also
   `/v1/completions`, `/v1/responses`), rewritten to the backend `/v1/...`.
3. `MaaSModelRef` publishes it. `spec.modelRef` takes kind and name only,
   no namespace, so the ref must be co-located with the model.
4. `MaaSSubscription` reconciles into `maas-trlp-<model>`, a real
   TokenRateLimitPolicy in the model namespace, alongside the platform's
   `gateway-default-deny`.

Verified: unauthenticated POST to a published model returns **403**.
Deny-by-default is demonstrated, not asserted.

## Blockers resolved

**1. vLLM GPU co-tenancy.** The model CrashLoopBackOffed with
`Free memory on device cuda:0 (2.3/22.03 GiB) is less than desired GPU
memory utilization (0.9, 19.83 GiB)`. Granite (UC02) holds ~20 GiB of the
single L4. Note the pod requested no `nvidia.com/gpu` yet still saw
`cuda:0`: the NVIDIA runtime exposes the device regardless of resource
requests, so the pod scheduled and then tried to claim the whole card.
Adding a GPU resource request would make it Pending forever. Fix:
`VLLM_ADDITIONAL_ARGS=--gpu-memory-utilization 0.09 --max-model-len 2048
--enforce-eager` via the LLMISVC template. The serving image
(`vllm-cuda-rhel9`) is CUDA-only, so there is no CPU fallback.

Unmanaged GPU co-tenancy is a lab shortcut, not a production pattern: two
vLLM processes share the card by mutual agreement on memory fractions.
Production answers are MIG, time-slicing, or separate cards. Worth stating
in customer conversations: token budgets govern consumption, GPU capacity
allocation is a separate control needing its own answer.

**2. Gateway listener had no TLS.** `protocol: HTTPS` with no
`certificateRefs` accepts TCP then drops the handshake. Surfaces as curl
exit code 000, not an HTTP status. Fixed with
`tls.mode: Terminate` referencing `cert-manager-ingress-cert`, a genuine
ZeroSSL wildcard for `*.apps.<domain>` provisioned by the RHDP catalog
item (not by RHOAI). Guarded in phase 2.

**3. Platform defect: openshift-ai-inference gateway is broken.** It
reports `Programmed: False`, `InvalidCertificateRef`, referencing secret
`default-gateway-tls` which the platform never creates. This is almost
certainly the root cause of the broken RHOAI dashboard Gateway URL
recorded on 2026-07-22. Two symptoms, one bug. Worth raising internally.

**4. DNS split.** Wildcard `*.apps.<domain>` resolves to the default
ingress router LB, while maas-default-gateway has its own ELB. A hostname
on the listener would route traffic to the wrong load balancer, so the
listener carries no hostname and clients read
`.status.addresses[0].value`. Consequence: the wildcard cert does not
match the address, so `curl -k` is required in the lab. A customer
environment resolves this with a DNS record or a Kuadrant DNSPolicy (the
dns-operator is installed as part of the stack).

**5. allowedRoutes selector locked out the platform's own API route.**
The listener restricts attachment to namespaces labelled
`maas.opendatahub.io/publish=true`. `maas-api-route` lives in
`redhat-ods-applications`, so `/v1/models` returned 404 until that
namespace was labelled. Now applied in phase 3.

This is the selector working as intended: it surfaced an implicit
dependency that a `from: All` listener would have hidden. Good
illustration for the control-plane narrative, an explicit control catching
something rather than a permissive default letting it pass unnoticed.

## Schema findings (3.4)

- Tiers were replaced by **subscriptions** in 3.4. The 3.3 tier ConfigMap
  approach and the upstream ODH `alpha.maas.opendatahub.io/tiers`
  annotation are both stale.
- CRDs are `maas.opendatahub.io/v1alpha1`: MaaSModelRef, MaaSSubscription,
  MaaSAuthPolicy, ExternalModel, Tenant.
- `LLMInferenceService` is **v1alpha2**; upstream docs show v1alpha1.
- `tokenRateLimits.window` accepts s, m, h only. Days are not supported,
  use `24h`.
- **MaaSSubscription carries chargeback natively**: `billingRate.perToken`
  and `tokenMetadata` with `costCenter`, `organizationId` and arbitrary
  labels. Cost attribution is declarative configuration in Git, not
  something assembled from metrics afterwards. Strongest Economics pillar
  artefact found so far.
- `ExternalModel` is a first-class backend type, so MaaS can govern
  third-party providers (Bedrock, Anthropic, OpenAI) without hosting them.

## Open item

`GET /v1/models` returns HTTP 200 with an empty list
(`{"data":[],"object":"list"}`) despite MaaSModelRef Ready and the
subscription Active. Discovery works; the model is not appearing in it.
To investigate: whether discovery filters on subscription membership and
whether the caller's identity resolves to demo-subscription, and whether
maas-api expects an issued API key rather than a raw OpenShift token.

## Still to do in Phase 4

Token issuance through maas-api, an authenticated inference call returning
a `usage` block, budget exhaustion producing 429, and key revocation.
