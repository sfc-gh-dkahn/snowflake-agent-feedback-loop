# Walkthrough

This guide runs one small review against an existing Cortex Agent. It does not create or change the agent.

The Cortex Code path is: clone, discover values, render, review, install, preflight, run one thread, then review the result.

## 1. Render

Follow the renderer command in `README.md`. It writes configured files under `local/render` and prints the install commands in `local/render/PLAN.txt`.

For Snow CLI, use the generated files:

- `sql/06_tasks.cli.sql` for task DDL.
- `tests/fixture_pair.cli.sql` for the SQL test pair.

The plain `sql/06_tasks.sql` is for Snowsight. Snow CLI can split the semicolons inside a task's Snowflake Scripting body. The generated CLI file wraps each task in `EXECUTE IMMEDIATE` so the body stays whole.

## 2. Install and Check

Use the approved role and warehouse. Install files `00` through `05`, then install the generated `06_tasks.cli.sql`. The tasks remain suspended.

Confirm the model is allowed and supports structured output:

```sql
SHOW CORTEX BASE MODELS;
```

Set `AF_CONFIG.docs_service` to the accessible three-part service name from the [Snowflake Documentation CKE](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4). The service must return `SOURCE_URL`, `DOCUMENT_TITLE`, and `CHUNK`.

Run preflight:

```sql
CALL OUTPUT_DB.AGENT_FEEDBACK.AF_PREFLIGHT();
```

Require `ok = true`. Preflight reads recent observability events and the agent specification. It calls no AI.

## 3. Run One Thread

Choose a known thread and explicit timestamps with `Z` or an offset. The end must be at least 15 minutes old. The window must fit `lookback_days` and cannot exceed 90 days.

Review the evidence scope, model, and likely AI cost before running.

Resume child tasks and the finalizer. Leave the root suspended:

```sql
USE ROLE AGENT_REVIEWER;
USE WAREHOUSE AGENT_WH;
USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

ALTER TASK AF_START SUSPEND;
ALTER TASK AF_CAPTURE RESUME;
ALTER TASK AF_PREPARE RESUME;
ALTER TASK AF_DIAGNOSE RESUME;
ALTER TASK AF_RECOMMEND RESUME;
ALTER TASK AF_FINISH RESUME;
ALTER TASK AF_FINALIZE RESUME;

EXECUTE TASK AF_START USING CONFIG = $${
  "window_start": "2026-09-01T10:00:00Z",
  "window_end": "2026-09-01T11:00:00Z",
  "thread_filter": "YOUR_THREAD_ID"
}$$;
```

This requests one run. It does not add a schedule. Task `CONFIG` accepts only `window_start`, `window_end`, and `thread_filter`.

Wait for the graph and finalizer before another run or configuration change.

## Manual Run

`AF_RUN` calls each stage in one session and does not need resumed child tasks:

```sql
CALL OUTPUT_DB.AGENT_FEEDBACK.AF_RUN(
    '2026-09-01T10:00:00Z'::TIMESTAMP_LTZ,
    '2026-09-01T11:00:00Z'::TIMESTAMP_LTZ,
    'YOUR_THREAD_ID');
```

Keep `AF_START` suspended and confirm no graph run is active. Do not run the manual and task paths at the same time.

Using `NULL` timestamps selects the configured lookback ending 15 minutes ago. A `NULL` thread filter reviews all eligible threads in the window. Use those broader settings only after the one-thread run works.

## 4. Read the Result

```sql
SELECT * FROM AF_RUNS ORDER BY started_at DESC LIMIT 10;
SELECT * FROM AF_FINDINGS ORDER BY feedback_ts DESC LIMIT 100;
SELECT * FROM AF_REVIEW_QUEUE ORDER BY created_at DESC LIMIT 100;
```

Check `AF_RUNS.diagnostics`:

- `prepare.candidate_pairs`: all eligible pairs in the window.
- `prepare.cached_pairs`: pairs mapped to stored diagnoses.
- `prepare.new_pairs`: unseen pairs selected for this run.
- `prepare.pairs_over_limit`: unseen pairs delayed by `max_diagnoses`.
- `diagnose`: attempted, invalid, and failed diagnosis calls.
- `recommend`: selected groups, docs state, AI calls, reuse, and errors.
- `finish`: pending, invalid, sampled, missing-docs, and omitted counts.

`COMPLETE` means selected processing finished. `PARTIAL` means some work was delayed, sampled, missing docs, invalid, or failed.

## What the Stages Mean

Preparation pairs an answer with the next complete user turn in the same thread. It does not skip an incomplete turn to join distant answers. The last answer in a thread has no later feedback proxy.

A diagnosis is a review hypothesis. Validation checks its JSON shape and confirms that `evidence_quote` appears in supplied text. It does not prove the assessment.

Recommendations need poor evidence that meets `min_occurrences`, one severe finding, or repeated evidence in one thread. They also need usable official docs. The model receives bounded samples of poor, good, and repeated evidence.

Technical citations must use a supplied Snowflake docs URL and an exact quote from its chunk. A person must still check that the quote supports the suggestion.

Reported data gaps can produce investigation steps only. They cannot confirm that a table, record, dataset, or permission is missing.

## Retry

After a failure, inspect `AF_RUNS.stage`, `error_message`, and restricted task or query history. Fix the cause and start a new run.

Stored AI errors and invalid outputs are reused for the same identity. To retry unchanged evidence, change `prompt_revision` between runs. That creates new AI work and can add cost.

Do not edit a `RUNNING` row until you have confirmed that no work is active. The run guard is not an atomic cross-session lock.

## Optional Schedule

Add a schedule only after the bounded run, task-owner checks, and coverage review succeed. Resume the root last:

```sql
ALTER TASK AF_START SUSPEND;
ALTER TASK AF_START SET CONFIG = '{}';
ALTER TASK AF_START SET SCHEDULE = 'USING CRON 0 9 * * MON UTC';
ALTER TASK AF_START RESUME;
```

This example runs Mondays at 09:00 UTC. Change it to the approved time.

## Optional Email

`optional/email.sql` creates a delivery table and `AF_SEND_EMAIL`. It needs an existing email integration and one recipient. It creates no integration or schedule.

Preview `AF_REVIEW_QUEUE` before sending. Calls must be serialized. An `UNCERTAIN_DO_NOT_RESEND` result means delivery may have happened; check before any retry.