# Rebuild guide

The environment is throwaway. This is the whole rebuild, assuming a fresh RHDP cluster with RHOAI. Everything here is repo state; nothing depends on notes, memory or a previous session's shell.

## 1. Prerequisites (once per laptop)

```bash
brew install minio/stable/mc gettext && brew link --force gettext
brew install pipx && pipx ensurepath
pipx install ansible-core
pipx install "huggingface_hub[cli]"

# Python deps for synthetic data generation. Install for the SAME python3 the
# seed scripts run under (your system python3, NOT Ansible's pipx venv).
python3 -m pip install --user pyyaml reportlab --break-system-packages
python3 -c "import yaml, reportlab; print('deps ok')"
```

## 2. Log in and set credentials

```bash
oc login --token=<token> --server=<api-url>

export MINIO_ACCESS_KEY='minio-admin'
export MINIO_SECRET_KEY='<choose-a-password>'    # quote it; a trailing ! breaks unquoted
export POSTGRES_PASSWORD='<choose-a-password>'   # Llama Stack metadata store (RHOAI 3.2+)
export HF_TOKEN='<hf-token>'

# Only needed for the optional MaaS phases (ADR-0003). This password is
# embedded in a postgresql:// connection URL, so avoid @ / : ? # < >
export MAAS_DB_PASSWORD='<choose-a-simple-password>'
```

Keep these in ONE terminal tab for the whole run. Lost exports were the single biggest time sink in the first live session.

## 3. Bootstrap

Operator activation is handled by the bootstrap; there are no console steps. RHDP catalog images ship Llama Stack and TrustyAI as `Removed`, so their CRDs do not exist and the llama-stack/guardrails manifests cannot apply. The bootstrap patches the DataScienceCluster and waits for the CRDs before applying anything that depends on them.

```bash
cd 02-complaint-intelligence
./scripts/bootstrap.sh
```

Verify afterwards if you want reassurance:

```bash
oc get crd | grep -iE "llamastackdistributions|guardrailsorchestrators"
```

The script guards every failure mode from the first session: missing envsubst, empty credentials, unsubstituted placeholders, wrong active project, and MinIO running stale credentials. If it exits with an error, the message tells you what to fix; it will not leave a half-broken cluster behind.

## 4. Seed

    ansible-playbook ansible/site.yml

Discovers the MinIO Route itself, downloads the model (~16GiB, roughly 15 to 20 minutes), mirrors it into MinIO, restarts the predictor once weights are confirmed complete, waits for it to be ready, then restarts Llama Stack so it discovers the now-ready model. Fully automated; no manual pod restarts or verification steps needed after this command finishes.

## 5. Verify

```bash
oc port-forward svc/granite-3-3-8b-instruct-predictor 8081:80 &
sleep 3
curl -s http://localhost:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"granite-3-3-8b-instruct","messages":[{"role":"user","content":"Say: ready"}],"max_tokens":10}'
```

## 6. Start the workbench

```bash
oc apply -f manifests/workbench/workbench.yaml -n complaint-intelligence
oc get pods -n complaint-intelligence -l notebook-name=complaint-intelligence-workbench -w
```

Wait for `1/1 Running`, then confirm the taxonomy mount:

```bash
oc exec -n complaint-intelligence complaint-intelligence-workbench-0 -- ls /opt/app-root/taxonomy
```

External access via the RHOAI dashboard and the Gateway URL does not work on this platform version (see "Do not" and the troubleshooting table). Use port-forward instead:

```bash
oc port-forward svc/complaint-intelligence-workbench -n complaint-intelligence 8888:80
```

Open `http://localhost:8888`. Get the login token:

```bash
oc logs complaint-intelligence-workbench-0 -n complaint-intelligence | grep -i token
```

## 7. Verify the pipeline

```bash
WORKBENCH_POD=$(oc get pods -n complaint-intelligence \
  -l notebook-name=complaint-intelligence-workbench \
  -o jsonpath='{.items[0].metadata.name}')

oc exec $WORKBENCH_POD -n complaint-intelligence -- \
    pip install --quiet requests pyyaml minio --break-system-packages
oc exec $WORKBENCH_POD -n complaint-intelligence -- \
    python3 /opt/app-root/pipeline/smoke_test.py
```

All checks should print PASS. This is the single go/no-go gate for a rebuild: if it fails, the failure message names the specific broken stage (taxonomy mount, model discovery, vector store, guardrails, or the model call itself) rather than requiring notebook archaeology to find it.

