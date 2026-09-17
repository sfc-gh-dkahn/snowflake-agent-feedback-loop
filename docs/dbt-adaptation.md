# dbt Adaptation

**Design only.** This repository does not include or test a dbt project. The SQL install does not require dbt.

The useful boundary is simple: save AI results once for a specific set of inputs, then let dbt transform those stored results. Do not put inference in dashboard views or make ordinary analytical queries call the model again.

## Proposed Mapping

These are possible mappings. This repository does not supply them.

| Current contract | Possible dbt responsibility |
| --- | --- |
| `AF_CONFIG`, `AF_SUPPORTED_AREAS` | Approved configuration and supported-surface reference inputs; exactly one agent/config row per output schema |
| `AF_EVENTS`, `AF_CONFIG_SNAPSHOTS` | Restricted, persisted source tables populated by an explicitly approved capture process |
| `AF_TURNS`, `AF_FEEDBACK_PAIRS` | Deterministic relational models for complete turns and adjacent same-thread pairs |
| `AF_RUN_FEEDBACK` | Persisted run-scoped evidence with stable IDs, configuration hash, model, and prompt revision |
| `AF_DIAGNOSES` | Incremental persisted inference results, selected through an anti-join against reusable IDs |
| `AF_DOC_CACHE` | Persisted official search passages with retrieval time, query hash, and content hash |
| `AF_RECOMMENDATIONS`, `AF_RUN_RECOMMENDATIONS` | Incremental persisted proposals plus a run-to-result mapping for reused records |
| `AF_FINDINGS`, `AF_REVIEW_QUEUE`, `AF_RUNS` | Analytical models for findings, review workflow, run health, and coverage |

Preserve the existing-agent-only scope. Use the approved output database/schema and explicit role/warehouse. Do not use a dbt adaptation as a reason to create or clone an agent, copy its source data, or repoint a populated output schema.

## Incremental AI Boundary

1. Capture evidence and the current agent specification before building candidate inputs. Do not present the snapshot as the configuration used by an earlier call.
2. Construct deterministic evidence IDs. The current diagnosis identity includes agent/thread and trace identities, turn/context hashes, config hash, model, and prompt revision. A model or evidence change should not silently reuse an old result.
3. Anti-join candidates to every persisted diagnosis ID before approved inference, including `valid`, `invalid_output`, and `ai_error`. Preserve immutable inference results. Retrying unchanged inputs requires an explicit new `prompt_revision`, creates a new identity, and can incur new charges; it must not overwrite the old result.
4. Materialize model output, validation status, error metadata, and result identity in an incremental table. A configured dbt `unique_key` or merge strategy is not an enforced unique constraint or cross-session lock. Serialize writers and test uniqueness.
5. Build downstream recommendation inputs from persisted valid diagnoses and successful counterevidence. Track hashes for evidence, counterevidence, snapshot, model, prompt/schema revision, documentation service/query/content, and selection policy. Preserve run-to-result mappings when reusing recommendations.
6. Serve dashboards from persisted outputs. Keep raw evidence and AI text restricted; downstream projections do not automatically sanitize it.

An incremental materialization is not a guarantee that AI runs exactly once. A failed build, full refresh, changed key, concurrent writer, or crash between inference and persistence can repeat paid calls. Keep inference in a separately approved execution step with explicit limits and durable result writes. Do not assume a CTE or view persists model results.

## Bounded New Work

`AF_PREPARE_FEEDBACK` computes candidate IDs from ordered turn/context hashes across the window, maps every cached diagnosis, and caps only newest unseen pairs at `max_diagnoses`. It reuses saved evidence where available and assembles full context only for selected pairs without it. Candidate hashing and cached mappings are not bounded by this AI cap.

Preserve the separate candidate, cached, new, prepared, attempted, and delayed counts. Test that later serialized runs advance through unchanged unseen inputs; the source logic is not runtime proof. Keep enough archived context for pairing across window boundaries. New arrivals and changed identities can still delay older work. Configuration changes, including limits and cache settings, intentionally affect the capture hash and can rejudge existing conversations.

Recommendations process all eligible groups across the eight supported surfaces, check docs and reuse first, then cap new AI calls. Map deferred groups as `needs_review` with `docs_status = 'inference_limit'` and error `Inference limit reached`. Keep the pre-limit docs-based identity stable so later runs can fill no-inference placeholders. Documentation failures remain retryable and can change identity as docs change. Actual recommendation inference, including errors and invalid outputs, stays immutable. Preserve `PARTIAL` for delayed work, sampled recommendation evidence, missing docs, pending results, invalid output, and errors. `COMPLETE` remains a processing status, not full conversation coverage or agent quality.

## Documentation and Validation

Keep the live Snowflake Documentation CKE contract: `SOURCE_URL`, `DOCUMENT_TITLE`, `CHUNK`, from the actual approved service associated with the [published listing](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4). Use generic supported-surface queries, not raw conversation text, for retrieval. The free, weekly-refreshed listing does not remove runtime credit costs. TTL governs cache retrieval age, not publication freshness.

Missing usable official passages must leave findings visible but block actionable documentation-backed fixes. Preserve verbatim evidence checks, exact supplied citation URL/quote checks, same-surface replacement validation, and investigation-only treatment of reported data gaps. These checks do not establish factual truth or sanitize model text. Keep human review before any agent change.

Validation work should cover:

- Unique event/result IDs and valid run mappings, including repeated and overlapping capture windows.
- Adjacent same-thread pairing, missing/redacted text, unthreaded events, and the final answer with no follow-up.
- Deterministic keys, late-arriving evidence, prompt revisions, model changes, and docs content/TTL changes.
- Cache reuse, retryable no-inference placeholders, immutable inference errors/invalid outputs, and backlog advancement under a bounded budget.
- Supported surfaces, output enums/types, evidence quotes, citations, replacement scope, and preserved good behavior.
- Run-level omission/error accounting and restricted dashboard exposure, including empty runs.

The offline tests check source contracts, not Snowflake compilation or live behavior. Keep fixtures synthetic and separate from runtime agent capture. Test a dbt version in an approved disposable environment before use.

Do not add an email post-hook or send mail during dbt builds. Optional delivery remains a separate, human-approved operation using an existing integration and a serialized delivery ledger. Start with manual builds; scheduling requires its own approval after validation and cost/coverage review.