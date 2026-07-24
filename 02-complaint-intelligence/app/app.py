"""
app/app.py

Thin demo application (ADR-0007, ADR-0009). Contains no classification
logic of its own; reads evidence records, calls into
pipeline.classify.Pipeline for view 1's live classification, renders
templates. See docs/app-architecture.md for the route table and data
flow this implements.
"""

import os
import random
import sys

sys.path.insert(0, os.environ.get("PIPELINE_PATH", "/app/pipeline"))
from classify import Pipeline
from flask import Flask, abort, redirect, render_template, url_for

app = Flask(__name__)

# Initialized at module import time (not inside a request handler or a
# deprecated before_first_request hook), so this runs correctly whether
# started via `python app.py` or a production WSGI server like gunicorn,
# which imports this module rather than executing it as __main__.
print("Starting up: connecting to pipeline...")
pipeline = Pipeline().setup()
print(f"Pipeline ready. Model: {pipeline.model_id}")

all_complaints = []
evidence_by_id = {}


def reload_state():
    """Reloads both in-memory caches from MinIO. Called at startup and
    by GET /refresh. See docs/app-architecture.md: every route except
    POST /classify/<id> reads from memory, not MinIO, per request."""
    global all_complaints, evidence_by_id
    all_complaints = pipeline.load_all_complaints()
    evidence_by_id = pipeline.load_all_evidence()
    print(
        f"State loaded: {len(all_complaints)} complaints, "
        f"{len(evidence_by_id)} evidence records."
    )


reload_state()


def complaints_by_id():
    return {c["complaint_id"]: c for c in all_complaints}


def split_on_citation(body: str, citation: dict):
    """Splits body into (before, cited, after) for template highlighting.
    If the citation wasn't verified (start/end are None, the model's
    citation_text didn't match verbatim), returns the whole body as
    `before` with no highlighted span, rather than guessing.

    Used by classify_run and evidence_detail, both of which highlight one
    specific cited sentence. NOT used by guardrails_demo, which needs the
    whole before/after body, not a citation span, that is a different
    kind of before/after entirely."""
    if not citation or citation.get("start") is None:
        return body, None, None
    start, end = citation["start"], citation["end"]
    return body[:start], body[start:end], body[end:]


# ---------------------------------------------------------------------
# View 2: theme dashboard
# ---------------------------------------------------------------------


@app.route("/")
def dashboard():
    theme_counts = {}
    for rec in evidence_by_id.values():
        theme_id = rec.get("theme_id")
        if theme_id:
            theme_counts[theme_id] = theme_counts.get(theme_id, 0) + 1

    themes_by_id = {t["id"]: t for t in pipeline.taxonomy["themes"]}
    theme_rows = sorted(
        (
            {
                "id": tid,
                "name": themes_by_id.get(tid, {}).get("name", tid),
                "count": count,
            }
            for tid, count in theme_counts.items()
        ),
        key=lambda r: r["count"],
        reverse=True,
    )

    routed_count = sum(1 for r in evidence_by_id.values() if r.get("routed_to_review"))
    pii_count = sum(1 for r in evidence_by_id.values() if r.get("pii_detected"))

    return render_template(
        "dashboard.html",
        total_complaints=len(all_complaints),
        total_classified=len(evidence_by_id),
        theme_rows=theme_rows,
        routed_count=routed_count,
        pii_count=pii_count,
    )


@app.route("/theme/<theme_id>")
def theme_detail(theme_id):
    themes_by_id = {t["id"]: t for t in pipeline.taxonomy["themes"]}
    theme = themes_by_id.get(theme_id)
    if not theme:
        abort(404)

    root_causes_by_id = {r["id"]: r for r in pipeline.taxonomy["root_causes"]}
    cbid = complaints_by_id()

    rows = []
    for rec in evidence_by_id.values():
        if rec.get("theme_id") != theme_id:
            continue
        complaint = cbid.get(rec["complaint_id"], {})
        rows.append(
            {
                "complaint_id": rec["complaint_id"],
                "root_cause": root_causes_by_id.get(rec.get("root_cause_id"), {}).get(
                    "name", rec.get("root_cause_id")
                ),
                "confidence": rec.get("confidence"),
                "routed_to_review": rec.get("routed_to_review"),
                "channel": complaint.get("channel", ""),
            }
        )
    rows.sort(key=lambda r: r["confidence"] or 0)

    return render_template("theme_detail.html", theme=theme, rows=rows)


# ---------------------------------------------------------------------
# View 1: live classification
# ---------------------------------------------------------------------


