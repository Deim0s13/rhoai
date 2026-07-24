# App architecture: complaint intelligence demo application

**Status:** Draft, written ahead of build
**Companion to:** ADR-0007 (thin application), ADR-0009 (shared module,
production-representativeness)

## Purpose

Implements the five views in `demo-experience.md` as a thin,
server-rendered Flask application. Contains no classification logic of
its own; reads evidence records written by the pipeline, and for view 1
only, calls into the shared classification module live. See ADR-0007 for
why thinness matters to the pitch, and ADR-0009 for what in this
implementation is genuinely production-representative versus a demo-scale
delivery mechanic.

## Component overview

```
Browser
  |
  v
Flask app (this document)
  |         |
  v         v
MinIO    pipeline/classify.py (shared module, ADR-0009)
(evidence,      |
 complaints)    v
           Llama Stack, guardrails, vector store
           (view 1's live classification only)
```

The app never talks to Llama Stack, guardrails, or the vector store
directly. All of that goes through `pipeline/classify.py`, the same
module the notebook uses. The app's own responsibilities are: load data,
route requests, render templates, and for view 1, call one function in
the shared module and persist its result.

## Views to routes

| Route                           | View (demo-experience.md)      | Data source                                                                   | Mutates state?                               |
| ------------------------------- | ------------------------------ | ----------------------------------------------------------------------------- | -------------------------------------------- |
| `GET /`                         | 2, theme dashboard             | In-memory evidence cache                                                      | No                                           |
| `GET /theme/<theme_id>`         | 2, drill-down                  | In-memory evidence cache                                                      | No                                           |
| `GET /classify`                 | 1, complaint picker            | In-memory complaints cache                                                    | No                                           |
| `POST /classify/<complaint_id>` | 1, live classification         | Calls `pipeline.classify.classify_complaint()`                                | Yes, writes to MinIO and the in-memory cache |
| `GET /review`                   | 3, review queue                | In-memory evidence cache, filtered on `routed_to_review`                      | No                                           |
| `GET /guardrails`               | 4, guardrails in action        | In-memory evidence cache, filtered on `pii_detected` or the injection fixture | No                                           |
| `GET /evidence/<complaint_id>`  | 5, evidence view               | In-memory evidence cache                                                      | No                                           |
| `GET /refresh`                  | (operational, not a demo view) | Reloads both in-memory caches from MinIO                                      | No (reload, not write)                       |

Only `POST /classify/<complaint_id>` writes anything. Every other route
is a read against memory already loaded at startup.

## Data flow: startup

1. App starts, calls `pipeline.classify`'s client setup (MinIO, Llama
   Stack config), same as the notebook's Cell 1-6 equivalent.
2. Loads `complaints/incoming/records.jsonl` into memory (`all_complaints`).
3. Loads every object under `evidence/classifications/` into memory
   (`evidence_by_id`, keyed by `complaint_id`).
4. Serves requests from these two in-memory structures. At demo volumes
   (~200 records, per ADR-0004), this is instant; no MinIO round-trip per
   page view.

## Data flow: live classification (view 1)

1. User selects an unclassified, or intentionally re-classifiable,
   complaint and submits.
2. `POST /classify/<complaint_id>` calls
   `pipeline.classify.classify_complaint(complaint)`, the exact function
   the batch notebook run uses, no separate code path.
3. On success: `pipeline.classify.write_evidence_record()` persists to
   MinIO (same as the notebook), and the route updates
   `evidence_by_id` in memory directly, so views 2, 3, and 5 reflect the
   new record immediately without a manual refresh.
4. On failure (model error, malformed JSON, etc.): the error surfaces to
   the page honestly. No silent fallback, no fabricated result. Consistent
   with ADR-0007: the application does not quietly correct the model.

## Module structure

```
02-complaint-intelligence/app/
  app.py              # Flask routes, thin: load, route, render
  Containerfile        # COPYs pipeline/classify.py into the image
  templates/
    dashboard.html      # view 2
    classify.html        # view 1
    review.html          # view 3
    guardrails.html       # view 4
    evidence.html          # view 5
    base.html               # shared layout/nav
  static/
    style.css
02-complaint-intelligence/pipeline/
  classify.py          # shared module, ADR-0009, single source of truth
```

## Deployment

New manifest set, `manifests/app/`:

- **Deployment** — same `secretKeyRef`-based env var pattern as
  `workbench.yaml` (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, plus
  `LLAMA_STACK_URL` and `GUARDRAILS_URL`, no new secrets needed since
  these already exist in-cluster)
- **Service** — ClusterIP, standard
- **Route** — classic OpenShift Route, matching MinIO's exposure pattern.
  Deliberately not a Gateway API path: this is a plain `Deployment`, not
  a `Notebook` CR, so it does not hit the controller bug or the
  NetworkPolicy restriction found and documented against the workbench
  (`REBUILD.md`, `DEPLOYMENT-LOG-2026-07-22`)

## What this document does not cover

- The shared module's internal design, that is `pipeline/classify.py`
  itself and its own inline documentation, built next
- Styling and visual design specifics, addressed during template build
- The batch Job promotion (notebook to automated Job), tracked separately
  on the "on the horizon" list

## Open questions to resolve during build

- Exact complaint-selection UX for view 1: a dropdown of all 200, or a
  filtered subset of already-classified complaints offered for
  re-classification, plus any still-unclassified ones. Affects whether
  "live classification" in the demo overwrites an existing evidence
  record or only ever creates new ones.
- Whether view 4's guardrails example is a fixed, specific complaint
  known to contain PII, or randomly selected from those with
  `pii_detected: true`. A fixed example is more reliable for a live demo.
