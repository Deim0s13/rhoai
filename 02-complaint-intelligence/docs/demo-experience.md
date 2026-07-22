# Demo Experience

## Who this is for

The primary demo audience is not technical. Expect a mix of business
stakeholders, risk and compliance, and enterprise architecture. Some will be
deeply technical; most will not. Nobody in the room should be looking at a
terminal.

This is a constraint on the build, not a presentation detail. If a capability
can only be shown from a CLI, it cannot be demonstrated to this audience, and
one of the controls this use case commits to is explicitly about a risk or
compliance persona reviewing evidence without administrator involvement. A
person in that role does not have a terminal, and would not want one.

## The two-part narrative

The demo has two halves, and keeping them separate is what makes the pitch
work.

**The business outcome, shown in our application.** Complaint records become
themes and root causes. This is what the customer asked for and it must look
like something a bank would actually use.

**The platform capability, shown in the product's own interfaces.** Model
serving, guardrails, evidence and evaluation, shown in the OpenShift AI
console rather than in anything we built. The claim is not "our application is
trustworthy", it is "the platform provides this, and any workload on it
inherits the same controls".

The second half is the stronger argument, and it only lands if the first half
is clearly thin. See ADR-0007.

## The five views

### 1. Complaint in, intelligence out

Select a complaint. Watch it classify. The output shows theme, root cause,
confidence, and the citation highlighted in the source text itself.

The moment: the citation. Not "the AI said THM-05", but "the AI said THM-05
_because of this sentence_, which you can read".

Evidences: outputs grounded in source data (Quality and Consistency).

### 2. Theme dashboard

Around 200 complaints collapsed into ten themes with counts, root-cause
breakdown, and trend. Clicking a theme drills into its complaints.

The moment: the shift from individual complaints to systemic issues, which is
the entire business case, made visible in one screen.

Evidences: centralised themes and root causes; strategic insight and
systemised view (mapped in the controls matrix to the customer's stated
outcomes).

### 3. Review queue

Low-confidence classifications routed for human review, with the reason
visible and the two candidate themes the model was torn between.

The moment: the system saying "I am not sure about this one". For a risk
audience this is the most trust-building screen in the demo, and it is the one
most AI demos do not have.

Evidences: the system expresses uncertainty rather than guessing (Quality and
Consistency).

### 4. Guardrails in action

A complaint containing mock PII is redacted before it reaches the model or any
store, shown as before and after. The injection fixture is visibly blocked
with the policy that caught it.

The moment: complaint text is untrusted user content, and a real complainant
can write anything, including "ignore your instructions".

Evidences: PII protection; untrusted content cannot steer the system (Safety
and Trust).

### 5. Evidence view

Click any classification and see its full record: theme, root cause,
confidence, citation, guardrail decision, prompt version, model version,
taxonomy version, trace ID, timestamp. Exportable.

The moment: a compliance officer answering "how do we know this works?"
without asking anyone for help.

Evidences: interactions reviewable end to end; evidence reviewable without
platform administrators; evidence retained and exportable (Production
Readiness).

## Product interfaces to show alongside

Not built by us, and that is the point:

- **OpenShift AI console**: the model serving view, showing Granite deployed
  and monitored like any other workload
- **Guardrails configuration**: the policy applied at platform level, separate
  from the application
- **Evaluation and evidence tooling**: whatever the platform provides on the
  target version (see the version-delta findings in the deployment logs)
- **Standard OpenShift monitoring**: the AI workload in the same operational
  tooling as everything else, no parallel operating model

## What this implies for the build

The views above are a build contract, not a wish list. Specifically:

- **The evidence record must carry everything view 5 displays.** No field is
  added later; the schema in ADR-0004 is the source of truth and any view that
  needs a field means the schema changes first.
- **The review queue needs a reason, not just a score.** A low confidence value
  alone is not a demonstrable control. The record needs the candidate themes
  and the reason the model was uncertain.
- **The citation must carry character offsets**, not just text, so the source
  can be highlighted rather than quoted.
- **The guardrail decision must be captured per record**, not inferred from
  logs, or view 4 cannot be joined to view 5.

## Deliberately out of scope for the demo

Stated so their absence is not mistaken for an oversight:

- Authentication and multi-user. Single demo user.
- AssuranceNow integration. The write-back contract is documented, not
  simulated (see architecture.md).
- Production scale. Demo data volumes are small by design and the scaling path
  is documented.
- Workflow tooling for the review queue. The routing decision and its evidence
  are the demonstrated control, not the case management around it.

## Open decision — theme dashboard weighting.

Synthetic data deliberately weights digital and hardship themes to dominate. The dashboard must decide whether to foreground that skew (supports the "systemic issue" narrative) or normalise it (avoids looking like a cherry-picked demo). Decide before wireframing view 2 in earnest.
