-- AGENT FEEDBACK LOOP: Inspect saved evidence, pending work and results
-- Customize OUTPUT_DB and AGENT_FEEDBACK. Read-only except session USE statements.
-- First run, in order: 00_setup.sql -> 01_preflight.sql -> 02_capture_context.sql
--   -> 03_prepare_feedback.sql -> 04_diagnose.sql -> 05_retrieve_documentation.sql
--   -> 06_recommendations.sql -> 07_inspect_results.sql.
-- Recurring: check settings/preflight, capture with 02, then 03 (recreate views
-- only if definitions changed), 04, manually refresh docs with 05 as needed,
-- then 06 and 07. Require fresh, ready exact-query docs before 06; a full 05
-- run makes eight paid searches. Never proceed using old docs after a failed refresh.
-- 02 reads the REVIEW_SETTINGS UTC window; thread_filter narrows reviews, not capture.
-- 04 is not optional: it saves new reviews. Recreate its views when definitions
-- change, and rerun 04 for a changed prompt_revision before running 06.
-- Keep every statement within 04 in one session, and likewise within 06, because
-- each uses temporary batches. Run sequentially, with no concurrent writers,
-- capture, settings edits or docs refresh. Abort on any failure; resolve it first.
-- This is not a scheduler or run ledger. No automatic COMPLETE status, error
-- handling, cross-statement rollback or exactly-once guarantee. Retries can cost again.
-- Counts are current reads, not a record of which statements finished. Empty does
-- not mean healthy: absent traffic, unpairable turns, guards and failures differ.
-- Follow-ups are proxies, not ratings. Capture-time settings are not historical
-- proof. Reported data gaps need investigation; all proposals need human approval.
-- Evidence and raw errors can contain sensitive text. These reads do not sanitize it.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- 1. Both aggregate status views return one row even with no settings/areas/groups.
SELECT * FROM ANSWER_REVIEW_SETTINGS_STATUS CROSS JOIN CHANGE_AREAS_STATUS;
SELECT * FROM REVIEW_SETTINGS;

-- 2. FULL SAVED HISTORY, not the selected window. Incomplete turns are separate.
-- Complete unpaired turns stay unjudged by the current pairing, including missing
-- threads, final turns and incomplete adjacent follow-ups. Not a quality verdict.
SELECT (SELECT COUNT(*) FROM AGENT_EVENTS) AS captured_events_all_history,
       (SELECT COUNT(*) FROM AGENT_SETTINGS_HISTORY) AS snapshots_all_history,
       (SELECT COUNT(*) FROM CONVERSATION_TURNS) AS turns_all_history,
       (SELECT COUNT(*) FROM CONVERSATION_TURNS WHERE is_complete) AS complete_turns_all_history,
       (SELECT COUNT(*) FROM CONVERSATION_TURNS WHERE NOT is_complete) AS incomplete_turns_all_history,
       (SELECT COUNT(*) FROM ANSWER_FOLLOWUP_PAIRS) AS pairs_all_history,
       (SELECT COUNT(*) FROM CONVERSATION_TURNS AS turns
        WHERE turns.is_complete AND NOT EXISTS (
            SELECT 1 FROM ANSWER_FOLLOWUP_PAIRS AS pairs
            WHERE pairs.agent_database = turns.agent_database
              AND pairs.agent_schema = turns.agent_schema AND pairs.agent_name = turns.agent_name
              AND pairs.response_trace_id = turns.trace_id)) AS complete_unpaired_turns_all_history,
       (SELECT COUNT(*) FROM CURRENT_AGENT_SETTINGS WHERE NOT specification_is_valid) AS invalid_current_specs;

-- 3. Selected pairs use FOLLOW-UP time (UTC start inclusive/end exclusive) + thread.
-- Counts are NULL for invalid settings, not a misleading zero-work verdict.
WITH selected_pairs AS (
    SELECT pairs.* FROM ANSWER_FOLLOWUP_PAIRS AS pairs
    CROSS JOIN REVIEW_SETTINGS AS settings CROSS JOIN ANSWER_REVIEW_SETTINGS_STATUS AS checks
    WHERE checks.settings_are_valid
      AND pairs.feedback_time_utc >= settings.review_start AND pairs.feedback_time_utc < settings.review_end
      AND (settings.thread_filter IS NULL OR pairs.thread_id = TRIM(settings.thread_filter, ' \t\r\n'))
), coverage AS (
    SELECT COUNT(*) AS pairs_in_window,
           COALESCE(COUNT_IF(config.snapshot_id IS NULL), 0) AS pairs_missing_snapshot,
           COALESCE(COUNT_IF(NOT config.specification_is_valid), 0) AS pairs_invalid_snapshot
    FROM selected_pairs AS pairs LEFT JOIN CURRENT_AGENT_SETTINGS AS config
      USING (agent_database, agent_schema, agent_name)
)
SELECT checks.settings_status,
       IFF(checks.settings_are_valid, coverage.pairs_in_window, NULL) AS pairs_in_selected_window,
       IFF(checks.settings_are_valid, coverage.pairs_missing_snapshot, NULL) AS pairs_missing_snapshot,
       IFF(checks.settings_are_valid, coverage.pairs_invalid_snapshot, NULL) AS pairs_invalid_snapshot,
       IFF(checks.settings_are_valid, (SELECT COUNT(*) FROM REVIEW_CANDIDATES), NULL) AS unsaved_reviews_now,
       IFF(checks.settings_are_valid, (SELECT COUNT(*) FROM REVIEW_CANDIDATES
           WHERE is_within_budget), NULL) AS unsaved_reviews_in_budget_now,
       IFF(checks.settings_are_valid, (SELECT COUNT(*) FROM REVIEW_CANDIDATES
           WHERE NOT is_within_budget), NULL) AS deferred_reviews_now
