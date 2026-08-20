# Running the Complaint Intelligence demo

How to demonstrate UC02 to a technical or mixed audience, and how to build
your own presentation materials around it.

This guide assumes you have a working environment (see REBUILD.md) and are
starting from nothing in terms of slides or recordings.

---

## What the demo shows

A classification pipeline that takes free-text complaint records and
produces standardised theme and root-cause classifications, each carrying
a verified citation, a confidence score, and a full provenance record.
Results aggregate into a themes view with trend indicators and a
cross-theme root cause analysis.

Four things it demonstrates that matter in a regulated environment:

1. Sensitive data is removed before it reaches a model or a vector index
2. Every classification is traceable to the specific text it rests on
3. The system routes its own uncertainty to a human rather than guessing
4. Individual records aggregate into systemic findings

---

## The five screens

Everything in the demo comes from one application with five views.

**Themes (`/`)** — the landing page. Totals for classified, routed to
review, and PII detected. Themes ranked by volume with trend indicators.
Below that, a root cause rollup showing which drivers appear across the
whole corpus.

**Theme detail (`/theme/<id>`)** — one theme, broken down by root cause,
with the complaints beneath. Root causes are clickable to filter.

**Root cause detail (`/root-cause/<id>`)** — the inverse view. One driver,
and every theme it appears in. This is where a cross-cutting systemic
issue becomes visible.

**Classify (`/classify`)** — a list of complaints with a re-classify
action. Running one shows the classification happening live against the
model, ending on a result page with the citation highlighted in the source
text.

**Review queue (`/review`)** — complaints the pipeline flagged as
genuinely uncertain, with the competing candidates and the reason.

**Evidence (`/evidence/<id>`)** — the full provenance record for one
classification. Reachable by clicking any complaint.

**Guardrails (`/guardrails`)** — one complaint before and after PII
redaction.

---

## Suggested structure

The demo works best as a complaint's journey rather than a feature tour.
Six beats:

| Beat | Screen              | Point being made                            |
| ---- | ------------------- | ------------------------------------------- |
| 1    | (none, framing)     | This is running, not conceptual             |
| 2    | Guardrails          | Sensitive data never reaches the model      |
| 3    | Classify → Evidence | Classification is grounded and provenanced  |
| 4    | Review queue        | The system knows what it doesn't know       |
| 5    | Themes → Root cause | Individual records become systemic findings |
| 6    | (none, close)       | Limits, and what happens next               |

**The order matters.** Beat 4 before beat 5 means the audience trusts the
aggregate numbers, because they've already seen the system admit
uncertainty rather than paper over it.

---

## Building your own materials

### Slides or screen share?

A twenty-minute screen share makes the _application_ the subject when the
subject should be the capability. Slides carrying the argument, with short
recorded segments carrying the proof, works better for a mixed audience.

Rough proportion for twenty minutes: twelve to thirteen minutes of slides,
four to five minutes of screen recording across five or six segments, and
a couple of minutes of buffer for interruptions.

### What deserves a recording

A segment earns its place by showing something a screenshot can't: motion,
sequence, or the system reacting. Live classification earns one, because
the wait and the result appearing are the point. A static themes list does
not; screenshot it into a slide.

The strongest candidates:

- **Guardrails**, because the before/after comparison needs the transition
- **Live classification**, because the wait and the reveal are the claim
- **Evidence record**, because the field list scrolling past is the argument
- **Review queue**, because seeing several uncertain cases conveys volume
- **Root cause drill-through**, because the click from one theme to seven
  is the moment the systemic finding lands

### Recording notes

- Full screen, no browser chrome, no bookmarks bar, single tab
- Zoom to 110 to 125% so text is legible projected
- Deliberate cursor movement; pause on whatever you're about to narrate
- Keep segments to 45 to 60 seconds
- Record silent and narrate live, so you can absorb interruptions
- Leave model latency in. Cutting it implies speed you aren't claiming
- Record the classification segment several times and keep the fastest take