## 8. Build and deploy the app

Requires step 4 to have fully completed, not just the complaints bucket seeded: `Pipeline().setup()` runs at container startup and discovers the model and creates the vector store, both only exist once the whole `ansible-playbook` run (including `sync_llama_stack`) has succeeded. Deploying before that finishes will crash-loop.

```bash
oc apply -f manifests/app/buildconfig.yaml -n complaint-intelligence
oc start-build complaint-intelligence-app -n complaint-intelligence --follow
```

Wait for the build to complete (`--follow` streams the log; a failed build shows here, not as a confusing pod-level error later). Then:

```bash
oc apply -f manifests/app/deployment.yaml -n complaint-intelligence
oc apply -f manifests/app/route.yaml -n complaint-intelligence
oc get pods -n complaint-intelligence -l app=complaint-intelligence-app -w
```

Wait for `1/1 Running`. Get the URL:

```bash
oc get route complaint-intelligence-app -n complaint-intelligence \
  -o jsonpath='{.spec.host}'
```

Open `https://<that-host>` in a browser. If the evidence bucket is still empty at this point (no batch run yet), the dashboard and review queue show their empty states correctly rather than erroring, that is expected, not a bug; classify a complaint via `/classify` or run the notebook's batch cell to populate real data.

## 9. Populate and classify

Two ways to do this, same underlying logic either way (ADR-0009, both call `pipeline/classify.py` directly).

**Recommended: the automated Job.** Requires step 8 (the app image) to have completed, it reuses that image. No workbench, no notebook.

```bash
oc create -f manifests/job/batch-classify.yaml -n complaint-intelligence
oc get jobs -n complaint-intelligence -w
```

Get the pod name from the job, then follow its logs:

```bash
oc logs -f job/<generated-name> -n complaint-intelligence
```

Expect, in order: `Taxonomy: 17 new documents added.`, `Complaints: 200 new documents added (...)`, then `Done. Classified: 200, Skipped: 0, Failed: 0`. Idempotent, safe to re-trigger any time (after a data change, a pipeline fix, or just to confirm the environment is healthy); already-populated data is correctly skipped, not reprocessed.

Each trigger creates a new Job object (`generateName`, not a fixed name), so they accumulate. Clean up old ones occasionally:

```bash
oc delete jobs -n complaint-intelligence -l app.kubernetes.io/part-of=rhoai-presales-lab --field-selector status.successful=1
```

**Alternative: run the notebook manually**, useful for debugging cell-by-cell or exploring the pipeline interactively. Open the workbench, run `01-classify-complaint.ipynb` top to bottom. Cells 6-7 populate the vector store; Cell 9 runs the same classification loop the Job runs. Either way, once done, refresh the app so it shows the new data:

```bash
oc get route complaint-intelligence-app -n complaint-intelligence \
  -o jsonpath='{.spec.host}'
```

Open `https://<host>/refresh`, or use "Refresh" in the app's nav.

## Optional: Models-as-a-Service (ADR-0003)

Not part of the standard rebuild. Only relevant if evaluating the Economics pillar.

**Run MaaS phases only after step 7's smoke test passes.** The core build has zero Service Mesh dependency (confirmed 2026-07-28: maas-default-gateway runs on the OpenShift ingress gateway controller, and the demo path uses Routes and service DNS). Keeping the two failure domains separated means a servicemesh guard trip cannot be confused with a broken core build.

    chmod +x scripts/setup-maas-phase1.sh scripts/setup-maas-phase2.sh scripts/setup-maas-phase3.sh

### Phase 1: prerequisites

    ./scripts/setup-maas-phase1.sh

Review the "pending install plans" listing partway through the output; it should show only the LWS plan being acted on.

### Phase 2: Kuadrant stack (isolated namespace)

    ./scripts/setup-maas-phase2.sh

Installs the RHCL/Kuadrant stack into its own namespace (`kuadrant-system`, created by the script with an OperatorGroup), plus the dedicated `maas-gateway-class` and `maas-default-gateway`. Namespace isolation is the prevention control: OLM resolution is per-namespace, so plans generated in kuadrant-system cannot bundle the servicemesh upgrade that is permanently pending in openshift-operators (the mechanism behind both 2026-07-28 incidents; see DEPLOYMENT-LOG-2026-07-29). The script inspects the install plan's contents before approving (detection), verifies Service Mesh is unchanged afterwards, and checks for duplicate controllers. If any guard trips, stop and open RUNBOOK-servicemesh-recovery.md.

