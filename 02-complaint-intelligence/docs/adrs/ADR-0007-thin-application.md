# ADR-0007: The demo application is deliberately thin

**Status:** Accepted
**Date:** 2026-07-15

## Context

The demo needs a browser-based interface. The audience includes business,
risk and compliance stakeholders, and one of the controls this use case
commits to demonstrating is a compliance persona reviewing evidence without
administrator involvement. That is not demonstrable from a terminal.

The risk is that the interface becomes the product. If an architect in the
room asks "how much of this is your application and how much is the
platform?", and the honest answer is "quite a lot is ours", the entire
platform argument collapses. The pitch is that a regulated organisation gets
these capabilities from Red Hat AI, not that we can build a good application.

## Decision

The application reads and displays. It does not think.

1. **No intelligence in the application.** Classification, retrieval,
   guardrails and evaluation are all platform calls. The application composes
   the response and renders it.
2. **The application reads evidence records; it does not create business
   logic.** The pipeline writes records; the application filters and displays
   them.
3. **Platform capabilities are shown in the platform's own interfaces**, not
   reimplemented in ours. Model serving, monitoring and evaluation views come
   from the OpenShift AI console.
4. **A plain web application**, not a data science UI framework. Gradio and
   Streamlit read as prototypes to an executive audience; the same effort in a
   simple web application reads as a product. This is a presentation
   judgement, not a technical one.

## Consequences

- The honest answer to "how much is yours?" becomes "almost none, and here is
  the same capability in the product console". That answer is the demo's
  strongest moment and it must remain true.
- Any temptation to fix a classification problem in the application layer is
  rejected: it belongs in the prompt, the taxonomy or the pipeline. An
  application that quietly corrects the model is a demo that lies.
- The application is disposable. It is not the reusable asset; the pipeline,
  the evidence schema and the manifests are.
- The five views in demo-experience.md constrain the evidence record schema.
  Views do not add fields at render time; if a view needs data, the record
  gains the field and the pipeline writes it.