Record in this order rather than presentation order:

1. Themes and root cause, back to back, immediately after a refresh
2. Review queue, same session
3. Evidence record, on a complaint you've chosen in advance
4. Live classification, several takes, on that same complaint
5. Guardrails last, since it needs reloading to find a good example

The first three depend on cache state matching storage, and recording
classification after the evidence record keeps the two consistent.

---

## Pre-flight checklist

Run within an hour of presenting. Every item here has caused a problem at
least once.

- [ ] Hit `/refresh`. The app caches state in memory and does not reload
      after a batch run. A dashboard disagreeing with the review queue
      mid-demo is avoidable
- [ ] Dashboard totals look right for your dataset
- [ ] Trend badges present on at least two themes. All reading 0% means
      the comparison window is too short for the data spread
- [ ] Review queue has items. **Zero means vector store search is
      returning nothing**, which silently breaks ambiguity detection while
      classification still appears to succeed
- [ ] No taxonomy IDs on the dashboard that aren't in `taxonomy.yaml`
- [ ] Your chosen demo complaint has `citation_verified: true`
- [ ] Note the complaint IDs in advance. Hunting for a good example on
      camera is the most common thing that spoils a recording

---

## Presenting principles

**Say the uncomfortable numbers first.** The referral rate, the synthetic
data, any Technology Preview components. Volunteering a limit is worth
more than defending it under questioning.

**Do not hide what the application surfaces about itself.** If it declares
that a check isn't configured, that's a feature of the demo. The operating
principle is that the system reports what it actually did.

**Let the systemic finding land.** The cross-theme root cause moment needs
a pause. Resist filling it.

**Put any requirements mapping at the end.** Structuring the whole demo
around a checklist is satisfying for whoever wrote the requirements and
deadening for everyone else.

---

## Known rough edges

Things a sharp audience may notice.

**The referral rate is high**, typically 40 to 45% on the sample dataset.
Deliberate: the data includes designed ambiguity and the threshold is
conservative. Frame it as a calibration decision rather than a defect, and
say the number before anyone divides it themselves.

**Similarity scores are low in absolute terms**, around 0.5 to 0.65. A
customer's description of a problem doesn't share vocabulary with a policy
definition of it. What matters is the separation between the top two
candidates, not the absolute values.

**Citation verification fails on a minority of records.** The model
paraphrases instead of quoting verbatim. Marked unverified rather than
accepted, which is the correct behaviour and worth pointing out if it
appears on screen.

**Prompt injection detection is not configured** on the standard build.
The application says so rather than claiming a check it isn't running.

**Occasionally the model returns a taxonomy ID that doesn't exist.**
Validated and routed to review, but the ID still appears in the rollup.

---

## Troubleshooting during setup

| Symptom                                          | Cause                                                                              | Fix                                                                                    |
| ------------------------------------------------ | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Review queue empty, dashboard shows referrals    | App cache is stale                                                                 | `/refresh`                                                                             |
| Review queue genuinely empty after refresh       | Vector store search returning nothing; ambiguity detection has no data             | Delete and recreate the vector store, verify the deletion took, repopulate, reclassify |
| Every trend badge reads 0%                       | Comparison window too short for the data spread                                    | Widen the window in the trend calculation                                              |
| App changes not visible after a successful build | Deployment still running the previous image                                        | `oc rollout restart deployment/complaint-intelligence-app`                             |
| Classification returns an error page             | Check the app log; the application surfaces model failures rather than hiding them | `oc logs deploy/complaint-intelligence-app`                                            |

---

## Adapting the length

**Ten minutes:** guardrails, classification and evidence, root cause
drill-through. Drop the uncertainty beat, which is a shame since it's the
differentiator, but it's the most compressible.

**Business audience:** shorten the guardrails detail to one sentence,
expand the prioritisation framing, drop anything about model selection.

**Technical deep dive:** this structure is the wrong shape. Build a
separate walkthrough around the pipeline architecture, the evidence
schema, and the retrieval design.
