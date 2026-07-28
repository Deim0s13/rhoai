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
```

Keep these in ONE terminal tab for the whole run. Lost exports were the single biggest time sink in the first live session.

## 3. Bootstrap

Operator activation is handled by the bootstrap; there are no console steps. RHDP catalog images ship Llama Stack and TrustyAI as `Removed`, so their CRDs
do not exist and the llama-stack/guardrails manifests cannot apply. The bootstrap patches the DataScienceCluster and waits for the CRDs before applying anything that depends on them.

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

**Recommended: the automated Job.** Requires step 9 (the app image) to have completed, it reuses that image. No workbench, no notebook.

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

    chmod +x scripts/setup-maas-phase1.sh scripts/setup-maas-phase2.sh

    ./scripts/setup-maas-phase1.sh

Review the "pending install plans" listing partway through the output; it should show only the LWS plan being acted on.

    ./scripts/setup-maas-phase2.sh

Installs RHCL (Kuadrant), the dedicated `maas-gateway-class` and `maas-default-gateway`. Stops after the operator install and prints the remaining manual steps (Kuadrant CR creation, Authorino TLS bootstrap), not yet scripted since this sequence has not been run end-to-end as of 2026-07-28. Follow the printed steps directly from `docs.redhat.com`'s "Configure TLS for Models-as-a-Service".

**Do not run Phase 2 without Phase 1 confirmed clean first**
(`scripts/setup-maas-phase1.sh` completing with no failures, Service Mesh
untouched). See `DEPLOYMENT-LOG-2026-07-28-servicemesh-incident.md` for
why this matters.

## Do not

- **Do not `oc expose`** anything in this namespace. Argo prunes it (ADR-0005). Network edge = a manifest.
- **Do not port-forward for the model upload.** It drops on multi-GiB transfers. The Route exists for this.
- **Do not put secret templates under `manifests/`.** Argo applies them raw (ADR-0005).
- **Do not activate operators through the console.** The bootstrap patches the DataScienceCluster. A console click is an undocumented manual step and will not survive a rebuild.
- **Do not trust `oc get applications`.** Use `oc get applications.argoproj.io`; the short name can resolve to a different CRD.
- **Do not use the RHOAI dashboard's Open button for this workbench.** Broken on 3.4.2 for hand-applied Notebook objects; use port-forward (step 7).
- **Do not add a Route to work around the broken Gateway URL.** A controller-generated NetworkPolicy blocks it by design; port-forward is the only working path.
- **Do not re-run `ansible-playbook ansible/site.yml` after the vector store has been created and populated.** `sync_llama_stack` restarts the Llama Stack pod every run. If that restart lands before the vector store's registration has durably persisted, Milvus's search index loses track of the store, file listings and uploads still work, search silently returns zero results (`VectorStoreNotFoundError` in the pod logs, not visible from the notebook side). Safe on a fresh rebuild: the playbook completes fully before the notebook creates the store. Only a risk if re-running the playbook after the notebook has already populated data. If something genuinely needs re-seeding at that point, delete and recreate the vector store afterward rather than trusting it survived the restart.
- **Do not blanket-approve pending install plans** (`oc get installplan -o
name | xargs -I{} oc patch {} ... approved:true` or similar). This approves _every_ pending plan across every operator, not just the one you're waiting on. Confirmed live (2026-07-28): approving a single pending LWS install plan this way also silently approved an unrelated, unplanned Service Mesh upgrade (v3.1.0 → v3.4.0, three minor versions), which broke Gateway API reconciliation cluster-wide (RHOAI 3.4.2's own gateway controller pins the Istio CR to a version the new operator refuses to install as end-of-life) and was not cleanly recoverable by hand. Always target a specific install plan by name, found first via a scoped query:
- **Do not approve any pending Service Mesh install plan.** RHOAI 3.4.2 pins Istio v1.26.2; Service Mesh operator v3.4.0 refuses to install it (end-of-life). A pending v3.4.0 channel-head plan is a permanent fixture of every environment and must never be approved. Confirmed live twice (2026-07-28).
- **Do not treat Manual approval on the servicemesh subscription as a
  sufficient brake.** Install plan approval is effectively shared across subscriptions OLM resolves together; Kuadrant's generated subscriptions participate in the same resolution and can sweep a servicemesh upgrade through inside a bundled plan (install-kkl59,2026-07-28). The post-install guard in setup-maas-phase2.sh is the real control.
- **Do not delete the servicemesh subscription to re-pin it.** It is an rhcl-operator dependency; the resolver recreates it within seconds,without your settings. Pin by patching the live subscription in place.
- **Do not commit one-shot corrective manifests into applyable paths**
  (ADR-0010). Remediation is a runbook step, not a manifest.

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

## If something fails

| Symptom                                                        | Cause                                                                                                         | Fix                                                                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `Access Key Id ... does not exist`                             | MinIO running stale/placeholder credentials                                                                   | `oc exec deploy/minio -- env \| grep MINIO_ROOT`; if it shows `${...}`, re-render and `oc rollout restart deploy/minio`    |
| `Unauthorized` on every oc command                             | Token expired (RHDP tokens are short)                                                                         | Fresh `oc login`                                                                                                           |
| Predictor `Init:CrashLoopBackOff`, log says `NoSuchBucket`     | Model not seeded yet                                                                                          | Expected before step 4; ignore                                                                                             |
| Predictor `Pending` forever                                    | GPU label mismatch                                                                                            | Check `nvidia.com/gpu.product` on nodes vs the InferenceService nodeSelector                                               |
| Route "created" then "not found"                               | Created via `oc expose` in an Argo namespace                                                                  | Apply the committed manifest instead                                                                                       |
| `mc` TLS error over http                                       | Router forces edge TLS                                                                                        | The Ansible role falls back to https automatically                                                                         |
| `no matches for kind "LlamaStackDistribution"`                 | Component still `Removed`; CRD absent                                                                         | Bootstrap handles this; if hit manually, patch the DSC and wait for the CRD                                                |
| Workbench URL returns 500 / "Application is unavailable"       | Gateway HTTPRoute port bug (3.4.2 controller defect)                                                          | Use port-forward (step 7), not the Gateway URL                                                                             |
| Dashboard shows "migration required, image unknown, deleted"   | Cosmetic; hand-applied Notebook lacks dashboard image-tracking annotations                                    | Ignore; check pod directly with `oc get pods -l notebook-name=complaint-intelligence-workbench`                            |
| App pod CrashLoopBackOff on startup                            | Deployed before step 4 finished; Pipeline().setup() failed discovering the model or creating the vector store | Confirm ansible-playbook completed fully, then `oc rollout restart deployment/complaint-intelligence-app`                  |
| App build fails with "no such file: pipeline/classify.py"      | BuildConfig's contextDir or Containerfile COPY paths don't match                                              | Confirm `contextDir: 02-complaint-intelligence` in buildconfig.yaml and that Containerfile COPY paths are relative to that |
| Vector search returns 0 results despite files listed correctly | Llama Stack restarted after the vector store was created; Milvus's search index lost its registration         | Delete the store (`DELETE /v1/vector_stores/<id>`), recreate via the notebook's Cell 10, repopulate via Cells 6-7          |
| Job fails: `can't open file '.../run_batch.py'`                | App image was built before `pipeline/run_batch.py` existed                                                    | `oc start-build complaint-intelligence-app -n complaint-intelligence --follow`, then re-trigger the Job                    |
