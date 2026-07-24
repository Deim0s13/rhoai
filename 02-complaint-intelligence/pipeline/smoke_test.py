"""
pipeline/smoke_test.py

Standalone verification script, doubles as a rebuild-validation gate.
Constructs a Pipeline, runs the full setup sequence, and classifies one
known complaint end to end, no mocking, the real guardrails call, the
real retrieval, the real model call. Exits 0 on success, 1 on any
failure, with a clear message identifying which stage failed.

Run inside the cluster (needs in-cluster DNS for Llama Stack, guardrails,
and MinIO), from the workbench once pipeline-code is mounted:

    oc exec <workbench-pod> -n complaint-intelligence -- \\
        python3 /opt/app-root/pipeline/smoke_test.py

Requires: requests, pyyaml, minio (same as notebook Cell 1). If these
aren't installed yet in this workbench, install them first:

    oc exec <workbench-pod> -n complaint-intelligence -- \\
        pip install --quiet requests pyyaml minio --break-system-packages
"""

import sys
import traceback

try:
    from classify import Pipeline
except ImportError as e:
    print(f"FAIL: could not import pipeline.classify ({e})")
    print(
        "Confirm /opt/app-root/pipeline/classify.py is mounted "
        "(see ADR-0009, manifests/workbench/workbench.yaml)"
    )
    sys.exit(1)


TEST_COMPLAINT_ID = "CMP-0031"  # validated repeatedly this build; a
# genuine scam complaint, unambiguous,
# good baseline for "is the pipeline
# basically working" rather than
# exercising an edge case


def check(label: str, fn):
    """Runs one stage, prints PASS/FAIL, re-raises on failure so the
    script stops at the first broken stage rather than cascading into
    confusing downstream errors."""
    try:
        result = fn()
        print(f"PASS: {label}")
        return result
    except Exception as e:
        print(f"FAIL: {label}")
        print(f"      {type(e).__name__}: {e}")
        raise


def main():
    print("=== Pipeline smoke test ===\n")

    pipeline = check("Pipeline constructed (env vars present)", lambda: Pipeline())

    taxonomy = check(
        "Taxonomy loaded (ConfigMap mount)",
        pipeline.load_taxonomy,
    )
    print(
        f"      {len(taxonomy['themes'])} themes, "
        f"{len(taxonomy['root_causes'])} root causes"
    )

    model_id = check(
        "Granite model discovered (InferenceService + Llama Stack)",
        pipeline.discover_model,
    )
    print(f"      {model_id}")

    embedding_model_id, embedding_dim = check(
        "Embedding model discovered",
        pipeline.discover_embedding_model,
    )
    print(f"      {embedding_model_id} ({embedding_dim} dims)")

    vector_store_id = check(
        "Vector store reachable (create-or-find)",
        pipeline.get_or_create_vector_store,
    )
    print(f"      {vector_store_id}")

    complaints = check(
        "Complaints bucket readable",
        pipeline.load_all_complaints,
    )
    print(f"      {len(complaints)} complaints loaded")

    test_complaint = check(
        f"Test complaint {TEST_COMPLAINT_ID} present in dataset",
        lambda: next(c for c in complaints if c["complaint_id"] == TEST_COMPLAINT_ID),
    )

    record = check(
        "End-to-end classification (guardrails, retrieval, model call, "
        "citation, routing)",
        lambda: pipeline.classify_complaint(test_complaint),
    )

    def validate_record_shape():
        required = [
            "complaint_id",
            "theme_id",
            "root_cause_id",
            "confidence",
            "citation",
            "citation_verified",
            "routed_to_review",
            "review_reason",
            "candidate_themes",
            "pii_detected",
            "pii_redactions",
            "trace_id",
        ]
        missing = [k for k in required if k not in record]
        if missing:
            raise RuntimeError(f"Evidence record missing fields: {missing}")
        if not (0.0 <= record["confidence"] <= 1.0):
            raise RuntimeError(f"confidence out of range: {record['confidence']}")
        if not record["theme_id"].startswith("THM-"):
            raise RuntimeError(f"theme_id malformed: {record['theme_id']}")
        return True

    check("Evidence record shape is correct", validate_record_shape)

    print(
        f"\n      theme_id={record['theme_id']} "
        f"root_cause_id={record['root_cause_id']} "
        f"confidence={record['confidence']} "
        f"routed_to_review={record['routed_to_review']}"
    )

    print("\n=== All checks passed. Pipeline is correctly wired. ===")
    print("(This run did NOT write to the evidence bucket, no side effects.)")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(
            "\n=== Smoke test FAILED. See the first FAIL above for the "
            "specific broken stage. ==="
        )
        sys.exit(1)
    sys.exit(0)
