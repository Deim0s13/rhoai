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
from datetime import datetime, timedelta

from classify import Pipeline
from flask import Flask, abort, redirect, render_template, request, url_for

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


def _parse_date(value):
    """Complaint dates are ISO after the 2026-08 regeneration. The older
    '23 June 2026' form is still accepted so a stale bucket degrades
    gracefully instead of breaking the dashboard."""
    if not value:
        return None
    for fmt in ("%Y-%m-%d", "%d %B %Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except (ValueError, TypeError):
            continue
    return None


def _trend_windows(cbid):
    """Anchor the comparison to the latest complaint in the dataset, not to
    wall clock. The sample is fixed in time, so a real-time window would
    show zero complaints and every theme would read as collapsing.

    90 days, not 30: at ~33 complaints a month across 10 themes, a 30-day
    window leaves most themes in single digits, where genuine growth is
    invisible and one complaint swings the percentage wildly."""
    dates = [
        d for d in (_parse_date(c.get("received_date")) for c in cbid.values()) if d
    ]
    if not dates:
        return None, None, None
    latest = max(dates)
    recent_start = latest - timedelta(days=89)
    return recent_start - timedelta(days=90), recent_start, latest


def _trend_pct(recent, prior):
    """None below a floor of 5 in the prior window: a swing from 3 to 0 is
    not a trend, and -100% on a base of three invites a question the number
    cannot answer."""
    if prior < 5:
        return None
    return round((recent - prior) / prior * 100)


# ---------------------------------------------------------------------
# View 2: theme dashboard
# ---------------------------------------------------------------------


@app.route("/")
def dashboard():
    themes_by_id = {t["id"]: t for t in pipeline.taxonomy["themes"]}
    root_causes_by_id = {r["id"]: r for r in pipeline.taxonomy["root_causes"]}
    cbid = complaints_by_id()
    prior_start, recent_start, latest = _trend_windows(cbid)

    theme_counts, theme_recent, theme_prior = {}, {}, {}
    rc_counts, rc_review = {}, {}

    for rec in evidence_by_id.values():
        tid = rec.get("theme_id")
        if tid:
            theme_counts[tid] = theme_counts.get(tid, 0) + 1
            d = _parse_date(cbid.get(rec["complaint_id"], {}).get("received_date"))
            if d and recent_start:
                if d >= recent_start:
                    theme_recent[tid] = theme_recent.get(tid, 0) + 1
                elif d >= prior_start:
                    theme_prior[tid] = theme_prior.get(tid, 0) + 1
        rcid = rec.get("root_cause_id")
        if rcid:
            rc_counts[rcid] = rc_counts.get(rcid, 0) + 1
            if rec.get("routed_to_review"):
                rc_review[rcid] = rc_review.get(rcid, 0) + 1

    theme_rows = sorted(
        (
            {
                "id": tid,
                "name": themes_by_id.get(tid, {}).get("name", tid),
                "count": count,
                "trend": _trend_pct(theme_recent.get(tid, 0), theme_prior.get(tid, 0)),
            }
            for tid, count in theme_counts.items()
        ),
        key=lambda r: r["count"],
        reverse=True,
    )

    rc_rows = sorted(
        (
            {
                "id": rcid,
                "name": root_causes_by_id.get(rcid, {}).get("name", rcid),
                "count": count,
                "review": rc_review.get(rcid, 0),
            }
            for rcid, count in rc_counts.items()
        ),
        key=lambda r: r["count"],
        reverse=True,
    )

    return render_template(
        "dashboard.html",
        total_complaints=len(all_complaints),
        total_classified=len(evidence_by_id),
        theme_rows=theme_rows,
        rc_rows=rc_rows,
        routed_count=sum(
            1 for r in evidence_by_id.values() if r.get("routed_to_review")
        ),
        pii_count=sum(1 for r in evidence_by_id.values() if r.get("pii_detected")),
        recent_start=recent_start,
        latest=latest,
    )


@app.route("/theme/<theme_id>")
def theme_detail(theme_id):
    themes_by_id = {t["id"]: t for t in pipeline.taxonomy["themes"]}
    theme = themes_by_id.get(theme_id)
    if not theme:
        abort(404)
    root_causes_by_id = {r["id"]: r for r in pipeline.taxonomy["root_causes"]}
    cbid = complaints_by_id()

    # Optional drill-through: /theme/THM-10?root_cause=RC-03
    filter_rc = request.args.get("root_cause")

    rc_counts, rc_review, rows = {}, {}, []
    for rec in evidence_by_id.values():
        if rec.get("theme_id") != theme_id:
            continue
        rcid = rec.get("root_cause_id")
        if rcid:
            rc_counts[rcid] = rc_counts.get(rcid, 0) + 1
            if rec.get("routed_to_review"):
                rc_review[rcid] = rc_review.get(rcid, 0) + 1
        if filter_rc and rcid != filter_rc:
            continue
        complaint = cbid.get(rec["complaint_id"], {})
        rows.append(
            {
                "complaint_id": rec["complaint_id"],
                "root_cause": root_causes_by_id.get(rcid, {}).get("name", rcid),
                "confidence": rec.get("confidence"),
                "routed_to_review": rec.get("routed_to_review"),
                "channel": complaint.get("channel", ""),
            }
        )

    rc_rows = sorted(
        (
            {
                "id": rcid,
                "name": root_causes_by_id.get(rcid, {}).get("name", rcid),
                "count": count,
                "review": rc_review.get(rcid, 0),
            }
            for rcid, count in rc_counts.items()
        ),
        key=lambda r: r["count"],
        reverse=True,
    )
    rows.sort(key=lambda r: r["confidence"] or 0)

    return render_template(
        "theme_detail.html",
        theme=theme,
        rows=rows,
        rc_rows=rc_rows,
        filter_rc=filter_rc,
        filter_rc_name=root_causes_by_id.get(filter_rc, {}).get("name", filter_rc),
    )


@app.route("/root-cause/<root_cause_id>")
def root_cause_detail(root_cause_id):
    root_causes_by_id = {r["id"]: r for r in pipeline.taxonomy["root_causes"]}
    rc = root_causes_by_id.get(root_cause_id)
    if not rc:
        abort(404)
    themes_by_id = {t["id"]: t for t in pipeline.taxonomy["themes"]}

    theme_counts, rows = {}, []
    for rec in evidence_by_id.values():
        if rec.get("root_cause_id") != root_cause_id:
            continue
        tid = rec.get("theme_id")
        if tid:
            theme_counts[tid] = theme_counts.get(tid, 0) + 1
        rows.append(
            {
                "complaint_id": rec["complaint_id"],
                "theme_id": tid,
                "theme": themes_by_id.get(tid, {}).get("name", tid),
                "confidence": rec.get("confidence"),
                "routed_to_review": rec.get("routed_to_review"),
            }
        )

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
    rows.sort(key=lambda r: r["confidence"] or 0)

    return render_template(
        "root_cause_detail.html", rc=rc, rows=rows, theme_rows=theme_rows
    )


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
