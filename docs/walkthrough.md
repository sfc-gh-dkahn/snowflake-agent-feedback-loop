# Walkthrough

**Experimental; clean-install and live runtime validation are pending.** This is Dylan Kahn's personal, as-is project, not an official, supported, or endorsed Snowflake project. No license has been chosen. Examples below explain contracts, not observed test results.

## Install and Check

Complete the README's account, role, warehouse, existing-agent, empty-output-schema, identifier, model-permission, and data-access checks. Substitute actual approved values privately. Install every numbered file in order: `00_setup.sql`, `01_preflight.sql`, `02_capture_context.sql`, `03_prepare_feedback.sql`, `04_diagnose.sql`, `05_recommend.sql`, `06_tasks.sql`.

These files install definitions and initial configuration/reference data only. They do not execute the pipeline. All tasks remain suspended and `AF_START` has no schedule. Do not create or clone an agent, database, or schema to follow this guide. Do not install into a populated output schema.

Under the approved role and warehouse, inspect `SHOW CORTEX BASE MODELS` and confirm the selected judge model is permitted and supports structured output. Then call `AF_PREFLIGHT()`. It performs no AI inference. It returns readability counts and a failure stage if applicable, not a diagnosis of why content is unavailable. An illustrative response is:

```json
{"ok":true,"config_readable":true,"agent_spec_readable":true,"root_traces":2,"user_message_traces":2,"answer_traces":2,"complete_traces":2,"lookback_days":14,"limits":{"lookback_days_max":90,"max_diagnoses_max":100,"max_recommendations_max":20,"min_occurrences_max":1000,"docs_cache_hours_max":720,"prior_turns_max":6},"inference_performed":false,"reason":"READABLE_EVIDENCE_FOUND"}
```

This does not prove model access, task-owner privileges, docs retrieval, or adjacent-pair coverage. Configure `docs_service` with the discovered, accessible three-part service name from the published [Snowflake Documentation CKE](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4). It requests `SOURCE_URL`, `DOCUMENT_TITLE`, `CHUNK`. The listing is free and refreshed weekly; runtime credits still apply. Default `docs_cache_hours = 168` measures retrieval age, not document publication age.

## One Bounded Proof

**Permission and token-cost gate:** do not execute either runtime path until the owner approves the existing thread, time window, readable evidence, model, and expected spend. The defaults cap new work at 20 diagnoses and 5 recommendation AI calls, not prompt bytes, tokens, or total credits. Capture, candidate hashing, cached mappings, and documentation lookups can process more rows than those caps. Use `AUTOCOMMIT = TRUE` and no open caller transaction.

Start with a known existing thread. Replace every placeholder below, including the thread and ISO timestamps. Timestamps must include `Z` or an explicit offset; the start must precede the end, the end must be at least 15 minutes old, the start must be within 90 days of now, and the interval must fit `lookback_days`. The 15-minute margin is not a telemetry-completeness guarantee.

After a separate approval for task changes, resume children and the finalizer while leaving the root suspended. Use the same approved owner role throughout. Do not use a helper that also resumes the root.

```sql
USE ROLE __ROLE__;
USE WAREHOUSE __WAREHOUSE__;
USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;
ALTER TASK AF_START SUSPEND;
ALTER TASK AF_CAPTURE RESUME;
ALTER TASK AF_PREPARE RESUME;
ALTER TASK AF_DIAGNOSE RESUME;
ALTER TASK AF_RECOMMEND RESUME;
ALTER TASK AF_FINISH RESUME;
ALTER TASK AF_FINALIZE RESUME;
EXECUTE TASK AF_START USING CONFIG = $${
  "window_start": "__ISO_START_WITH_OFFSET__",
  "window_end": "__ISO_END_WITH_OFFSET__",
  "thread_filter": "__EXISTING_THREAD_ID__"
}$$;
```

