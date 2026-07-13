# ADR-0002: Platform baseline as validated in the provisioned environment

**Status:** Draft (pending day-one validation)
**Date:** TO CAPTURE

## Context

The UC02 design assumes platform capabilities whose availability and maturity
vary by RHOAI version: the Llama Stack operator, TrustyAI guardrails with
built-in detectors, MLflow-based tracing and evaluation, and any
models-as-a-service or gateway capability. UC01 validated against RHOAI 2.25.8
on OpenShift 4.18.21; the RHDP catalog item provisioned for UC02 determines
what this build actually gets, and pretending otherwise is how drift tables
get long.

This ADR records the validated baseline and the posture decision that follows
from it. Where the environment lacks a capability the design assumes, the gap
and its treatment are recorded here, not worked around silently.

## Findings (captured during validation)

| Item                                                  | Expected by design                             | Found      | Gap treatment |
| ----------------------------------------------------- | ---------------------------------------------- | ---------- | ------------- |
| OpenShift version                                     | 4.18+                                          | TO CAPTURE |               |
| RHOAI version                                         | 2.25+ (newer preferred for tracing/MaaS)       | TO CAPTURE |               |
| GPU node and product label                            | 1x NVIDIA L4 (g6.xlarge), label `NVIDIA-L4`    | TO CAPTURE |               |
| Argo CD (openshift-gitops) present                    | Preferred, not required (bootstrap falls back) | TO CAPTURE |               |
| Llama Stack operator                                  | Available, activatable                         | TO CAPTURE |               |
| Llama Stack distribution name                         | `rh-dev` per 2.25 docs                         | TO CAPTURE |               |
| TrustyAI operator, built-in detector sidecar          | Available                                      | TO CAPTURE |               |
| MLflow / tracing and evaluation capability            | Present in provisioned version                 | TO CAPTURE |               |
| MaaS / gateway capability                             | Unknown; determines ADR-0003                   | TO CAPTURE |               |
| Model catalog contents (Granite 3.3 8B or equivalent) | Present                                        | TO CAPTURE |               |
| RHAIIS vLLM image tag currency (3.2.5 assumed)        | Current or superseded                          | TO CAPTURE |               |

## Decision

TO CAPTURE. One of, or a combination of:

1. Proceed as designed: the provisioned baseline supports the full design.
2. Proceed with recorded gaps: capabilities X and Y are absent or immature;
   the affected controls-matrix rows are demonstrated as documented patterns
   rather than live, and the demo guide states this honestly.
3. Re-provision: the gap is fundamental enough that a different catalog item
   or manually installed operators are the cheaper path.

## Consequences

TO CAPTURE against the decision taken. At minimum, record: which
controls-alignment rows are affected, which manifests changed as a result
(and were committed), and what the demo can and cannot show live in this
environment.
