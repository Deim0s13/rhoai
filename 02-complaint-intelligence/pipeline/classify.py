"""
pipeline/classify.py

Shared classification module (ADR-0009). Single source of truth for
guardrails/redaction, retrieval, prompt construction, the model call,
citation matching, ADR-0004 review routing, and vector store population
helpers. Imported by both the notebook (01-classify-complaint.ipynb) and
the demo application (app/app.py). Fix something once, here, and both
consumers pick it up automatically.

Restructured as a class (not module-level functions/globals, the
notebook's original pattern) because the application is a long-running
process serving concurrent requests; it needs an object constructed once
at startup, not a script whose correctness depends on cells having run in
a specific order.
"""

import io
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml
from minio import Minio


class Config:
    """Configuration from environment variables. Defaults match what was
    validated live against RHOAI 3.4.2 (DEPLOYMENT-LOG-2026-07-15/22/23)."""

    def __init__(self):
        self.llama_stack_url = os.environ.get(
            "LLAMA_STACK_URL", "http://lsd-complaint-intelligence-service:8321"
        )
        self.guardrails_url = os.environ.get(
            "GUARDRAILS_URL", "https://guardrails-orchestrator-service:8032"
        )
        self.taxonomy_path = os.environ.get(
            "TAXONOMY_PATH", "/opt/app-root/taxonomy/taxonomy.yaml"
        )
        self.minio_endpoint = os.environ.get(
            "MINIO_ENDPOINT", "minio.complaint-intelligence.svc.cluster.local:9000"
        )
        self.minio_access_key = os.environ["MINIO_ACCESS_KEY"]  # fail fast if not set
        self.minio_secret_key = os.environ["MINIO_SECRET_KEY"]  # fail fast if not set

        # NB: real bucket names, not the `mc` alias (`uc02`) used when
        # seeding from a laptop.
        self.complaints_bucket = "complaints"
        self.evidence_bucket = "evidence"
        self.complaints_key = "incoming/records.jsonl"
        self.evidence_prefix = "classifications"

        self.vector_store_name = "uc02-complaint-intelligence"

        # ADR-0004 (2026-07-23): demo-appropriate value, not calibrated
        # against a statistically meaningful labeled set.
        self.ambiguity_delta_threshold = 0.03