`EXECUTE TASK` requests a one-off run of the suspended root; it does not enable a schedule. Children must be resumed to participate. The task accepts only `window_start`, `window_end`, and `thread_filter`; row limits live in `AF_CONFIG`, not task `CONFIG`. The graph uses its runtime group ID as `run_id` and passes it through predecessor return values. Wait for the graph and finalizer to settle before another run or any configuration change.

### Manual Alternative

The same permission and token warning applies. Keep `AF_START` suspended, confirm no graph is running, and serialize calls. `AF_RUN` calls the stages synchronously; it does not require resumed child tasks and returns a new run UUID, not a success grade.

```sql
CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN(
    NULL, NULL, '__EXISTING_THREAD_ID__');
```

With both timestamps `NULL`, the start is now minus `lookback_days` and the end is now minus 15 minutes. Explicit windows are preferable for a narrow proof. Only after approving the broader scope:

```sql
CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN(NULL, NULL, NULL);
```

The last `NULL` removes the thread filter. It does not create feedback pairs for unthreaded events or remove the candidate cap.

## One Synthetic Scenario

This is a small paper example, not fixture data to load into runtime tables. It creates no agent and seeds no telemetry. Assume both turns belong to the same existing agent and synthetic thread `thread-demo-01` and have readable root responses and user messages.

| Turn / trace | User message | Agent answer |
| --- | --- | --- |
| 1 / `trace-demo-01` | Show the totals as a table. | The totals are 12 and 9. |
| 2 / `trace-demo-02` | Please use a table, as I asked. | Here is a table with totals 12 and 9. |

| Stage | Input | Persisted output or result |
| --- | --- | --- |
| Start | Approved window and `thread-demo-01` | `AF_RUNS`: UUID, `RUNNING`, stage `START` |
| Capture | Current agent specification and bounded observability spans | Deduplicated `AF_EVENTS`; one `AF_CONFIG_SNAPSHOTS` row for the run |
| Prepare | Archived complete adjacent turns | `AF_RUN_FEEDBACK`: response `trace-demo-01`, feedback `trace-demo-02`, prior turns and current config |
| Diagnose | Prepared evidence, current captured config, model/revision | `AF_DIAGNOSES`: structured output and validation status; surfaced in `AF_FINDINGS` |
| Recommend | Valid poor diagnoses grouped by supported surface, good counterevidence, current config, official docs | Eligible groups yield `AF_RECOMMENDATIONS` and `AF_RUN_RECOMMENDATIONS` mappings |
| Finish | Persisted results, omissions, errors, and sampling counts | `AF_RUNS`: `COMPLETE` or `PARTIAL`; reviewable projections in `AF_REVIEW_QUEUE` |

Preparation uses the next turn's **user message** as a proxy for feedback on the previous answer. The feedback turn must also have a readable answer. It retains up to six complete prior turns within the six preceding turn positions, including the answer under review. It does not skip an incomplete intervening turn to pair distant answers. It can use earlier archived context outside the selected window; the window selects the feedback turn's timestamp.

The first answer is eligible because turn 2 follows it. Turn 2's answer has no later follow-up, so its quality remains unknown. Null, empty, or `'0'` threads are not paired. A repeated request, thank-you, or new requirement is not automatically a complaint or proof of success. Ratings and explicit comments are **extension ideas only**: current capture and pairing do not ingest them. An extension would need its own source contract, provenance, response linkage, and tests rather than silently treating a comment as the next turn.

The agent specification is current **at capture time**, not necessarily when either turn ran. Preparation labels this `CAPTURE_TIME_ONLY; INVOCATION_VERSION_UNKNOWN`. Do not infer historical noncompliance from that snapshot.

### Diagnosis Contract

An illustrative diagnosis uses the exact response keys:

```json
{
  "assessment": "poor",
  "issue_type": "agent_behavior",
  "severity": "low",
  "surface": "instructions.response",
  "observation": "The first answer did not use the requested table format.",
  "evidence_quote": "Please use a table, as I asked.",
  "suspected_cause": "unknown",
  "preserve_behavior": "The follow-up answer supplied the requested format; factual accuracy is not established.",
  "requires_review": true
}
```