A clean run ends with three guard confirmations (Service Mesh unchanged at v3.1.x, operator deployment present, no duplicate controllers) followed by the manual-steps block.

Note that `authorino-operator` installs in `openshift-operators`, not `kuadrant-system`: the platform installs it for kserve, and because it is AllNamespaces, OLM resolves RHCL's dependency against that existing install rather than creating a second copy. A resolver-generated authorino subscription may exist in kuadrant-system with no CSV; that is correct, not a fault. The scripts check for it cluster-wide.

### Phase 2 manual steps: Kuadrant CR and Authorino TLS

Printed by the script; not yet automated. Validated in this exact sequence on two environments (2026-07-28 and 2026-07-29).

**Step 1: create the Kuadrant CR**

```bash
oc apply -f manifests/maas/kuadrant-cr.yaml
```

Gate (allow about a minute):

```bash
oc get kuadrant -n kuadrant-system \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expect `True`. The Authorino and Limitador instances are created by this CR and land in `kuadrant-system` (confirmed; the `rh-connectivity-link` namespace referenced in upstream docs is a different install topology).

**Step 2: Authorino TLS bootstrap**

```bash
oc annotate service authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
```

Gate: `oc get secret authorino-server-cert -n kuadrant-system` returns a `kubernetes.io/tls` secret within about ten seconds. Then:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge \
  --patch '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'

oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

oc rollout status deployment/authorino -n kuadrant-system --timeout=120s
```

Gate: the Authorino log shows both the gRPC auth service (port 50051) and HTTP auth service (port 5001) starting with `tls:true`. The OIDC service on 8083 is plain by design.

```bash
oc logs deployment/authorino -n kuadrant-system --tail=20
```

The Gateway's `security.opendatahub.io/authorino-tls-bootstrap` annotation (already applied by `gateway.yaml` in phase 2) is an interim mechanism pending native Gateway-to-Authorino TLS support (CONNLINK-528). Worth stating honestly in any customer production-timeline conversation.

### Phase 3: MaaS platform

    export MAAS_DB_PASSWORD='<choose-a-simple-password>'
    ./scripts/setup-maas-phase3.sh

Deploys a dedicated PostgreSQL in `maas-platform`, creates the `maas-db-config` secret in `redhat-ods-applications` (single key `DB_CONNECTION_URL`), enables `modelsAsService` under the kserve component in the DataScienceCluster, and gates on the MaaS Tenant CR reaching Ready. Guards check the phase 2 prerequisites cluster-wide (all four operators Succeeded as real installs in whichever namespace they legitimately occupy), including a Ready Kuadrant CR, so it fails clearly if the manual steps above were skipped. Idempotent; safe to re-run.

Expected end state:

```bash
oc get pods -n redhat-ods-applications | grep -i maas
```

`maas-api` and `maas-controller` Running, plus a `maas-api-key-cleanup` CronJob on a 15-minute schedule (API key expiry enforcement; default key lifetime is 90 days).

What MaaS creates on enablement: `gateway-default-deny` (TokenRateLimitPolicy), `gateway-default-auth` (AuthPolicy) on the gateway, and `maas-api-auth-policy` protecting maas-api. Note that tiers are **not** shipped as CRs; the platform's out-of-box posture is deny-by-default and tier policies (PlanPolicy, TokenRateLimitPolicy) are authored deliberately. Model registration and tier authoring are Phase 4, not yet built.

### Phase 4: publish a model and subscribe

    ./scripts/setup-maas-phase4.sh

Deploys Qwen3-0.6B as an `LLMInferenceService` that opts in to the MaaS gateway, publishes it with a `MaaSModelRef`, and attaches a `MaaSSubscription` carrying a token budget, billing rate and cost-centre metadata. Gates on the model serving, the MaaSModelRef reaching Ready, and the subscription reconciling into a `TokenRateLimitPolicy`.

First run is slow: the model pulls from Hugging Face. The model co-tenants on the single L4 with UC02's Granite and is constrained to roughly 9% of the card; it requests no `nvidia.com/gpu` deliberately, since Granite holds the only GPU and a resource request would leave it Pending forever.

Verify deny-by-default (expect **403**, no credentials):

```bash
GW=https://$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')

curl -sk -o /dev/null -w "%{http_code}\n" \
  -X POST "$GW/maas-models/qwen3-06b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```

Model discovery through maas-api:

