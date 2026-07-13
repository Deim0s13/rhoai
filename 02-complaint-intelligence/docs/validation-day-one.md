# Platform Validation: Day One

A structured validation exercise for the provisioned environment, not
exploration. Each step has an expected outcome and a defined place for the
result to land. The session closes open decisions 1 to 4 in
`architecture.md` and produces ADR-0002 through ADR-0004.

Time-box the whole session. Anything that resists validation inside the
time-box becomes a recorded gap with a workaround decision, not an open-ended
investigation. Use Case 01 established the pattern: deviations are expected,
fixed where cheap, recorded always.

## 1. Baseline inventory (closes open decision 1, feeds ADR-0002)

| Check                                                                       | How                                                      | Record                   |
| --------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------------ |
| OpenShift version                                                           | `oc version`                                             | ADR-0002                 |
| RHOAI version and installed components                                      | Operator details in the console; DataScienceCluster spec | ADR-0002                 |
| GPU worker present and schedulable                                          | `oc get nodes` with labels; NVIDIA operator status       | ADR-0002                 |
| Llama Stack operator availability and maturity (GA / tech preview / absent) | OperatorHub search; DataScienceCluster component list    | ADR-0002                 |
| TrustyAI operator availability and version                                  | As above                                                 | ADR-0002                 |
| MLflow / tracing and evaluation capability present in this version          | RHOAI dashboard and component inventory                  | ADR-0002                 |
| Models-as-a-service / gateway capability present                            | RHOAI dashboard; component inventory                     | ADR-0002, feeds ADR-0003 |
| Model catalog contents (Granite 3.x 8B or equivalent)                       | RHOAI dashboard model catalog                            | ADR-0002                 |

Expected drift, based on Use Case 01: assume nothing about component
availability until seen. If the provisioned RHOAI version predates a capability
this design assumes, record the gap and decide: newer catalog item, manual
operator install, or design adjustment. That decision is the substance of
ADR-0002.

## 2. Serving smoke test (validates the foundation carried over from UC01)

1. Create the project/namespace via the UC01 manifest pattern.
2. Deploy the smallest viable model from the catalog via vLLM ServingRuntime,
   RawDeployment mode.
3. Single completion request against the endpoint; confirm response and GPU
   scheduling.

Expected to be routine: this path was proven in Use Case 01. Apply the UC01
learnings directly (ServingRuntime as single source of truth for args, bare
hostname for any S3 endpoint, image tag currency). Any new drift goes in this
use case's learnings, not silently absorbed.

## 3. Llama Stack validation (feeds ADR-0004)

1. Deploy Llama Stack (operator-managed if available) pointing at the vLLM
   endpoint from step 2.
2. Confirm inference through the unified API rather than the direct endpoint.
3. Register the Milvus vector store (inline first; remote only if inline is
   unavailable) and run a trivial store/retrieve round trip.
4. Record: does consuming Milvus through Llama Stack sidestep the
   pymilvus/marshmallow dependency conflict recorded in Use Case 01? Either
   answer is useful; feed it back to the UC01 close-out.

## 4. Guardrails validation

1. Deploy the TrustyAI guardrails orchestrator.
2. Apply a minimal PII detection policy (regex detectors are sufficient for
   day one).
3. Send a request containing mock PII per the fixture conventions; confirm
   detection/redaction fires and the decision is observable somewhere a demo
   can show.

## 5. Tracing and evaluation validation (closes open decision 2, feeds ADR-0004)

1. Confirm where traces land in this environment and what creates them
   (automatic via Llama Stack, or explicit instrumentation).
2. Create one experiment; log one traced interaction; confirm the span
   structure available supports the four-stage convention (application,
   input/guardrails, retrieval, model).
3. Decide and record span naming and experiment structure in ADR-0004. This
   unblocks pipeline code.

## 6. Gateway validation (closes open decision 3, produces ADR-0003)

If a models-as-a-service / gateway capability exists in this version: register
an application identity, apply a token or rate limit, demonstrate a constrained
request, revoke the credential, demonstrate the failure. If it does not exist:
record the gap and decide the demo posture for the economics pillar (composed
gateway, or documented-pattern-only), in ADR-0003.

## Exit criteria for the session

- ADR-0002 (platform baseline, gaps and decisions) drafted
- ADR-0003 (gateway composition) drafted, even if the decision is "pattern
  documented, not demonstrated, in this environment"
- ADR-0004 (tracing and span conventions) drafted; pipeline work is unblocked
- New environment learnings recorded in this use case's documentation
- The pymilvus question answered in either direction and noted for UC01

Steps 1 to 3 are the critical path; 4 to 6 can spill into a second session
without blocking taxonomy, data or pipeline design work.