The structured response schema rejects additional root keys. Validation checks required types/enums and that the quote occurs verbatim in a supplied user or agent message. The prompt asks for `requires_review = true`; the validator checks its boolean type, not that it is true. Valid structure is not proof of a correct assessment. Outcomes include `valid`, `invalid_output`, and `ai_error`. Every persisted diagnosis ID is skipped by inference, including errors. Stored results and their timestamps are immutable; a deliberate retry of unchanged inputs requires a new `prompt_revision` and approval for new AI cost.

### Recommendation Contract

At default `min_occurrences = 2`, this single low-severity poor response does **not** qualify for a recommendation. That is an expected no-proposal outcome, not an installation failure. Groups count distinct response traces within the prepared run; one severe observation can bypass the occurrence threshold. Grouping by agent and surface does not prove a shared cause.

For an explicitly approved paper variation with `min_occurrences = 1`, the same evidence could reach recommendation review. Change configuration only between runs. If usable official passages exist but the model judges the evidence too weak, this is a valid exact-key response example, not a promised result:

```json
{
  "recommendation_warranted": false,
  "headline": "No instruction change established",
  "reasoning": "One formatting follow-up does not establish a recurring configuration defect.",
  "suggested_change": "",
  "change_mode": "none",
  "displaced_text": "",
  "preserve_behavior": "Keep the ability to adapt the answer format in a follow-up.",
  "would_regress_good_behavior": false,
  "confidence": "low",
  "citations": []
}
```

Warranted technical proposals need 1-5 citation objects with exactly `url`, `quote`, and `supports`. The URL must match a supplied official passage and the quote must occur in its chunk. No fabricated documentation quote is supplied here. A human must decide whether the quoted text actually supports the claim. `replace` additionally requires `displaced_text` to occur in current same-surface instructions; other modes require empty displaced text. Data surfaces and reported gaps permit `investigate` only, not assertions of missing tables, records, or permissions.

Usable docs are a prerequisite for recommendation inference. Missing docs leave an eligible group `needs_review` without actionable advice; findings remain. Other review statuses include `ready_for_review`, `not_warranted`, `invalid_output`, and `ai_error`. None authorizes applying a change. Retrieval takes up to five passages, truncating titles to 300 characters and chunks to 1,500. Recommendation prompts sample up to ten poor examples per surface and ten good examples across the agent in that run; full evidence hashes still track the grouped inputs.

The stage processes every eligible group across the eight supported surfaces, retrieves docs, and reuses any stored inference result before enforcing `max_recommendations` on new AI calls. This includes terminal `ai_error` and `invalid_output` results. A docs-ready group beyond the cap is still mapped: `review_status = 'needs_review'`, `docs_status = 'inference_limit'`, error `Inference limit reached`, and no AI call. Its identity was computed from the retrieved docs before setting the limit status. Later approved runs can fill this no-inference placeholder under the same identity. Only no-inference placeholders can be updated; documentation failures can instead get a new ID when docs change. Prior actual inference is never overwritten.

## Coverage and Review

Use these dashboard sources in your existing query or BI tool; the repository includes no app:

| Source | Review focus |
| --- | --- |
| `AF_FINDINGS` | Observations, suspected causes, preserved behavior, validation and pending diagnoses |
| `AF_REVIEW_QUEUE` | Run-linked proposals, citations, docs status, review status |
| `AF_RUNS` | Window/filter, stage, errors, `diagnostics` and processing coverage |

Keep raw events, evidence, snapshots, model output, error details, and dashboard views restricted. Neither a prompt that forbids disclosure nor a view that drops raw columns guarantees sanitization. AI summaries can repeat sensitive text.