class Pipeline:
    """Holds live client state and exposes the classification methods.
    One instance per process. Call .setup() once at startup before using
    any other method."""

    def __init__(self, config: Config = None):
        self.config = config or Config()
        self.minio_client = Minio(
            self.config.minio_endpoint,
            access_key=self.config.minio_access_key,
            secret_key=self.config.minio_secret_key,
            secure=False,
        )
        self.taxonomy = None
        self.taxonomy_version = None
        self.confidence_threshold = None
        self.model_id = None
        self.embedding_model_id = None
        self.embedding_dimension = None
        self.vector_store_id = None

    # ---------------------------------------------------------------
    # Setup, run once at process startup
    # ---------------------------------------------------------------

    def load_taxonomy(self) -> dict:
        p = Path(self.config.taxonomy_path)
        if not p.exists():
            raise RuntimeError(
                f"Taxonomy not found at {self.config.taxonomy_path}. Confirm "
                f"the taxonomy ConfigMap volume is mounted."
            )
        self.taxonomy = yaml.safe_load(p.read_text())
        self.taxonomy_version = self.taxonomy["version"]
        self.confidence_threshold = self.taxonomy["classification"][
            "confidence_threshold"
        ]
        return self.taxonomy

    def discover_model(self) -> str:
        resp = requests.get(f"{self.config.llama_stack_url}/v1/models")
        resp.raise_for_status()
        models = resp.json().get("data", resp.json())
        candidates = [m for m in models if "granite" in m.get("id", "").lower()]
        if not candidates:
            raise RuntimeError(
                f"No Granite model found in /v1/models. Got: {models}\n"
                f"If the InferenceService is healthy but still missing here, "
                f"Llama Stack likely needs a restart to re-discover it."
            )
        self.model_id = candidates[0]["id"]
        return self.model_id

    def discover_embedding_model(self):
        resp = requests.get(f"{self.config.llama_stack_url}/v1/models")
        resp.raise_for_status()
        models = resp.json().get("data", resp.json())
        candidates = [
            m
            for m in models
            if m.get("custom_metadata", {}).get("model_type") == "embedding"
        ]
        if not candidates:
            raise RuntimeError(f"No embedding model found in /v1/models. Got: {models}")
        self.embedding_model_id = candidates[0]["id"]
        self.embedding_dimension = candidates[0]["custom_metadata"][
            "embedding_dimension"
        ]
        return self.embedding_model_id, self.embedding_dimension

    def get_or_create_vector_store(self) -> str:
        list_resp = requests.get(f"{self.config.llama_stack_url}/v1/vector_stores")
        list_resp.raise_for_status()
        existing = [
            s
            for s in list_resp.json().get("data", [])
            if s.get("name") == self.config.vector_store_name
        ]
        if existing:
            self.vector_store_id = existing[0]["id"]
        else:
            create_resp = requests.post(
                f"{self.config.llama_stack_url}/v1/vector_stores",
                json={
                    "name": self.config.vector_store_name,
                    "embedding_model": self.embedding_model_id,
                    "embedding_dimension": self.embedding_dimension,
                },
            )
            if not create_resp.ok:
                raise RuntimeError(
                    f"Store creation failed ({create_resp.status_code}): {create_resp.text}"
                )
            self.vector_store_id = create_resp.json()["id"]
        return self.vector_store_id

    def setup(self) -> "Pipeline":
        """Runs the full startup sequence in order. Returns self, so this
        can be chained: pipeline = Pipeline().setup()"""
        self.load_taxonomy()
        self.discover_model()
        self.discover_embedding_model()
        self.get_or_create_vector_store()
        return self

    # ---------------------------------------------------------------
    # PII detection and redaction
    # ---------------------------------------------------------------

    def check_pii(self, text: str):
        """FIXED 2026-07-23: reads response['detections'] explicitly.
        The original bug measured len() on the whole response dict
        (always 1, one key: "detections"), making pii_detected always
        True and pii_redactions always 1 regardless of real content."""
        resp = requests.post(
            f"{self.config.guardrails_url}/api/v2/text/detection/content",
            json={
                "detectors": {"regex": {"regex": ["email", "credit-card"]}},
                "content": text,
            },
            verify=False,
        )
        resp.raise_for_status()
        spans = resp.json().get("detections", [])
        return len(spans) > 0, spans

    def redact_pii(self, text: str, spans: list) -> str:
        """Processes spans in reverse start-offset order so earlier
        offsets are not shifted by replacements made later in the
        string."""
        for span in sorted(spans, key=lambda s: s["start"], reverse=True):
            placeholder = f"[REDACTED:{span['detection'].upper()}]"
            text = text[: span["start"]] + placeholder + text[span["end"] :]
        return text

    # ---------------------------------------------------------------
    # Vector store operations
    # ---------------------------------------------------------------

    def add_document(self, text: str, metadata: dict) -> str:
        upload_resp = requests.post(
            f"{self.config.llama_stack_url}/v1/files",
            files={"file": ("doc.txt", text.encode("utf-8"))},
            data={"purpose": "assistants"},
        )
        if not upload_resp.ok:
            raise RuntimeError(
                f"File upload failed ({upload_resp.status_code}): {upload_resp.text}"
            )
        file_id = upload_resp.json()["id"]

        attach_resp = requests.post(
            f"{self.config.llama_stack_url}/v1/vector_stores/{self.vector_store_id}/files",
            json={"file_id": file_id, "attributes": metadata},
        )
        if not attach_resp.ok:
            raise RuntimeError(
                f"Attach to store failed ({attach_resp.status_code}): {attach_resp.text}"
            )
        return file_id

    def existing_ids_for_kind(self, kind: str) -> set:
        """Paginates via the `after` cursor (ADR-0008: the listing
        endpoint defaults to 20 results per page and silently ignores a
        `limit` override, that param is dropped, not honored)."""
        ids = set()
        after = None
        while True:
            params = {"after": after} if after else {}
            resp = requests.get(
                f"{self.config.llama_stack_url}/v1/vector_stores/{self.vector_store_id}/files",
                params=params,
            )
            resp.raise_for_status()
            page = resp.json()
            files = page.get("data", [])
            ids.update(
                f["attributes"]["id"]
                for f in files
                if f.get("attributes", {}).get("kind") == kind
                and "id" in f.get("attributes", {})
            )
            if not page.get("has_more") or not files:
                break
            after = files[-1]["id"]
        return ids

    def search_by_kind(self, query: str, kind: str, top_k: int = 3) -> list:
        """Typed-filter syntax confirmed live 2026-07-22 (a flat dict
        filter silently returns zero results rather than erroring, do
        not revert to that shape, see ADR-0008)."""
        resp = requests.post(
            f"{self.config.llama_stack_url}/v1/vector_stores/{self.vector_store_id}/search",
            json={
                "query": query,
                "filters": {"type": "eq", "key": "kind", "value": kind},
                "max_num_results": top_k,
            },
        )
        if not resp.ok:
            raise RuntimeError(f"Search failed ({resp.status_code}): {resp.text}")
        return resp.json().get("data", [])

    def taxonomy_theme_ambiguity(self, chosen_theme_id: str, body: str) -> dict:
        """ADR-0004 review-routing signal, corrected 2026-07-24: compares
        the model's ACTUAL chosen theme against the next-best alternative
        from retrieval, not a blind top-2 that could exclude the model's
        own pick entirely. Found live via the deployed app's review queue
        (not visible in raw JSON): a blind top-2 comparison regularly
        named two themes unrelated to what the model actually chose,
        since the original version computed this independently, with no
        knowledge of the classification result. top_k=10 covers all 10
        themes in the taxonomy, so the chosen theme's own retrieval score
        is always present to compare against, by construction."""
        hits = self.search_by_kind(body, "taxonomy", top_k=10)
        theme_hits = {
            h["attributes"]["id"]: h["score"]
            for h in hits
            if h["attributes"].get("item_type") == "theme"
        }

        if chosen_theme_id not in theme_hits or len(theme_hits) < 2:
            return {
                "top_theme": None,
                "top_score": None,
                "second_theme": None,
                "second_score": None,
                "delta": None,
            }

        chosen_score = theme_hits[chosen_theme_id]
        others = {
            tid: score for tid, score in theme_hits.items() if tid != chosen_theme_id
        }
        best_other_id = max(others, key=others.get)
        best_other_score = others[best_other_id]

        return {
            "top_theme": chosen_theme_id,
            "top_score": chosen_score,
            "second_theme": best_other_id,
            "second_score": best_other_score,
            "delta": chosen_score - best_other_score,
        }

    def lookup_classification(self, complaint_id: str):
        """Returns the confirmed classification for a complaint from its
        evidence record, for label-enriched retrieval. None if
        unclassified, or if that record was routed to review, an
        unconfirmed classification is not surfaced as precedent."""
        try:
            obj = self.minio_client.get_object(
                self.config.evidence_bucket,
                f"{self.config.evidence_prefix}/{complaint_id}.json",
            )
            rec = json.loads(obj.read())
            obj.close()
            obj.release_conn()
            if rec.get("routed_to_review"):
                return None
            return {"theme_id": rec["theme_id"], "root_cause_id": rec["root_cause_id"]}
        except Exception:
            return None

    # ---------------------------------------------------------------
    # Classification
    # ---------------------------------------------------------------

    def classify_complaint(self, c: dict) -> dict:
        """Runs one complaint through guardrails/redaction, retrieval,
        classification, and ADR-0004 review routing. Returns the
        evidence record; does not write it (see write_evidence_record)."""

        pii_detected, pii_spans = self.check_pii(c["body"])
        pii_redactions = len(pii_spans)
        redacted_body = self.redact_pii(c["body"], pii_spans)
        injection_blocked = None  # not configured on this stack

        taxonomy_hits = self.search_by_kind(redacted_body, "taxonomy", top_k=3)
        complaint_hits = [
            r
            for r in self.search_by_kind(redacted_body, "complaint", top_k=4)
            if r["attributes"].get("id") != c["complaint_id"]
        ][:3]
        taxonomy_section = (
            "\n".join(f"- {r['content'][0]['text']}" for r in taxonomy_hits)
            if taxonomy_hits
            else "(none retrieved)"
        )
        complaint_lines = []
        for r in complaint_hits:
            cid = r["attributes"].get("id")
            cls = self.lookup_classification(cid) if cid else None
            label = (
                f" [confirmed classification: {cls['theme_id']}]"
                if cls
                else " [classification not yet confirmed]"
            )
            complaint_lines.append(f"- {r['content'][0]['text'][:200]}{label}")
        complaint_section = (
            "\n".join(complaint_lines) if complaint_lines else "(none retrieved)"
        )
        retrieved_context = (
            f"Relevant taxonomy guidance:\n{taxonomy_section}\n\n"
            f"Similar past complaints:\n{complaint_section}"
        )

        theme_block = "\n".join(
            f"- {t['id']}: {t['name']} — {t['definition'].strip()}"
            for t in self.taxonomy["themes"]
        )
        root_cause_block = "\n".join(
            f"- {r['id']}: {r['name']} — {r['definition'].strip()}"
            for r in self.taxonomy["root_causes"]
        )
        prompt = f"""You are classifying a bank complaint against a fixed taxonomy.

Themes:
{theme_block}

Root causes:
{root_cause_block}

{retrieved_context}

Complaint:
\"\"\"{redacted_body}\"\"\"

Respond with JSON only, no other text, in this exact shape:
{{
  "theme_id": "THM-XX",
  "root_cause_id": "RC-XX",
  "confidence": 0.0,
  "citation_text": "the exact sentence from the complaint that supports this classification"
}}

citation_text must be copied verbatim from the complaint text above."""

        completion_resp = requests.post(
            f"{self.config.llama_stack_url}/v1/chat/completions",
            json={
                "model": self.model_id,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 500,
                "temperature": 0.0,
            },
        )
        completion_resp.raise_for_status()
        raw = completion_resp.json()["choices"][0]["message"]["content"]

        # FIXED 2026-07-23: the model occasionally emits content after the
        # closing JSON brace. raw_decode() parses the first valid JSON
        # object and ignores anything trailing, instead of rejecting the
        # whole response ("Extra data").
        try:
            classification = json.JSONDecoder().raw_decode(raw.strip())[0]
        except json.JSONDecodeError:
            raise RuntimeError(f"Model did not return valid JSON:\n{raw}")

        citation_text = classification["citation_text"]
        start = redacted_body.find(citation_text)
        if start == -1:
            citation = {"start": None, "end": None, "text": citation_text}
            citation_verified = False
        else:
            citation = {
                "start": start,
                "end": start + len(citation_text),
                "text": citation_text,
            }
            citation_verified = True

        confidence = classification["confidence"]
        taxonomy_ambig = self.taxonomy_theme_ambiguity(
            classification["theme_id"], redacted_body
        )

        low_confidence = confidence < self.confidence_threshold
        narrow_margin = (
            taxonomy_ambig["delta"] is not None
            and taxonomy_ambig["delta"] < self.config.ambiguity_delta_threshold
        )
        routed_to_review = low_confidence or narrow_margin

        reasons = []
        if low_confidence:
            reasons.append(
                f"confidence {confidence:.2f} below threshold {self.confidence_threshold}"
            )
        if narrow_margin:
            reasons.append(
                f"top two taxonomy matches ({taxonomy_ambig['top_theme']}: "
                f"{taxonomy_ambig['top_score']:.2f}, {taxonomy_ambig['second_theme']}: "
                f"{taxonomy_ambig['second_score']:.2f}) within "
                f"{self.config.ambiguity_delta_threshold} of each other"
            )
        review_reason = "; ".join(reasons) if reasons else None

        candidate_theme_ids = []
        if narrow_margin:
            reasons.append(
                f"chosen theme {taxonomy_ambig['top_theme']} ({taxonomy_ambig['top_score']:.2f}) "
                f"is close to the next-best match {taxonomy_ambig['second_theme']} "
                f"({taxonomy_ambig['second_score']:.2f}), within "
                f"{self.config.ambiguity_delta_threshold} of each other"
            )

        return {
            "complaint_id": c["complaint_id"],
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "theme_id": classification["theme_id"],
            "root_cause_id": classification["root_cause_id"],
            "confidence": confidence,
            "citation": citation,
            "citation_verified": citation_verified,
            "routed_to_review": routed_to_review,
            "review_reason": review_reason,
            "candidate_themes": candidate_theme_ids,
            "pii_detected": pii_detected,
            "pii_redactions": pii_redactions,
            "injection_blocked": injection_blocked,
            "guardrail_policy_id": "regex",
            "prompt_version": "0.1.0",
            "model_version": self.model_id,
            "taxonomy_version": self.taxonomy_version,
            "trace_id": completion_resp.json().get("id", str(uuid.uuid4())),
        }

    def write_evidence_record(self, record: dict) -> str:
        record_bytes = json.dumps(record).encode("utf-8")
        record_key = f"{self.config.evidence_prefix}/{record['complaint_id']}.json"
        self.minio_client.put_object(
            self.config.evidence_bucket,
            record_key,
            data=io.BytesIO(record_bytes),
            length=len(record_bytes),
            content_type="application/json",
        )
        return record_key

    # ---------------------------------------------------------------
    # Bulk loaders, used by both consumers
    # ---------------------------------------------------------------

    def load_all_complaints(self) -> list:
        response = self.minio_client.get_object(
            self.config.complaints_bucket, self.config.complaints_key
        )
        lines = response.read().decode("utf-8").splitlines()
        response.close()
        response.release_conn()
        return [json.loads(l) for l in lines]

    def load_all_evidence(self) -> dict:
        """Returns {complaint_id: evidence_record} for every record
        currently in the evidence bucket. Used by the app at startup and
        by /refresh."""
        result = {}
        objects = self.minio_client.list_objects(
            self.config.evidence_bucket,
            prefix=f"{self.config.evidence_prefix}/",
            recursive=True,
        )
        for obj in objects:
            data = self.minio_client.get_object(
                self.config.evidence_bucket, obj.object_name
            )
            rec = json.loads(data.read())
            data.close()
            data.release_conn()
            result[rec["complaint_id"]] = rec
        return result

    def already_classified(self, complaint_id: str) -> bool:
        """NOTE: the broad except treats ANY failure (auth, network,
        wrong bucket) as "not yet classified", not just a genuine
        missing-key case. Acceptable for a demo corpus; would need
        narrowing to the specific S3 NoSuchKey exception for
        production use."""
        try:
            self.minio_client.stat_object(
                self.config.evidence_bucket,
                f"{self.config.evidence_prefix}/{complaint_id}.json",
            )
            return True
        except Exception:
            return False
