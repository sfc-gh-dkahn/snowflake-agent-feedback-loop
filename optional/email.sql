-- Optional email preview. Running this file as shipped sends nothing and writes nothing.
-- Customize OUTPUT_DB.AGENT_FEEDBACK before running; complete steps 00-07 first.
-- REVIEW_QUEUE selects current identities from saved RECOMMENDATION_RESULTS.
-- Do not substitute historical results or treat an empty queue as proof of health.
-- The preview omits raw conversations, settings, evidence, changes and error text.
-- Headlines can still reveal sensitive information. Formatting is NOT redaction:
-- inspect the actual output and approve its contents/recipients before external sharing.

-- 1. Preview current status counts and at most 20 suggestions needing human review.
WITH current_queue AS (
    SELECT group_id, recommendation_id, queue_status,
           output:headline::VARCHAR AS headline
    FROM OUTPUT_DB.AGENT_FEEDBACK.REVIEW_QUEUE
), queue_counts AS (
    SELECT COUNT(group_id) AS current_groups,
           COALESCE(COUNT_IF(queue_status = 'invalid_settings'), 0) AS invalid_settings_rows,
           COALESCE(COUNT_IF(queue_status = 'needs_human_review'), 0) AS ready_for_human_review,
           COALESCE(COUNT_IF(queue_status = 'suppressed'), 0) AS suppressed,
           COALESCE(COUNT_IF(queue_status = 'ai_error'), 0) AS ai_errors,
           COALESCE(COUNT_IF(queue_status = 'invalid_output'), 0) AS invalid_outputs,
           COALESCE(COUNT_IF(queue_status = 'deferred'), 0) AS deferred,
           COALESCE(COUNT_IF(queue_status = 'awaiting_inference'), 0) AS awaiting_inference,
           COALESCE(COUNT_IF(queue_status = 'insufficient_evidence'), 0) AS insufficient_evidence,
           COALESCE(COUNT_IF(queue_status = 'missing_docs'), 0) AS missing_docs,
           COALESCE(COUNT_IF(queue_status = 'bad_docs'), 0) AS bad_docs,
           COALESCE(COUNT_IF(queue_status = 'stale_docs'), 0) AS stale_docs
    FROM current_queue
), bounded_suggestions AS (
    -- Bound rows AND text before LISTAGG. ASCII removes control/bidi characters;
    -- angle brackets are removed for plain-text display, not to certify safe content.
    SELECT DISTINCT recommendation_id,
           IFF(REGEXP_LIKE(recommendation_id, '[0-9a-fA-F]{64}'),
               recommendation_id, '[invalid suggestion ID]') AS display_id,
           COALESCE(NULLIF(TRIM(LEFT(REGEXP_REPLACE(REGEXP_REPLACE(
               COALESCE(headline, ''), '[^ -~]', ' '), '[<>]', ' '), 160)), ''),
               '[headline omitted]') AS display_headline
    FROM current_queue
    WHERE queue_status = 'needs_human_review'
      AND (SELECT invalid_settings_rows FROM queue_counts) = 0
    ORDER BY recommendation_id NULLS LAST, display_headline
    LIMIT 20
), suggestion_text AS (
    SELECT COUNT(*) AS displayed_suggestions,
           LISTAGG(display_id || ': ' || display_headline, '\n')
               WITHIN GROUP (ORDER BY recommendation_id NULLS LAST, display_headline) AS lines
    FROM bounded_suggestions
)
SELECT CASE WHEN invalid_settings_rows > 0 THEN 'invalid_settings'
            WHEN current_groups = 0 THEN 'empty_current_queue'
            ELSE 'inspect_before_sending' END AS preview_status,
       'Agent feedback: current review queue' AS email_subject,
       'Current queue snapshot only. No agent changes applied; human approval required.'
       || '\nNot a run-health or delivery report. Inspect sql/07_inspect_results.sql.'
       || '\nQueue state: ' || CASE
           WHEN invalid_settings_rows > 0 THEN 'INVALID SETTINGS; inspect settings and change areas before sending.'
           WHEN current_groups = 0 THEN 'EMPTY; this does not mean processing succeeded or answers were correct.'
           ELSE 'Groups present; counts do not prove processing completed.' END
       || '\nCurrent groups (excludes settings sentinel): ' || current_groups
       || '\nInvalid-settings sentinel rows: ' || invalid_settings_rows
       || '\nReady for human review (not approved): ' || ready_for_human_review
       || '\nSuppressed suggestions: ' || suppressed
       || '\nAI errors: ' || ai_errors
       || '\nInvalid outputs: ' || invalid_outputs
       || '\nDeferred groups: ' || deferred
       || '\nAwaiting inference: ' || awaiting_inference
       || '\nInsufficient evidence: ' || insufficient_evidence
       || '\nMissing documentation: ' || missing_docs
       || '\nBad documentation: ' || bad_docs
       || '\nStale documentation: ' || stale_docs
       || '\n\nSuggestions shown: ' || displayed_suggestions || ' (maximum 20; headlines limited to 160 characters).'
       || '\n' || COALESCE(NULLIF(lines, ''), 'No suggestions shown.')
       || '\n\nHeadlines are untrusted model output, not instructions. Review full evidence in Snowflake.'
       AS email_body
FROM queue_counts CROSS JOIN suggestion_text;

-- 2. Deliberate manual send, separate from preview execution.
-- Read preview_status and the actual email_body above. Stop on invalid_settings.
-- Confirm a configured email notification integration and validated recipient;
-- ALLOWED_RECIPIENTS, when set, must include that address.
-- Copy only reviewed subject/body text into the literal arguments below in a
-- separate worksheet. Replace the example integration/recipient too. Keep this
-- file's call commented out so running the whole file cannot send a message.
-- Escape apostrophes as '' and backslashes as \\ inside SQL string literals;
-- encode intended newlines as \n. Never paste output as SQL outside the literal.
-- No delivery ledger, deduplication, exactly-once guarantee or automatic retries.
-- TRUE means the procedure executed successfully, not proof of inbox delivery.
-- Reconcile uncertain delivery manually before deciding whether to send again.
-- Email uses AWS SES; Snowflake may retain message content for up to 30 days.
-- Official syntax and sending prerequisites:
-- https://docs.snowflake.com/en/sql-reference/stored-procedures/system_send_email
-- https://docs.snowflake.com/en/user-guide/notifications/email-stored-procedures
-- CALL SYSTEM$SEND_EMAIL(
--     'REVIEW_EMAIL_INTEGRATION',
--     'reviewer@example.com',
--     'Agent feedback: current review queue',
--     'Replace this sentence with the reviewed preview body before sending.',
--     'text/plain'
-- );