FROM ANSWER_REVIEW_SETTINGS_STATUS AS checks CROSS JOIN coverage;

-- 4. All saved history. Raw counts include results missing inputs; views may not.
SELECT COUNT(*) AS raw_review_rows_all_history,
       COALESCE(COUNT_IF(model_response:error IS NOT NULL
           AND NOT IS_NULL_VALUE(model_response:error)), 0) AS raw_error_rows,
       COALESCE(COUNT_IF(NOT COALESCE(IS_OBJECT(model_response), FALSE)), 0) AS nonobject_envelopes
FROM ANSWER_REVIEWS;
SELECT COUNT(*) AS raw_reviews_missing_input_all_history FROM ANSWER_REVIEWS AS saved
WHERE NOT EXISTS (SELECT 1 FROM ANSWER_REVIEW_INPUTS AS inputs WHERE inputs.review_id = saved.review_id);
SELECT COUNT(*) AS finding_rows_all_history,
       COALESCE(COUNT_IF(validation_status = 'valid'), 0) AS valid_rows,
       COALESCE(COUNT_IF(validation_status = 'invalid_output'), 0) AS invalid_output_rows,
       COALESCE(COUNT_IF(validation_status = 'ai_error'), 0) AS ai_error_rows
FROM REVIEW_FINDINGS;
SELECT review_id, reviewed_at, model_response:error AS raw_error
FROM ANSWER_REVIEWS
WHERE model_response:error IS NOT NULL AND NOT IS_NULL_VALUE(model_response:error)
ORDER BY reviewed_at DESC, review_id LIMIT 20;

-- Saved-input gaps across ALL history are not necessarily eligible for a call now.
SELECT 'answer_review' AS input_kind, COUNT(*) AS saved_input_rows_missing_result_all_history
FROM ANSWER_REVIEW_INPUTS AS inputs
WHERE NOT EXISTS (SELECT 1 FROM ANSWER_REVIEWS AS saved WHERE saved.review_id = inputs.review_id)
UNION ALL
SELECT 'recommendation', COUNT(*) FROM RECOMMENDATION_INPUTS AS inputs
WHERE NOT EXISTS (SELECT 1 FROM RECOMMENDATIONS AS saved WHERE saved.recommendation_id = inputs.recommendation_id);

-- 5. Current queue: missing/bad/stale docs, insufficient evidence, deferred, waiting,
-- saved failures, suppressed and human-review states remain distinct. Sentinel is
-- NOT a group: COUNT(group_id) excludes it; invalid_settings remains visible.
SELECT queue_status, COUNT(*) AS queue_rows, COUNT(group_id) AS current_groups
FROM REVIEW_QUEUE GROUP BY queue_status ORDER BY queue_status;
SELECT agent_database, agent_schema, agent_name, surface, queue_status,
       recommendation_id, documentation_status, docs_captured_at, validation_note
FROM REVIEW_QUEUE ORDER BY queue_status, agent_database, agent_schema, agent_name, surface;

-- History is not the current queue. This view selects one saved result per ID;
-- raw duplicates survive in RECOMMENDATIONS. Current means same candidate identity,
-- not newest-by-surface. Expired/changed docs, settings or evidence can remove it.
WITH history_scope AS (
    SELECT results.recommendation_id, results.review_status,
           IFF(candidates.recommendation_id IS NULL,
               'historical_not_current', 'current') AS result_scope
    FROM RECOMMENDATION_RESULTS AS results
    LEFT JOIN (SELECT DISTINCT recommendation_id FROM RECOMMENDATION_CANDIDATES) AS candidates
      ON candidates.recommendation_id = results.recommendation_id
)
SELECT result_scope, review_status, COUNT(*) AS saved_result_identities
FROM history_scope GROUP BY result_scope, review_status ORDER BY result_scope, review_status;

-- 6. Duplicate IDs can inflate joins/counts or hide rows behind view deduplication.
-- Diagnose only; never delete evidence here. Empty means no duplicates found, not health.
WITH saved_ids AS (
    SELECT 'AGENT_EVENTS' AS object_name, event_hash AS identity FROM AGENT_EVENTS
    UNION ALL
    SELECT 'AGENT_SETTINGS_HISTORY', snapshot_id FROM AGENT_SETTINGS_HISTORY
    UNION ALL
    SELECT 'ANSWER_REVIEW_INPUTS', review_id FROM ANSWER_REVIEW_INPUTS
    UNION ALL
    SELECT 'ANSWER_REVIEWS', review_id FROM ANSWER_REVIEWS
    UNION ALL
    SELECT 'DOCUMENTATION_RETRIEVALS', retrieval_id FROM DOCUMENTATION_RETRIEVALS
    UNION ALL
    SELECT 'RECOMMENDATION_INPUTS', recommendation_id FROM RECOMMENDATION_INPUTS
    UNION ALL
    SELECT 'RECOMMENDATIONS', recommendation_id FROM RECOMMENDATIONS
)
SELECT object_name, identity, COUNT(*) AS saved_rows
FROM saved_ids GROUP BY object_name, identity HAVING COUNT(*) > 1
ORDER BY object_name, identity;