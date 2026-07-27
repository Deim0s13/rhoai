# Deployment log: 2026-07-24 (vector store restart race)

Found while re-validating the ADR-0004 review-routing fix (comparing the
model's actual chosen theme rather than a blind top-2, see
pipeline/classify.py and DEPLOYMENT-LOG-2026-07-22). A full batch
classification returned `Routed to review: 0/200`, plausible-looking but
wrong. Root cause turned out to be a genuinely new finding, unrelated to
the routing logic itself: a Llama Stack restart left the vector store's
search index unreachable while its file listings kept working normally,
masking the real cause behind what looked like the routing fix simply not
firing.

---

## Status at end of session

| Layer                                           | Status                                                                                   |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `taxonomy_theme_ambiguity()` routing fix        | Working, confirmed via fresh rebuild 2026-07-26                                          |
| Vector store search after a Llama Stack restart | BROKEN if the store already has data at restart time; workaround documented (REBUILD.md) |
| `seed_pipeline_code` ConfigMap task             | Fixed (see finding 2)                                                                    |

---

## Findings

### 1. A Llama Stack restart can silently break vector search while leaving file operations working

**Expected:** per ADR-0008's own validated notes, Milvus's vector data
lives on the mounted PVC and survives pod restarts.

**Happened:** after `ansible-playbook ansible/site.yml` was re-run
(specifically to refresh the `pipeline-code` ConfigMap, see finding 2)
against an environment where the vector store already existed and was
populated, `sync_llama_stack` restarted the Llama Stack pod as designed.
After the restart:

- `GET /v1/vector_stores/{id}/files` continued to work normally, correctly
  listing all 217 attached documents (17 taxonomy, 200 complaints).
- `POST /v1/vector_stores/{id}/search` returned `200` with an empty
  `data: []`, on every query, including a freshly-uploaded diagnostic
  document added _after_ the restart, ruling out "old embeddings lost,"
  since a document that never existed before the restart also could not
  be found.
- The pod's own logs showed the real error, not surfaced to the API
  caller at all:

```
  VectorStoreNotFoundError: Vector Store 'vs_...' not found. Use
  'client.vector_dbs.list()' to list available Vector Stores.
```

thrown from Milvus's provider code
(`_get_and_cache_vector_store_index`), which looks up a `kvstore` entry
keyed by `VECTOR_DBS_PREFIX + vector_store_id` separately from
whatever backs file listing.

**Diagnosis:** file attachments and the store's searchable index are
evidently tracked through two different registration paths. One survived
the restart; the other did not. This looks like the store's registration
write had not durably persisted before the restart landed, the same
underlying shape as two earlier findings this build (the `model_fetch`
predictor race, DEPLOYMENT-LOG-2026-07-22 finding 1; Llama Stack's
model-discovery-at-startup-only behavior, finding 2 in the same log), a
restart landing in the middle of something that needed to finish first.
This is the third distinct instance of that pattern, on a different
component each time.

**Not currently guarded against**, unlike the two earlier instances of
this pattern, which now have automated fixes (`model_fetch`'s
readiness check, `sync_llama_stack`'s wait-then-restart sequencing). No
equivalent guard exists for the vector store surviving an
already-populated-then-restarted sequence. See REBUILD.md's "Do not"
section for the manual workaround (delete and recreate the store) and the
safe ordering (the playbook must complete fully before the notebook ever
creates the store; the race is specific to re-running the playbook
_after_ the store already has data).

**Not yet built:** an automated guard equivalent to the other two. Would
need a readiness check confirming the vector store's search actually
returns results for a known document, not just that file listing works,
before treating any post-restart state as healthy. Worth doing if this
recurs, not urgent given the documented manual workaround and the safe
default ordering.

### 2. `seed_pipeline_code`'s original implementation had a shell-injection bug

**Expected:** applying the `pipeline-code` ConfigMap would work the same
way `seed_taxonomy` already does, `oc create --dry-run=client -o yaml`
piped directly into `oc apply -f -`, no file content ever touching a
shell-interpreted string.

**Happened:** the role was written with two separate tasks instead:
render the manifest via `--dry-run`, `register` the output, then a
second task `echo`'d that captured string into `oc apply`. `taxonomy.yaml`
survives this pattern because YAML rarely contains shell metacharacters.
Python source code does: `pipeline/classify.py`'s docstrings and
parenthesised comments (e.g. `(ADR-0009)`) contain unescaped quotes and
parentheses. The first such character closed the shell's outer quoting
early, and the remainder of the file's content was interpreted as shell
commands, not echoed text, producing errors like:

```
  /bin/sh: line 4: pipeline/classify.py: No such file or directory
  /bin/sh: -c: line 6: syntax error near unexpected token `('
```

**Fix:** rewrote as a single task, matching `seed_taxonomy`'s existing
(and always-correct) pattern exactly, `oc create --dry-run=client -o yaml
| oc apply -f -` in one piped command, so `oc` reads the files directly
off disk and the shell never sees their content at all.

**Implication:** the two-task register/echo pattern should not be reused
elsewhere in this repo. Any future role delivering file content via a
ConfigMap should follow `seed_taxonomy`'s single-piped-command form
directly, not be written fresh from a mental model of "how ConfigMaps
work" that doesn't account for what's actually inside the file being
delivered.

---

## Resume point for next session

- Both fixes validated on a genuinely fresh rebuild, 2026-07-26 (see chat):
  `Routed to review: 71/200`, matching the prior-verified `70/200`, and
  `review_reason` now consistently names the same theme as the row's own
  `theme_id`, confirmed directly in the deployed app's review queue.
- Minor wording cleanup applied to `review_reason`'s phrasing ("chosen
  theme X is close to the next-best match Y" rather than "top two
  taxonomy matches"), cosmetic only, not yet re-validated on a fresh
  rebuild as of this entry; low risk, will be confirmed on the next one.
- No automated guard yet for finding 1 (unlike findings 1 and 2 in
  DEPLOYMENT-LOG-2026-07-22, which both got automated fixes). Worth
  revisiting if the manual workaround needs to fire more than
  occasionally.
