# Synthetic dataset manifest

Generated deterministically (seed 20260716). 200 records total.

Date window: 2026-01-01 to 2026-06-30. Themes shaped to rise across the window: THM-05, THM-07.

## By category

- ambiguous: 15
- clean: 171
- injection: 2
- near_duplicate: 12
- PII carriers (planted across categories): 25

## By theme (ground truth)

- THM-01:  11  ###########
- THM-02:  20  ####################
- THM-03:   9  #########
- THM-04:  16  ################
- THM-05:  51  ###################################################
- THM-06:  19  ###################
- THM-07:  37  #####################################
- THM-08:   8  ########
- THM-09:   9  #########
- THM-10:  20  ####################

## Theme volume, first half vs second half of window

- THM-01: H1   7  H2   4
- THM-02: H1  10  H2  10
- THM-03: H1   3  H2   6
- THM-04: H1   9  H2   7
- THM-05: H1  16  H2  35  <- shaped to rise
- THM-06: H1   9  H2  10
- THM-07: H1  14  H2  23  <- shaped to rise
- THM-08: H1   6  H2   2
- THM-09: H1   4  H2   5
- THM-10: H1  12  H2   8

## Reference set

- 60 records, labelled theme + root_cause only
- ambiguous included: 15
- injection included: 2

## Notes

- records.jsonl carries no labels: it is the ingestion input.
- reference-labels.jsonl is the accuracy baseline (theme + root_cause). PII correctness is verified separately by the guardrail, per ADR-0004.
- ambiguous records carry candidate_theme_id: the second defensible theme, for the review-queue view.
- received_date is ISO; dates inside body text are prose. Both fall inside the same window.
