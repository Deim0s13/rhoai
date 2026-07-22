# ADR-0008: Inline Milvus vector store with inline sentence-transformers embeddings

**Status:** Accepted
**Date:** 2026-07-15

## Context

RHOAI 3.4 registers neither a vector store nor an embedding model by default.
Both are opt-in, and both are required before any retrieval or classification
work can begin. RHOAI 2.25 provided inline Milvus and two embedding models
without configuration, so this is a version delta rather than a gap.

The platform supports four vector store options: inline Milvus, inline FAISS,
remote Milvus, and remote PostgreSQL with pgvector. All four use PostgreSQL for
metadata persistence from 3.2. Embeddings can be served remotely (the
documented production recommendation) or inline via the sentence-transformers
library (documented for development and testing).

Two constraints shape the choice:

- **One GPU.** Granite 3.3 8B occupies the single L4 at 0.85 memory
  utilisation. A served embedding model would compete for the same card.
- **The demo must be rebuildable and self-contained.** Every additional
  component is another thing to deploy, wait for, and debug on demo morning.

## Decision

**Inline Milvus** as the vector store, **inline sentence-transformers** for
embeddings. Both enabled in the LlamaStackDistribution CR:

```yaml
- name: ENABLE_INLINE_MILVUS
  value: "true"
- name: ENABLE_SENTENCE_TRANSFORMERS
  value: "true"
- name: EMBEDDING_PROVIDER
  value: "sentence-transformers"
```

### Why inline Milvus over the alternatives

- **Consistency with the material we have already written.** The architecture
  document, the conceptual diagram and the customer proposal all say Milvus.
  Choosing FAISS or pgvector would mean either revising those or explaining a
  mismatch mid-demo.
- **It is the vector store a customer will recognise** in the Red Hat RAG
  story, and "inline for the demo, remote for production" is a clean, honest
  sentence that maps to the documented options.
- **pgvector was the serious runner-up.** It would reuse the PostgreSQL we
  already deploy, dropping a component. Rejected on narrative consistency
  rather than technical merit; it remains the better choice for an organisation
  already operating PostgreSQL, and the architecture should say so.
- **FAISS is lighter but adds nothing** we do not already have, and is the
  option furthest from what we would recommend in production.

### Why inline embeddings

Serving an embedding model via vLLM means a second GPU consumer on a
single-GPU cluster. The docs recommend remote embeddings for production, and
that recommendation stands; for a demo constrained to one L4, inline
sentence-transformers running on CPU is the pragmatic choice. The node has
31.5 CPU and 125GB allocatable, so CPU-based embedding is not a constraint at
demo data volumes.

## Validated configuration

Confirmed on RHOAI 3.4.2, 2026-07-15:

- **Vector provider:** `provider_id: milvus`, `provider_type: inline::milvus`
- **Vector data path:** `/opt/app-root/src/.llama/distributions/rh/milvus.db`,
  which is on the mounted 20Gi PVC and therefore survives pod restarts
- **Metadata persistence:** `backend: kv_default`,
  `namespace: vector_io::milvus`, which resolves to the PostgreSQL metadata
  store
- **Embedding provider:** `provider_id: sentence-transformers`,
  `provider_type: inline::sentence-transformers`
- **Embedding model:** `sentence-transformers/nomic-ai/nomic-embed-text-v1.5`,
  **768 dimensions**
- **Startup:** pod reached 1/1 in 21 seconds, so embedding weights are resolved
  from the image cache rather than downloaded from Hugging Face. There is no
  network dependency at pod start.

RHOAI 2.25 registered `granite-embedding-125m` (768) and `all-MiniLM-L6-v2`
(384) instead. The embedding model is therefore a version-dependent fact, not a
constant, which is itself an argument for reading it from `/v1/models` at
runtime rather than hard-coding it.

## Consequences

- **The pipeline reads its embedding configuration at runtime**, not from
  constants:

```python
  embedding = next(m for m in models if m.model_type == "embedding")
  embedding_model_id = embedding.identifier
  embedding_dimension = int(embedding.metadata["embedding_dimension"])
```

Given the model changed between two consecutive platform versions, hard-coding
it would guarantee breakage on the next.

- **Vector store registration happens at runtime**, via the client SDK with
  `provider_id: "milvus"`, not in the CR. The pipeline creates the store.

- **This is the development posture, and the demo should say so.** Production is
  remote Milvus (with its own etcd) or pgvector, plus a served embedding model.
  Inline Milvus provides no high availability or horizontal scalability. The
  architecture document's deviations table carries this.

- **The switch is configuration, not code.** Because the vector store sits
  behind Llama Stack's API, moving to remote Milvus or pgvector changes
  environment variables and a `provider_id` string, not pipeline logic. This is
  the substitutability the layered design was intended to buy, and it is now
  demonstrable rather than asserted.

- **Both providers are opt-in from 3.4.** Anyone carrying a 2.25 Llama Stack
  configuration forward gets a silently retrieval-less stack: no error, just no
  vector_io provider and no embedding model. Worth flagging to anyone else
  building on this.

- **The RAG stack is Technology Preview in RHOAI 3.4**, unlike guardrails, MaaS
  and MLflow which are GA. This must be stated honestly in any customer
  conversation about production timelines.

## Addendum 2026-07-22: retrieval design

Confirms architecture.md's stated position ("parsed complaints embedded
alongside the taxonomy, forming the knowledge layer") and resolves how.

### Decision: one vector store, not two

A single store, not separate stores for taxonomy and complaints. Each
document carries a `kind` metadata field (`taxonomy` or `complaint`).
Reasoning: one store is one thing to create, version, and reason about
operationally; the OpenAI-native search API supports metadata filtering, so
a single store doesn't force mixed, undifferentiated retrieval.

### Decision: two filtered searches per classification, not one mixed search

At classification time, run two separate `search` calls against the same
store: one filtered to `kind=taxonomy` (top-k 3), one filtered to
`kind=complaint` (top-k 3). Combine into the prompt as two clearly labeled
sections ("Relevant taxonomy guidance" / "Similar past complaints"), not one
undifferentiated block.

Rejected: a single unfiltered search across both. At this corpus size (17
taxonomy documents, 200 complaints), an unfiltered top-k search skews
toward whichever category dominates semantically for a given complaint,
risking a classification that sees three similar complaints and zero
taxonomy guidance, or the reverse. Filtering costs one extra API call per
classification and removes that risk entirely.

### What gets embedded: taxonomy

One document per theme (10) and one per root cause (7), 17 total. Each
embeds its `definition`, `includes`, `excludes`, and `examples` fields
concatenated, matching taxonomy.yaml's own stated intent that these fields
"are retrieval content... the primary lever for classification quality with
a small model."

Metadata per taxonomy document:

```json
{
  "kind": "taxonomy",
  "item_type": "theme",
  "id": "THM-05",
  "name": "...",
  "taxonomy_version": "0.1.0"
}
```

### What gets embedded: complaints

One document per complaint record, embedding `body` directly. No chunking:
synthetic complaint bodies are single short paragraphs, not the
multi-page regulatory documents UC01's chunking strategy was designed for.
Chunking here would be complexity with no corresponding benefit.

Metadata per complaint document:

```json
{ "kind": "complaint", "complaint_id": "CMP-0031", "channel": "...", "received_date": "..." }
```

### Build implication

Cell 7 (currently a route-discovery placeholder) becomes two things: a
one-time store creation and population step (idempotent, check-if-exists),
and a per-classification retrieval step inserted before Cell 8, replacing
the empty `retrieved_context` string with the two labeled, filtered search
results.
