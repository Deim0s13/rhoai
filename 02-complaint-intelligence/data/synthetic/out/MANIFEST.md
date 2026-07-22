# Synthetic dataset manifest

Generated deterministically (seed 20260716). 200 records total.

## By category

- ambiguous: 15
- clean: 171
- injection: 2
- near_duplicate: 12
- PII carriers (planted across categories): 25

## By theme (ground truth)

- THM-01:  16  ################
- THM-02:  21  #####################
- THM-03:   9  #########
- THM-04:  15  ###############
- THM-05:  54  ######################################################
- THM-06:  20  ####################
- THM-07:  34  ##################################
- THM-08:   7  #######
- THM-09:   8  ########
- THM-10:  16  ################

## Reference set

- 60 records, labelled theme + root_cause only
- ambiguous included: 15
- injection included: 2

## Notes

- records.jsonl carries no labels: it is the ingestion input.
- reference-labels.jsonl is the accuracy baseline (theme + root_cause). PII correctness is verified separately by the guardrail, per ADR-0004.
- ambiguous records carry candidate_theme_id: the second defensible theme, for the review-queue view.
