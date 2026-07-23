# ADR-0008: Inline Milvus vector store with inline sentence-transformers embeddings

**Status:** Accepted
**Date:** 2026-07-15
**Last revised:** 2026-07-23

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

- **Consistency with the material already written.** The architecture
  document, the conceptual diagram, and the customer proposal all say
  Milvus. Choosing FAISS or pgvector would mean either revising those or
  explaining a mismatch mid-demo.
- **It is the vector store a customer will recognise** in the Red Hat RAG
  story, and "inline for the demo, remote for production" is a clean, honest
  sentence that maps to the documented options.
- **pgvector was the serious runner-up.** It would reuse the PostgreSQL
  already deployed, dropping a component. Rejected on narrative consistency
  rather than technical merit; it remains the better choice for an
  organisation already operating PostgreSQL, and the architecture should
  say so.
- **FAISS is lighter but adds nothing** not already available, and is the
  option furthest from what would be recommended in production.

### Why inline embeddings

Serving an embedding model via vLLM means a second GPU consumer on a
single-GPU cluster. The docs recommend remote embeddings for production,
and that recommendation stands; for a demo constrained to one L4, inline
sentence-transformers running on CPU is the pragmatic choice. The node has
31.5 CPU and 125GB allocatable, so CPU-based embedding is not a constraint
at demo data volumes.

## Retrieval design: one store, filtered by kind

Confirms `architecture.md`'s stated position ("parsed complaints embedded
alongside the taxonomy, forming the knowledge layer") and resolves how.

**One vector store, not two.** Each document carries a `kind` attribute
(`taxonomy` or `complaint`), rather than maintaining separate stores. One
store is one thing to create, version, and reason about operationally; the
OpenAI-native search API supports metadata filtering, so a single store
does not force mixed, undifferentiated retrieval.

**Two filtered searches per classification, not one mixed search.** At
classification time, two separate `search` calls run against the same
store: one filtered to `kind=taxonomy` (top-k 3), one filtered to
`kind=complaint` (top-k 3, excluding the complaint being classified).
Combined into the prompt as two labeled sections ("Relevant taxonomy
guidance" / "Similar past complaints").

Rejected: a single unfiltered search across both. At this corpus size (17
taxonomy documents, 200 complaints), an unfiltered top-k search skews
toward whichever category dominates semantically for a given complaint,
risking a classification that sees three similar complaints and zero
taxonomy guidance, or the reverse. Filtering costs one extra API call per
classification and removes that risk entirely.

**What gets embedded: taxonomy.** One document per theme (10) and per root
cause (7), 17 total. Each embeds `definition`, `includes`, `excludes`, and
`examples` concatenated, matching `taxonomy.yaml`'s own stated intent that
these fields are retrieval content, not decoration.

```json
{ "kind": "taxonomy", "item_type": "theme", "id": "THM-05" }
```

**What gets embedded: complaints.** One document per complaint record,
embedding `body` directly, no chunking. Synthetic complaint bodies are
single short paragraphs, not the multi-page regulatory documents UC01's
chunking strategy was designed for; chunking here would be complexity with
no corresponding benefit.

```json
{ "kind": "complaint", "id": "CMP-0031", "channel": "...", "received_date": "..." }
```

## Validated configuration

Confirmed on RHOAI 3.4.2, 2026-07-15:

- **Vector provider:** `provider_id: milvus`, `provider_type: inline::milvus`
- **Vector data path:** `/opt/app-root/src/.llama/distributions/rh/milvus.db`,
  on the mounted 20Gi PVC, survives pod restarts
- **Metadata persistence:** `backend: kv_default`,
  `namespace: vector_io::milvus`, resolves to the PostgreSQL metadata store
- **Embedding provider:** `provider_id: sentence-transformers`,
  `provider_type: inline::sentence-transformers`
- **Embedding model:** `sentence-transformers/nomic-ai/nomic-embed-text-v1.5`,
  **768 dimensions**
- **Startup:** pod reached 1/1 in 21 seconds; embedding weights resolve from
  the image cache, no network dependency at pod start

RHOAI 2.25 registered `granite-embedding-125m` (768) and `all-MiniLM-L6-v2`
(384) instead. The embedding model is a version-dependent fact, not a
constant, read from `/v1/models` at runtime rather than hard-coded.

## Validated retrieval API behavior

The retrieval API follows OpenAI's Vector Stores convention
(`/v1/vector_stores`, `/v1/files`, `.../search`), confirmed live against
this stack, 2026-07-22/23. Two behaviors are easy to get wrong and fail
**silently** rather than with an error, worth documenting precisely for
anyone building on this:

- **Search filters must use the typed-filter shape**,
  `{"type": "eq", "key": "kind", "value": "taxonomy"}`, not a flat dict
  like `{"kind": "taxonomy"}`. The flat-dict shape does not error; it
  silently returns zero results, indistinguishable from "no matches" unless
  specifically tested against a document known to exist.
- **File listing (`GET /v1/vector_stores/{id}/files`) defaults to 20 results
  per page.** A `limit` query parameter does not expand this; it is
  silently ignored (returns zero results for `limit=250` rather than
  erroring). Real pagination is cursor-based: pass
  `after=<last_file_id_from_previous_page>` and check `has_more`. Any code
  counting or listing attached documents must paginate properly or it will
  undercount, exactly what happened during first implementation: 200
  complaint uploads all succeeded, but the completion check reported only
  20 present.
- **Population is idempotent by design**, not by accident: each document's
  `id` attribute is checked against what is already attached
  (paginated correctly) before uploading, so re-running population is safe
  and cheap on an already-populated store.

## Consequences

- **The pipeline reads its embedding and retrieval configuration at
  runtime**, not from constants. Given the embedding model changed between
  two consecutive platform versions, hard-coding it would guarantee
  breakage on the next.
- **Vector store registration happens at runtime**, via the API, not the
  CR. The pipeline creates the store on first run and reuses it thereafter.
- **This is the development posture, and the demo should say so.**
  Production is remote Milvus (with its own etcd) or pgvector, plus a
  served embedding model. Inline Milvus provides no high availability or
  horizontal scalability. `architecture.md`'s deviations table carries
  this.
- **The switch is configuration, not code.** Because the vector store sits
  behind Llama Stack's API, moving to remote Milvus or pgvector changes
  environment variables and a `provider_id` string, not pipeline logic.
  This is the substitutability the layered design was intended to buy, and
  it is demonstrable, not asserted: the same principle that makes the model
  tier swappable (see ADR-0004's review-routing discussion) applies here.
- **Both providers are opt-in from 3.4.** Anyone carrying a 2.25 Llama
  Stack configuration forward gets a silently retrieval-less stack: no
  error, just no vector_io provider and no embedding model.
- **The RAG stack is Technology Preview in RHOAI 3.4**, unlike guardrails,
  MaaS, and MLflow, which are GA. Must be stated honestly in any customer
  conversation about production timelines.

## Amendment history

- **2026-07-15:** Initial decision; inline Milvus and inline
  sentence-transformers, validated on RHOAI 3.4.2.
- **2026-07-22:** Added retrieval design (one store, `kind`-filtered
  search) and confirmed live: full 217-document corpus populated, search
  and citation working end to end.
- **2026-07-23:** Documented two silently-failing API behaviors found
  during implementation (filter syntax, file-listing pagination), so
  future work does not rediscover them the hard way.