```bash
curl -sk "$GW/v1/models" -H "Authorization: Bearer $(oc whoami -t)"
```

Consumption paths are `/{namespace}/{model}/v1/chat/completions` (also `/v1/completions` and `/v1/responses`), created automatically when the model is published.

`-k` is required and the address must be read from the Gateway status: wildcard DNS for `*.apps` points at the default ingress router, not at this gateway's load balancer, so the listener carries no hostname and the wildcard certificate does not match the address. A customer environment resolves this with a DNS record or a Kuadrant DNSPolicy.

Then confirm the whole governance chain end to end:

```bash
./scripts/maas-demo-verify.sh
```

Seven checks: unauthenticated denied (403), model discovery, OpenShift
token rejected on inference (401, k8s tokens are scoped to /v1/models by
policy), API key issuance, authenticated inference with token accounting,
budget exhaustion (429), and revocation (403). Takes about two minutes,
most of it waiting out the 60-second key-validation cache.

Three CRs make up the chain and all three are required: **MaaSModelRef**
publishes, **MaaSAuthPolicy** grants access, **MaaSSubscription** meters
and limits. Without the auth policy the model is Ready and subscribed but
`/v1/models` returns an empty list with no error.

**Do not run any phase without the previous one confirmed clean.** See `DEPLOYMENT-LOG-2026-07-28-servicemesh-incident.md`, `DEPLOYMENT-LOG-2026-07-28-servicemesh-recovery.md` and `DEPLOYMENT-LOG-2026-07-29-kuadrant-namespace-isolation.md` for why this matters.

## Do not

- **Do not `oc expose`** anything in this namespace. Argo prunes it (ADR-0005). Network edge = a manifest.
- **Do not port-forward for the model upload.** It drops on multi-GiB transfers. The Route exists for this.
- **Do not put secret templates under `manifests/`.** Argo applies them raw (ADR-0005).
- **Do not put phase-specific secret templates directly in `secrets/`.** Bootstrap renders `secrets/*.template.yaml` non-recursively and applies everything to `complaint-intelligence`. Templates targeting other namespaces (MaaS: `maas-platform` and `redhat-ods-applications`) live in `secrets/maas/` and are rendered by their own phase script. Confirmed 2026-07-29: a MaaS template left in `secrets/` aborts bootstrap on a namespace mismatch.
- **Do not activate operators through the console.** The bootstrap patches the DataScienceCluster. A console click is an undocumented manual step and will not survive a rebuild.
- **Do not trust `oc get applications`.** Use `oc get applications.argoproj.io`; the short name can resolve to a different CRD.
- **Do not use the RHOAI dashboard's Open button for this workbench.** Broken on 3.4.2 for hand-applied Notebook objects; use port-forward (step 6).
- **Do not add a Route to work around the broken Gateway URL.** A controller-generated NetworkPolicy blocks it by design; port-forward is the only working path.
- **Do not re-run `ansible-playbook ansible/site.yml` after the vector store has been created and populated.** `sync_llama_stack` restarts the Llama Stack pod every run. If that restart lands before the vector store's registration has durably persisted, Milvus's search index loses track of the store, file listings and uploads still work, search silently returns zero results (`VectorStoreNotFoundError` in the pod logs, not visible from the notebook side). Safe on a fresh rebuild: the playbook completes fully before the notebook creates the store. Only a risk if re-running the playbook after the notebook has already populated data. If something genuinely needs re-seeding at that point, delete and recreate the vector store afterward rather than trusting it survived the restart.
- **Do not blanket-approve pending install plans** (`oc get installplan -o name | xargs -I{} oc patch {} ... approved:true` or similar). This approves _every_ pending plan across every operator, not just the one you're waiting on. Confirmed live (2026-07-28): approving a single pending LWS install plan this way also silently approved an unrelated, unplanned Service Mesh upgrade (v3.1.0 → v3.4.0, three minor versions), which broke Gateway API reconciliation cluster-wide (RHOAI 3.4.2's own gateway controller pins the Istio CR to a version the new operator refuses to install as end-of-life). Recoverable by hand, but only via RUNBOOK-servicemesh-recovery.md; the original attempt failed on ordering and unknown blocker depth. Always target a specific install plan by name, found first via a scoped query:
- **Do not request `nvidia.com/gpu` for the MaaS demonstration model.** The NVIDIA runtime exposes the device regardless of resource requests, so the pod sees `cuda:0` without asking. Granite holds the only card, so a resource request leaves the pod Pending forever. Constrain vLLM's memory fraction instead (`--gpu-memory-utilization`), and expect a CrashLoopBackOff with `Free memory on device cuda:0 ... less than desired GPU memory utilization` if the fraction is too high. Confirmed 2026-07-31.
- **Do not add a hostname to the maas-default-gateway listener.** Wildcard DNS for `*.apps` resolves to the default ingress router, not to this gateway's load balancer, so a hostname routes traffic to the wrong LB. Read the address from `.status.addresses[0].value`. Confirmed 2026-07-31.
- **Do not remove the `allowedRoutes` selector from the gateway listener.** It is the control on which namespaces may publish models under governance. Both `maas-models` and `redhat-ods-applications` must carry `maas.opendatahub.io/publish=true`; the second is applied by phase 3 and without it the platform's own `/v1/models` route silently fails to attach.