Inspect `diagnostics:prepare` for all window `candidate_pairs`, mapped `cached_pairs`, selected unseen `new_pairs`, total `prepared_pairs`, and delayed `pairs_over_limit`. All cached IDs are mapped; only unseen pairs compete for `max_diagnoses`, ordered newest first with stable trace ties. Candidate IDs use ordered prior-turn hashes before full evidence assembly. Saved evidence is reused where available; selected pairs without saved evidence reconstruct it. Prepared rows may exceed the cap because cached rows do not spend it. With unchanged inputs and serialized runs, later runs can select older unseen work. New arrivals, changed hashes, shrinking windows, and missing archived context still limit coverage. Verify with bounded backfills; clean-install and runtime proof remain pending.

`AF_FINISH` records `PARTIAL` for omitted pairs/groups, sampled recommendation evidence, missing docs, pending results, invalid outputs, or errors. Review its `finish` diagnostics rather than relying on task success alone. `COMPLETE` is a processing status, not an accuracy score; a zero-pair run can be `COMPLETE`. `AF_FINALIZE` marks unfinished graph runs failed. Failures before a run row is created require restricted task history inspection.

## Retry and Schedule

There are no automatic task retries. Keep the root suspended and serialize manual calls, task executions, and delivery. `NO_OVERLAP` does not coordinate direct procedure calls. The active-run check precedes insertion and is not an atomic lock. A crash after inference but before persistence can cause repeat billing; do not promise exactly-once processing.

After a failure, inspect the recorded stage and restricted task/query history, resolve the cause, and start a new approved run. Do not blindly edit run state or reuse a run UUID. Reconcile an abandoned `RUNNING` row only after confirming no work remains active. Keep configuration unchanged during a run. Starting another run alone does not retry persisted inference errors. For a deliberate retry of unchanged inputs, bump `prompt_revision`; new identities can incur new charges while preserving old results. Changed evidence, configuration, or model can also produce new diagnosis IDs. Configuration includes limits and cache settings: changing them intentionally changes the capture hash and can rejudge conversations, not merely increase throughput. Bump `prompt_revision` when diagnosis prompt logic changes because its text is not itself in the diagnosis key. Recommendation reuse also tracks prompt/schema, evidence, counterevidence, snapshot, and documentation hashes.

Only after clean-install proof, task-owner checks, cost review, and demonstrated coverage, consider an optional weekly schedule with separate approval. This example means Mondays at 09:00 UTC; choose the actual desired time before using it. Resume the children/finalizer first, clear any retained one-thread config, and resume the root last:

```sql
ALTER TASK AF_START SUSPEND;
ALTER TASK AF_START SET CONFIG = '{}';
ALTER TASK AF_START SET SCHEDULE = 'USING CRON 0 9 * * MON UTC';
ALTER TASK AF_START RESUME;
```

Scheduling does not guarantee coverage: unseen arrivals can outpace the caps, rolling windows can drop older work, and recommendation evidence remains sampled. Suspend `AF_START` before graph changes or manual runs and wait for active work to finish; suspension alone does not cancel an in-flight run.

## Optional Email

After separate approval, install `optional/email.sql`. It creates `AF_DELIVERY` and `AF_SEND_EMAIL(P_RUN_ID, P_INTEGRATION, P_RECIPIENT)` only, not an integration, task, schedule, or dbt hook. Use an existing approved email integration and one approved recipient. Preview the exact eligible summaries before approving a send; the body includes the agent's qualified name, surface, review/docs statuses, and bounded AI-generated summary text. It is not a full health report or guaranteed sanitized text.

Only completed `COMPLETE`/`PARTIAL` runs qualify, and only `ready_for_review`/`needs_review` summaries are included. No eligible rows returns `NO_REVIEW_SUMMARIES`. The ledger suppresses matching payload/integration/recipient delivery IDs across runs, but claims are not an atomic concurrency lock. Serialize calls. `UNCERTAIN_DO_NOT_RESEND` means delivery may have occurred; reconcile manually. `SENT` records acknowledgment, not proof the recipient read or received it. Never delete a claim to force a blind resend.