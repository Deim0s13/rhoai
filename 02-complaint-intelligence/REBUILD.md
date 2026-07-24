# Rebuild guide

The environment is throwaway. This is the whole rebuild, assuming a fresh RHDP
cluster with RHOAI. Everything here is repo state; nothing depends on notes,
memory or a previous session's shell.

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

Keep these in ONE terminal tab for the whole run. Lost exports were the single
biggest time sink in the first live session.

## 3. Bootstrap

Operator activation is handled by the bootstrap; there are no console steps.
RHDP catalog images ship Llama Stack and TrustyAI as `Removed`, so their CRDs
do not exist and the llama-stack/guardrails manifests cannot apply. The
bootstrap patches the DataScienceCluster and waits for the CRDs before
applying anything that depends on them.

```bash
cd 02-complaint-intelligence
./scripts/bootstrap.sh
```

Verify afterwards if you want reassurance:

```bash
oc get crd | grep -iE "llamastackdistributions|guardrailsorchestrators"
```

The script guards every failure mode from the first session: missing envsubst,
empty credentials, unsubstituted placeholders, wrong active project, and MinIO
running stale credentials. If it exits with an error, the message tells you
what to fix; it will not leave a half-broken cluster behind.

## 4. Seed

    ansible-playbook ansible/site.yml

Discovers the MinIO Route itself, downloads the model (~16GiB, roughly 15 to
20 minutes), mirrors it into MinIO, restarts the predictor once weights are
confirmed complete, waits for it to be ready, then restarts Llama Stack so
it discovers the now-ready model. Fully automated; no manual pod restarts
or verification steps needed after this command finishes.

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

External access via the RHOAI dashboard and the Gateway URL does not work on
this platform version (see "Do not" and the troubleshooting table). Use
port-forward instead:

```bash
oc port-forward svc/complaint-intelligence-workbench -n complaint-intelligence 8888:80
```

Open `http://localhost:8888`. Get the login token:

```bash
oc logs complaint-intelligence-workbench-0 -n complaint-intelligence | grep -i token
```

## 8. Verify the pipeline

```bash
WORKBENCH_POD=$(oc get pods -n complaint-intelligence \
  -l notebook-name=complaint-intelligence-workbench \
  -o jsonpath='{.items[0].metadata.name}')

oc exec $WORKBENCH_POD -n complaint-intelligence -- \
    pip install --quiet requests pyyaml minio --break-system-packages
oc exec $WORKBENCH_POD -n complaint-intelligence -- \
    python3 /opt/app-root/pipeline/smoke_test.py
```

All checks should print PASS. This is the single go/no-go gate for a
rebuild: if it fails, the failure message names the specific broken
stage (taxonomy mount, model discovery, vector store, guardrails, or
the model call itself) rather than requiring notebook archaeology to
find it.

## Do not

- **Do not `oc expose`** anything in this namespace. Argo prunes it (ADR-0005).
  Network edge = a manifest.
- **Do not port-forward for the model upload.** It drops on multi-GiB
  transfers. The Route exists for this.
- **Do not put secret templates under `manifests/`.** Argo applies them raw
  (ADR-0005).
- **Do not activate operators through the console.** The bootstrap patches the
  DataScienceCluster. A console click is an undocumented manual step and will
  not survive a rebuild.
- **Do not trust `oc get applications`.** Use `oc get applications.argoproj.io`;
  the short name can resolve to a different CRD.
- **Do not use the RHOAI dashboard's Open button for this workbench.**
  Broken on 3.4.2 for hand-applied Notebook objects; use port-forward
  (step 7).
- **Do not add a Route to work around the broken Gateway URL.** A
  controller-generated NetworkPolicy blocks it by design; port-forward is
  the only working path.

## If something fails

| Symptom                                                      | Cause                                                                      | Fix                                                                                                                     |
| ------------------------------------------------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `Access Key Id ... does not exist`                           | MinIO running stale/placeholder credentials                                | `oc exec deploy/minio -- env \| grep MINIO_ROOT`; if it shows `${...}`, re-render and `oc rollout restart deploy/minio` |
| `Unauthorized` on every oc command                           | Token expired (RHDP tokens are short)                                      | Fresh `oc login`                                                                                                        |
| Predictor `Init:CrashLoopBackOff`, log says `NoSuchBucket`   | Model not seeded yet                                                       | Expected before step 4; ignore                                                                                          |
| Predictor `Pending` forever                                  | GPU label mismatch                                                         | Check `nvidia.com/gpu.product` on nodes vs the InferenceService nodeSelector                                            |
| Route "created" then "not found"                             | Created via `oc expose` in an Argo namespace                               | Apply the committed manifest instead                                                                                    |
| `mc` TLS error over http                                     | Router forces edge TLS                                                     | The Ansible role falls back to https automatically                                                                      |
| `no matches for kind "LlamaStackDistribution"`               | Component still `Removed`; CRD absent                                      | Bootstrap handles this; if hit manually, patch the DSC and wait for the CRD                                             |
| Workbench URL returns 500 / "Application is unavailable"     | Gateway HTTPRoute port bug (3.4.2 controller defect)                       | Use port-forward (step 7), not the Gateway URL                                                                          |
| Dashboard shows "migration required, image unknown, deleted" | Cosmetic; hand-applied Notebook lacks dashboard image-tracking annotations | Ignore; check pod directly with `oc get pods -l notebook-name=complaint-intelligence-workbench`                         |
