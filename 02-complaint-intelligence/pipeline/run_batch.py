"""
pipeline/run_batch.py

Batch classification entrypoint (promoted from the notebook's Cells 6-9,
2026-07-28). Ensures the vector store is populated, then classifies every
complaint not yet done. Same shared module the notebook and the app both
use (ADR-0009); no logic duplicated here.

Run as a Kubernetes Job (manifests/job/batch-classify.yaml), triggered on
demand (`oc create -f manifests/job/batch-classify.yaml`), not scheduled,
matching the System-to-LLM batch/event-driven pattern in the ANZ use case
document, not continuous processing.

Exit code 0 if every complaint was classified or already done, 1 if any
record failed, so Job success/failure status is meaningful.
"""

import sys

from classify import Pipeline


def main():
    print("=== Batch classification ===\n")

    pipeline = Pipeline().setup()
    print(
        f"Pipeline ready. Model: {pipeline.model_id}, "
        f"vector store: {pipeline.vector_store_id}\n"
    )

    all_complaints = pipeline.load_all_complaints()
    print(f"Loaded {len(all_complaints)} complaints.")

    taxonomy_added = pipeline.populate_taxonomy()
    print(f"Taxonomy: {taxonomy_added} new documents added.")

    complaints_added, redacted_count = pipeline.populate_complaints(all_complaints)
    print(
        f"Complaints: {complaints_added} new documents added "
        f"({redacted_count} contained PII, redacted before embedding).\n"
    )

    results = {"classified": [], "skipped": [], "failed": []}

    for i, c in enumerate(all_complaints):
        if pipeline.already_classified(c["complaint_id"]):
            results["skipped"].append(c["complaint_id"])
            continue
        try:
            record = pipeline.classify_complaint(c)
            pipeline.write_evidence_record(record)
            results["classified"].append(c["complaint_id"])
        except Exception as e:
            results["failed"].append(
                {"complaint_id": c["complaint_id"], "error": str(e)}
            )

        if (i + 1) % 25 == 0:
            print(
                f"  processed {i + 1}/{len(all_complaints)} "
                f"({len(results['classified'])} classified, "
                f"{len(results['skipped'])} skipped, "
                f"{len(results['failed'])} failed so far)"
            )

    print(
        f"\nDone. Classified: {len(results['classified'])}, "
        f"Skipped (already done): {len(results['skipped'])}, "
        f"Failed: {len(results['failed'])}"
    )

    evidence = pipeline.load_all_evidence()
    routed_count = sum(1 for r in evidence.values() if r.get("routed_to_review"))
    pii_count = sum(1 for r in evidence.values() if r.get("pii_detected"))
    print(f"Routed to review: {routed_count}/{len(evidence)}")
    print(f"PII detected and redacted: {pii_count}/{len(evidence)}")

    if results["failed"]:
        print("\nFailures:")
        for f in results["failed"]:
            print(f"  {f['complaint_id']}: {f['error']}")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