```bash
  oc get installplan -n openshift-operators -o json | python3 -c "
  import json, sys
  data = json.load(sys.stdin)
  for item in data['items']:
    if '<expected-csv-name>' in item['spec'].get('clusterServiceVersionNames', []):
      print(item['metadata']['name'])
  "
  oc patch installplan <that-specific-name> -n openshift-operators \
    --type merge -p '{"spec":{"approved":true}}'
```

- **Do not approve any pending Service Mesh install plan.** RHOAI 3.4.2 pins Istio v1.26.2; Service Mesh operator v3.4.0 refuses to install it (end-of-life). A pending v3.4.0 channel-head plan is a permanent fixture of every environment and must never be approved. Confirmed live twice (2026-07-28).
- **Do not install the Kuadrant/RHCL stack into `openshift-operators`.** Install plan approval is effectively shared across subscriptions OLM resolves together in a namespace, and openshift-operators permanently holds a fenced servicemesh v3.4.0 upgrade that any bundled plan sweeps in (install-kkl59, 2026-07-28; reproduced three times on 2026-07-29). Prevention is namespace isolation: the stack lives in kuadrant-system (handled by setup-maas-phase2.sh). The script's plan-content inspection is detection only. If either trips, stop and open RUNBOOK-servicemesh-recovery.md.
- **Do not touch the servicemesh subscription at all: no pinning, no channel edits, no deletion.** It is installed and managed by the cluster ingress operator as the platform's Gateway API implementation (confirmed 2026-07-29 via managedFields). Deletion is reverted within seconds; channel edits are overwritten. The platform's own spec (stable, Manual, startingCSV v3.1.0) is the correct state and is self-healing. The only interaction this build ever has with it is read-only verification.
- **Do not apply manifest directories wholesale** (`oc apply -f manifests/<dir>/`). Scripts apply named files. A directory apply is what swept the first incident's corrective manifest onto a fresh environment and detonated the second incident (ADR-0010).
- **Do not commit one-shot corrective manifests into applyable paths** (ADR-0010). Remediation is a runbook step, not a manifest.
- **Do not expect publishing a model to grant access to it.** MaaSModelRef publishes, MaaSAuthPolicy grants subjects access, MaaSSubscription meters them. Missing the auth policy produces an empty `/v1/models` list with HTTP 200 and no error message. Confirmed 2026-07-31.

## If something fails

