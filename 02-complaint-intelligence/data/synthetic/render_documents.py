#!/usr/bin/env python3
"""
Render a subset of synthetic complaints as PDF documents, to exercise the
Docling parsing path in the ingestion pipeline.

Two document shapes, because a real complaints inbox is not uniform and the
point is to prove Docling handles variety:
  - formal complaint letters  (letterhead, date block, salutation, body, sign-off)
  - exported email threads     (From/To/Subject/Date headers, quoted body)

Reads out/records.jsonl (produced by generate.py) and renders a deterministic
subset. PDFs are build outputs, not committed: the repo .gitignore excludes
*.pdf (UC01 convention). This script is the versioned artefact.

Selection is deterministic (same seed) so the same records render every run,
which keeps the ingestion demo repeatable.
"""

import json
import random
from pathlib import Path

from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

SEED = 20260716
random.seed(SEED)

HERE = Path(__file__).parent
RECORDS = HERE / "out" / "records.jsonl"
DOC_DIR = HERE / "out" / "documents"

N_LETTERS = 10
N_EMAILS = 10

# Fictional sender identities for document headers (obviously synthetic).
SENDERS = [
    ("Tama Testperson", "tama.testperson@example.com"),
    ("Aroha Sampleton", "aroha.sampleton@example.co.nz"),
    ("Wiremu Fakename", "wiremu.fakename@example.com"),
    ("Mere Demoson", "mere.demoson@example.co.nz"),
    ("Hemi Placeholder", "hemi.placeholder@example.com"),
    ("Ana Exampleton", "ana.exampleton@example.co.nz"),
    ("Rangi Mockford", "rangi.mockford@example.com"),
    ("Kiri Fixturely", "kiri.fixturely@example.co.nz"),
    ("Manaia Notreal", "manaia.notreal@example.com"),
    ("Ngaire Synthwick", "ngaire.synthwick@example.co.nz"),
]

# Generic, unbranded recipient. No real organisation named (repo convention).
RECIPIENT = "Customer Complaints Team"


def styles():
    s = getSampleStyleSheet()
    s.add(
        ParagraphStyle(
            "Sender", parent=s["Normal"], fontSize=10, leading=13, alignment=TA_LEFT
        )
    )
    s.add(
        ParagraphStyle(
            "Meta", parent=s["Normal"], fontSize=9, leading=12, textColor="#444444"
        )
    )
    s.add(
        ParagraphStyle(
            "BodyText2", parent=s["Normal"], fontSize=11, leading=16, spaceAfter=8
        )
    )
    s.add(
        ParagraphStyle(
            "Head", parent=s["Normal"], fontSize=9, leading=12, fontName="Courier"
        )
    )
    return s


def render_letter(rec, sender, path, st):
    name, email = sender
    doc = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        topMargin=25 * mm,
        bottomMargin=25 * mm,
        leftMargin=25 * mm,
        rightMargin=25 * mm,
    )
    flow = []
    # sender block
    flow.append(Paragraph(name, st["Sender"]))
    flow.append(Paragraph(email, st["Meta"]))
    flow.append(Spacer(1, 10 * mm))
    flow.append(Paragraph(rec["received_date"], st["Meta"]))
    flow.append(Spacer(1, 6 * mm))
    flow.append(Paragraph(RECIPIENT, st["Sender"]))
    flow.append(Spacer(1, 8 * mm))
    flow.append(Paragraph(f"Reference: {rec['complaint_id']}", st["Meta"]))
    flow.append(Spacer(1, 6 * mm))
    flow.append(Paragraph("To whom it may concern,", st["BodyText2"]))
    flow.append(Spacer(1, 2 * mm))
    # body, split into paragraphs on sentence-ish boundaries for realism
    for para in split_paras(rec["body"]):
        flow.append(Paragraph(para, st["BodyText2"]))
    flow.append(Spacer(1, 4 * mm))
    flow.append(Paragraph("I look forward to your response.", st["BodyText2"]))
    flow.append(Spacer(1, 6 * mm))
    flow.append(Paragraph("Yours faithfully,", st["BodyText2"]))
    flow.append(Paragraph(name, st["Sender"]))
    doc.build(flow)


def render_email(rec, sender, path, st):
    name, email = sender
    doc = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        topMargin=20 * mm,
        bottomMargin=20 * mm,
        leftMargin=20 * mm,
        rightMargin=20 * mm,
    )
    flow = []
    # email header block, monospaced to look like an export
    header = [
        f"From:    {name} &lt;{email}&gt;",
        f"To:      {RECIPIENT} &lt;complaints@example.com&gt;",
        f"Date:    {rec['received_date']}",
        f"Subject: Complaint - {rec['complaint_id']}",
    ]
    for h in header:
        flow.append(Paragraph(h, st["Head"]))
    flow.append(Spacer(1, 6 * mm))
    flow.append(Paragraph("Hi,", st["BodyText2"]))
    flow.append(Spacer(1, 2 * mm))
    for para in split_paras(rec["body"]):
        flow.append(Paragraph(para, st["BodyText2"]))
    flow.append(Spacer(1, 4 * mm))
    flow.append(Paragraph("Thanks,", st["BodyText2"]))
    flow.append(Paragraph(name, st["BodyText2"]))
    doc.build(flow)


def split_paras(body, max_sentences=2):
    """Break a run-on body into 1-2 sentence paragraphs for document realism."""
    import re

    sentences = re.split(r"(?<=[.!?])\s+", body.strip())
    paras, buf = [], []
    for s in sentences:
        buf.append(s)
        if len(buf) >= max_sentences:
            paras.append(" ".join(buf))
            buf = []
    if buf:
        paras.append(" ".join(buf))
    return paras


def main():
    records = [json.loads(l) for l in RECORDS.open()]
    # deterministic selection; prefer records with some length and variety
    pool = [r for r in records if len(r["body"]) > 180]
    random.shuffle(pool)
    chosen = pool[: N_LETTERS + N_EMAILS]

    DOC_DIR.mkdir(parents=True, exist_ok=True)
    st = styles()

    manifest = []
    for i, rec in enumerate(chosen):
        sender = SENDERS[i % len(SENDERS)]
        if i < N_LETTERS:
            fname = f"letter_{rec['complaint_id']}.pdf"
            render_letter(rec, sender, DOC_DIR / fname, st)
            kind = "letter"
        else:
            fname = f"email_{rec['complaint_id']}.pdf"
            render_email(rec, sender, DOC_DIR / fname, st)
            kind = "email"
        manifest.append((fname, kind, rec["complaint_id"]))

    lines = [
        "# Rendered complaint documents\n",
        f"{len(manifest)} documents for the Docling ingestion path "
        f"(deterministic, seed {SEED}).\n",
        "These are build outputs, regenerated from records.jsonl; the repo",
        "does not commit PDFs. The ingestion pipeline must parse both",
        "shapes to the same clean text.\n",
    ]
    for fname, kind, cid in manifest:
        lines.append(f"- {fname}  ({kind}, {cid})")
    (DOC_DIR / "MANIFEST.md").write_text("\n".join(lines) + "\n")

    print(f"Rendered {len(manifest)} documents -> {DOC_DIR}/")
    print(f"  {N_LETTERS} letters, {N_EMAILS} emails")


if __name__ == "__main__":
    main()