@app.route("/classify")
def classify_picker():
    rows = []
    for c in all_complaints:
        existing = evidence_by_id.get(c["complaint_id"])
        rows.append(
            {
                "complaint_id": c["complaint_id"],
                "preview": c["body"][:100],
                "current_theme": existing.get("theme_id") if existing else None,
            }
        )
    return render_template("classify.html", rows=rows)


@app.route("/classify/<complaint_id>", methods=["POST"])
def classify_run(complaint_id):
    complaint = complaints_by_id().get(complaint_id)
    if not complaint:
        abort(404)

    # Deliberately no try/except swallowing here beyond capturing the
    # message to display. ADR-0007: the application does not quietly
    # correct or hide a model failure. If classification fails, the
    # user sees why.
    try:
        record = pipeline.classify_complaint(complaint)
        pipeline.write_evidence_record(record)
        evidence_by_id[complaint_id] = record  # update cache directly
        error = None

        # Reconstruct the redacted body for display: citation offsets are
        # relative to redacted text, not the raw body in all_complaints.
        _, spans = pipeline.check_pii(complaint["body"])
        display_body = pipeline.redact_pii(complaint["body"], spans)
        before, cited, after = split_on_citation(display_body, record["citation"])
    except Exception as e:
        record = None
        error = str(e)
        before = cited = after = None

    return render_template(
        "classify_result.html",
        complaint=complaint,
        record=record,
        error=error,
        before=before,
        cited=cited,
        after=after,
    )


# ---------------------------------------------------------------------
# View 3: review queue
# ---------------------------------------------------------------------


@app.route("/review")
def review_queue():
    cbid = complaints_by_id()
    rows = []
    for rec in evidence_by_id.values():
        if not rec.get("routed_to_review"):
            continue
        complaint = cbid.get(rec["complaint_id"], {})
        rows.append(
            {
                "complaint_id": rec["complaint_id"],
                "preview": complaint.get("body", "")[:150],
                "theme_id": rec.get("theme_id"),
                "confidence": rec.get("confidence"),
                "review_reason": rec.get("review_reason"),
                "candidate_themes": rec.get("candidate_themes", []),
            }
        )
    return render_template("review.html", rows=rows)


# ---------------------------------------------------------------------
# View 4: guardrails in action
#
# NOTE: only the PII-redaction half of this view is real. demo-
# experience.md's "injection fixture visibly blocked" was never built,
# the guardrails orchestrator on this stack only has email/credit-card
# regex detectors configured, no injection detector. injection_blocked
# has been None ("not configured on this stack") in every evidence
# record all session. The template surfaces this honestly rather than
# fabricating a blocked example.
#
# NOTE: this view shows the WHOLE complaint body before/after redaction,
# not a citation span. It does not use split_on_citation.
# ---------------------------------------------------------------------


@app.route("/guardrails")
def guardrails_demo():
    cbid = complaints_by_id()
    pii_ids = [cid for cid, rec in evidence_by_id.items() if rec.get("pii_detected")]

    if not pii_ids:
        return render_template("guardrails.html", example=None)

    chosen_id = random.choice(pii_ids)
    complaint = cbid.get(chosen_id, {})
    record = evidence_by_id[chosen_id]

    # Cheap to recompute live (one guardrails call) rather than storing
    # the redacted body twice in the evidence record just for this view.
    _, spans = pipeline.check_pii(complaint.get("body", ""))
    redacted = pipeline.redact_pii(complaint.get("body", ""), spans)

    example = {
        "complaint_id": chosen_id,
        "before": complaint.get("body", ""),
        "after": redacted,
        "pii_redactions": record.get("pii_redactions"),
    }
    return render_template("guardrails.html", example=example)


# ---------------------------------------------------------------------
# View 5: evidence view
# ---------------------------------------------------------------------


@app.route("/evidence/<complaint_id>")
def evidence_detail(complaint_id):
    record = evidence_by_id.get(complaint_id)
    if not record:
        abort(404)
    complaint = complaints_by_id().get(complaint_id, {})

    _, spans = pipeline.check_pii(complaint.get("body", ""))
    display_body = pipeline.redact_pii(complaint.get("body", ""), spans)
    before, cited, after = split_on_citation(display_body, record.get("citation"))

    return render_template(
        "evidence.html",
        record=record,
        complaint=complaint,
        before=before,
        cited=cited,
        after=after,
    )


# ---------------------------------------------------------------------
# Operational
# ---------------------------------------------------------------------


@app.route("/refresh")
def refresh():
    reload_state()
    return redirect(url_for("dashboard"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