| Symptom                                                               | Cause                                                                                                         | Fix                                                                                                                        |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `Access Key Id ... does not exist`                                    | MinIO running stale/placeholder credentials                                                                   | `oc exec deploy/minio -- env \| grep MINIO_ROOT`; if it shows `${...}`, re-render and `oc rollout restart deploy/minio`    |
| `Unauthorized` on every oc command                                    | Token expired (RHDP tokens are short)                                                                         | Fresh `oc login`                                                                                                           |
| Predictor `Init:CrashLoopBackOff`, log says `NoSuchBucket`            | Model not seeded yet                                                                                          | Expected before step 4; ignore                                                                                             |
| Predictor `Pending` forever                                           | GPU label mismatch                                                                                            | Check `nvidia.com/gpu.product` on nodes vs the InferenceService nodeSelector                                               |
| Route "created" then "not found"                                      | Created via `oc expose` in an Argo namespace                                                                  | Apply the committed manifest instead                                                                                       |
| `mc` TLS error over http                                              | Router forces edge TLS                                                                                        | The Ansible role falls back to https automatically                                                                         |
| `no matches for kind "LlamaStackDistribution"`                        | Component still `Removed`; CRD absent                                                                         | Bootstrap handles this; if hit manually, patch the DSC and wait for the CRD                                                |
| An operator looks missing or duplicated in `oc get csv`               | AllNamespaces CSVs are projected read-only into every namespace                                               | Filter copies: exclude any CSV carrying the `olm.copiedFrom` label; only unlabelled ones are real installs                 |
| Workbench URL returns 500 / "Application is unavailable"              | Gateway HTTPRoute port bug (3.4.2 controller defect)                                                          | Use port-forward (step 6), not the Gateway URL                                                                             |
| Dashboard shows "migration required, image unknown, deleted"          | Cosmetic; hand-applied Notebook lacks dashboard image-tracking annotations                                    | Ignore; check pod directly with `oc get pods -l notebook-name=complaint-intelligence-workbench`                            |
| App pod CrashLoopBackOff on startup                                   | Deployed before step 4 finished; Pipeline().setup() failed discovering the model or creating the vector store | Confirm ansible-playbook completed fully, then `oc rollout restart deployment/complaint-intelligence-app`                  |
| App build fails with "no such file: pipeline/classify.py"             | BuildConfig's contextDir or Containerfile COPY paths don't match                                              | Confirm `contextDir: 02-complaint-intelligence` in buildconfig.yaml and that Containerfile COPY paths are relative to that |
| Vector search returns 0 results despite files listed correctly        | Llama Stack restarted after the vector store was created; Milvus's search index lost its registration         | Delete the store (`DELETE /v1/vector_stores/<id>`), recreate via the notebook's Cell 10, repopulate via Cells 6-7          |
| Job fails: `can't open file '.../run_batch.py'`                       | App image was built before `pipeline/run_batch.py` existed                                                    | `oc start-build complaint-intelligence-app -n complaint-intelligence --follow`                                             |
| Bootstrap aborts: "namespace from the provided object does not match" | A phase-specific secret template is sitting in `secrets/` and got picked up by the non-recursive render       | Move it to its phase subdirectory (MaaS: `secrets/maas/`) and update that phase script's envsubst path                     |
| setup-maas-phase2.sh FAIL: plan bundles servicemesh outside v3.1.x    | Kuadrant dependency resolution pulled the channel-head servicemesh upgrade into the RHCL plan                 | Stop; RUNBOOK-servicemesh-recovery.md. If already approved (shared approval), check CSV state immediately: Path A likely   |
| setup-maas-phase2.sh FAIL: CSV present but no operator deployment     | ServiceAccount/RBAC garbage-collected by a prior downgrade; stranded approved plans block recreation          | RUNBOOK-servicemesh-recovery.md, Path B (validated 2026-07-28)                                                             |
| Phase 3 FAIL: no Ready Kuadrant CR in kuadrant-system                 | Phase 2's manual steps (Kuadrant CR, TLS bootstrap) not completed                                             | Run them per the MaaS section above, confirm Ready, re-run phase 3                                                         |
| Phase 3 FAIL: Tenant did not reach Ready                              | Usually maas-db-config connection string wrong or database unreachable                                        | `oc logs deployment/maas-api -n redhat-ods-applications`; check DB_CONNECTION_URL and that maas-postgres is Running        |
| maas-postgres `ImagePullBackOff`                                      | `registry.redhat.io/rhel9/postgresql-16` not pullable on this cluster                                         | Swap to the same PostgreSQL image the Llama Stack deployment uses; it is proven to pull on this platform                   |
| curl returns `000` against the gateway                                | Listener has no resolvable TLS certificate; TCP connects then the handshake is dropped                        | Confirm `certificateRefs` in gateway.yaml and that the secret exists in openshift-ingress                                  |
| LLMISVC stuck `HTTPRoutesNotReady`                                    | Route rejected by the listener: namespace not permitted                                                       | Check the HTTPRoute status for `NotAllowedByListeners`; label the namespace `maas.opendatahub.io/publish=true`             |
| `/v1/models` returns 404                                              | `maas-api-route` not attached: `redhat-ods-applications` missing the publish label                            | `oc label namespace redhat-ods-applications maas.opendatahub.io/publish=true --overwrite` (phase 3 does this)              |
| Model pod CrashLoopBackOff, log shows `Free memory on device cuda:0`  | Another workload holds most of the GPU; vLLM defaults to reserving 90%                                        | Lower `--gpu-memory-utilization` in manifests/maas/model-qwen.yaml                                                         |
