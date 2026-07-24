# ADR-0009: Thin application implementation, shared classification module

**Status:** Accepted
**Date:** 2026-07-24

## Context

ADR-0007 establishes that the demo application must be thin: no
classification logic of its own, platform calls composed and rendered,
not reimplemented. Building the actual application surfaces the mechanism
for honoring that principle, and a real risk alongside it: the
classification logic currently lives entirely inside the notebook
(`classify_complaint()`). If the application reimplements any part of it
independently, even with good intentions, the two copies will drift, the
exact failure mode this build has already hit and fixed more than once
tonight (the PII counting bug, the trailing-JSON parsing bug, both bugs
that existed in one place and had to be found and fixed twice, once
noticed, once actually applied everywhere it mattered).

Live classification was chosen for view 1 over a pre-computed, staged
reveal (see chat, 2026-07-24), on the reasoning that a genuinely live
model call is a stronger demo moment than an animated pause over static
data, provided the underlying logic is shared rather than duplicated.

## Decision

**One shared module, two consumers.** `pipeline/classify.py` becomes the
single source of truth for guardrails/redaction, retrieval, prompt
construction, the model call, citation matching, and ADR-0004 review
routing. The notebook and the application both import from it; neither
defines this logic independently.

- **The application** gets the module via a normal container build
  (`Containerfile` `COPY`), the standard way.
- **The notebook** gets it via a ConfigMap, mirroring the existing
  `seed_taxonomy` pattern (`oc create configmap pipeline-code
--from-file=pipeline/classify.py`), mounted into the workbench
  alongside the taxonomy ConfigMap. This keeps the "no manual
  undocumented steps" discipline: the module reaches the workbench
  through the same GitOps-native mechanism as everything else, not a
  copy-paste.

## What this is, and is not, representative of

Worth being precise about this distinction, since conflating the two
would be exactly the overclaim ADR-0007 warns against.

**Genuinely production-representative:**

- A thin presentation layer with no business logic of its own
- One shared module as the single source of classification logic,
  rather than two implementations that can silently diverge
- Platform services (Llama Stack, guardrails, the vector store) doing
  the actual intelligence work, not reimplemented in the application
- The evidence record as the audit trail, read by the application,
  written by the pipeline

This is the honest version of ADR-0007's claim: "the platform provides
this" is true here, not asserted for effect.

**Demo-scale delivery mechanics, not the production shape:**

- **The notebook** driving batch and (for view 1) live classification.
  Production has nothing resembling a notebook in the serving path; this
  is the still-open "promote to an automated Job" item.
- **ConfigMap-mounting the shared module into the workbench.** A
  reasonable trick for a demo lab needing the code without a manual
  step, not how production code distribution works, no size ceiling
  concerns, no versioning discipline. Production would build the module
  into a container image via CI/CD, the same way the application itself
  is built.
- **Synchronous, user-triggered classification on a button click.** The
  ANZ use case document specifies this as a System-to-LLM pattern with
  no direct customer interaction, batch or event-driven, not a person
  clicking a button and waiting on a live call. View 1's live
  classification is a genuine call into the real pipeline, not a
  simulation, but the _interaction pattern_ is a demo device. Views 2,
  3, and 5, reading pre-existing evidence records, are already closer to
  the actual production interaction shape than view 1 is.

## Consequences

- Any fix to classification logic (a prompt change, a routing threshold,
  a bug) happens once, in `pipeline/classify.py`, and both the notebook
  and the application pick it up automatically. No parallel maintenance.
- The application's honesty depends on this module staying the single
  source of truth. Any future temptation to patch behavior directly in
  `app.py` for a demo-day fix should be treated as a signal to fix the
  module instead, consistent with ADR-0007's original warning.
- If asked directly "would a bank build it this way", the accurate
  answer is: the architecture, yes; the notebook-as-batch-driver and the
  synchronous button-click interaction, no, those are named here
  explicitly as what a production build would replace.
