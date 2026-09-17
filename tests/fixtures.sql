-- README: OFFLINE-AUTHORED TEST INPUT. NOT EXECUTED OR COMPILED AGAINST SNOWFLAKE.
-- Install sql/00_setup.sql through sql/06_tasks.sql LATER in a NEW, dedicated,
-- disposable schema created solely for this test. Never use a production schema.
-- Replace __OUTPUT_DATABASE__ and __OUTPUT_SCHEMA__ with that SAME install target.
-- Keep all tasks suspended; use a single session, AUTOCOMMIT enabled, no concurrent
-- writers, and a client that STOPS ON ERROR. Do not run install SQL between these files.
-- Run fixtures.sql, then assertions.sql IN THE SAME SESSION without disconnecting.
-- This file leaves a transaction OPEN. Assertions roll it back on pass or failure.
-- If interrupted or any statement fails, run ROLLBACK in this session immediately.
-- No COMMIT, DDL, procedure CALL, or LLM execution is allowed after BEGIN TRANSACTION.
-- Temporary fixture data survives rollback until the session ends. All data is synthetic.

USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

EXECUTE IMMEDIATE $$
DECLARE
    existing_rows INTEGER;
    task_count INTEGER;
    unsafe_tasks INTEGER;
    tasks_query_id VARCHAR;
    unsafe_target EXCEPTION (-20030, 'Use a new empty disposable schema matching this rendered installation, with no active transaction and suspended tasks. Stop on error.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL
        OR CURRENT_DATABASE() <> '__OUTPUT_DATABASE__'
        OR CURRENT_SCHEMA() <> '__OUTPUT_SCHEMA__') THEN
        RAISE unsafe_target;
    END IF;
    SELECT SUM(row_count) INTO :existing_rows FROM (
        SELECT COUNT(*) AS row_count FROM AF_EVENTS
        UNION ALL SELECT COUNT(*) FROM AF_RUNS
        UNION ALL SELECT COUNT(*) FROM AF_CONFIG_SNAPSHOTS
        UNION ALL SELECT COUNT(*) FROM AF_RUN_FEEDBACK
        UNION ALL SELECT COUNT(*) FROM AF_DIAGNOSES
        UNION ALL SELECT COUNT(*) FROM AF_DOC_CACHE
        UNION ALL SELECT COUNT(*) FROM AF_RECOMMENDATIONS
        UNION ALL SELECT COUNT(*) FROM AF_RUN_RECOMMENDATIONS
    );
    IF (existing_rows <> 0) THEN
        RAISE unsafe_target;
    END IF;
    SHOW TASKS IN SCHEMA __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__;
    tasks_query_id := SQLID;
    SELECT COUNT(*), COALESCE(COUNT_IF(UPPER("state") IS DISTINCT FROM 'SUSPENDED'), 0)
    INTO :task_count, :unsafe_tasks FROM TABLE(RESULT_SCAN(:tasks_query_id));
    IF (task_count <> 7 OR unsafe_tasks <> 0) THEN
        RAISE unsafe_target;
    END IF;
END;
$$;

CREATE OR REPLACE TEMPORARY TABLE AF_FIXTURE_EVENTS AS
WITH identities AS (
    SELECT column1::VARCHAR AS agent_database, column2::VARCHAR AS agent_schema,
        column3::VARCHAR AS agent_name
    FROM VALUES
        ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT'),
        ('AF_SYNTH_DB_B', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT'),
        ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_B', 'AF_SYNTH_AGENT'),
        ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT_OTHER')
), roots AS (
    SELECT column1::VARCHAR AS event_key, column2::VARCHAR AS trace_id,
        column3::VARCHAR AS thread_id, column4::INTEGER AS second_offset,
        column5::VARCHAR AS span_id, column6::VARCHAR AS user_message,
        column7::VARCHAR AS agent_response, column8::VARCHAR AS status_code
    FROM VALUES
        ('identity_02', 'af_fixture_identity_02', 'af_fixture_shared', 0, 'root', 'Repeat the synthetic question.', 'Synthetic follow-up answer.', 'OK'),
        ('identity_01', 'af_fixture_identity_01', 'af_fixture_shared', 0, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('zero_01', 'af_fixture_zero_01', '0', 10, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('zero_02', 'af_fixture_zero_02', '0', 11, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('null_01', 'af_fixture_null_01', NULL, 20, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('null_02', 'af_fixture_null_02', NULL, 21, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('space_01', 'af_fixture_space_01', '   ', 22, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('space_02', 'af_fixture_space_02', '   ', 23, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('blank_01', 'af_fixture_blank_01', 'af_fixture_blank', 30, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('blank_02', 'af_fixture_blank_02', 'af_fixture_blank', 31, 'root', '   ', 'Synthetic answer.', 'OK'),
        ('blank_03', 'af_fixture_blank_03', 'af_fixture_blank', 32, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('blank_04', 'af_fixture_blank_04', 'af_fixture_blank', 33, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('redacted_01', 'af_fixture_redacted_01', 'af_fixture_redacted', 40, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('redacted_02', 'af_fixture_redacted_02', 'af_fixture_redacted', 41, 'root', 'Synthetic question.', '[redacted]', 'OK'),
        ('redacted_03', 'af_fixture_redacted_03', 'af_fixture_redacted', 42, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('missing_01', 'af_fixture_missing_01', 'af_fixture_missing', 43, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('missing_02', 'af_fixture_missing_02', 'af_fixture_missing', 44, 'root', 'Synthetic question.', NULL, 'ERROR'),
        ('missing_03', 'af_fixture_missing_03', 'af_fixture_missing', 45, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK'),
        ('dedup_old', 'af_fixture_dedup_01', 'af_fixture_dedup', 49, 'zz', 'First readable synthetic question.', 'Obsolete synthetic answer.', 'ERROR'),
        ('dedup_span_a', 'af_fixture_dedup_01', 'af_fixture_dedup', 50, 'a', 'Later synthetic question.', 'Wrong span answer.', 'ERROR'),
        ('dedup_hash_a', 'af_fixture_dedup_01', 'af_fixture_dedup', 50, 'z', 'Later synthetic question.', 'Wrong hash answer.', 'ERROR'),
        ('dedup_hash_z', 'af_fixture_dedup_01', 'af_fixture_dedup', 50, 'z', 'Later synthetic question.', 'Selected synthetic answer.', 'OK'),
        ('dedup_02', 'af_fixture_dedup_02', 'af_fixture_dedup', 51, 'root', 'Synthetic question.', 'Synthetic answer.', 'OK')
), tools AS (
    SELECT column1::VARCHAR AS event_key, column2::VARCHAR AS trace_id,
        column3::INTEGER AS second_offset, column4::VARCHAR AS span_id,
        column5::VARCHAR AS span_name, column6::VARCHAR AS tool_name,
        column7::VARCHAR AS final_sql, column8::VARCHAR AS chart_spec,
        column9::VARCHAR AS status_code
    FROM VALUES
        ('sql_late', 'af_fixture_identity_01', 2, 'a', 'synthetic_sql', 'synthetic_sql', 'SELECT 4 AS synthetic_value', NULL, 'OK'),
        ('sql_tie_z', 'af_fixture_identity_01', 1, 'b', 'synthetic_sql', 'synthetic_sql', 'SELECT 3 AS synthetic_value', NULL, 'ERROR'),
        ('sql_tie_a', 'af_fixture_identity_01', 1, 'b', 'synthetic_sql', 'synthetic_sql', 'SELECT 2 AS synthetic_value', NULL, 'OK'),
        ('sql_early', 'af_fixture_identity_01', 1, 'a', 'synthetic_sql', 'synthetic_sql', 'SELECT 1 AS synthetic_value', NULL, 'OK'),
        ('skill', 'af_fixture_identity_01', 3, 'skill', 'ServerSkillTool_synthetic', NULL, NULL, NULL, 'OK'),
        ('chart', 'af_fixture_identity_01', 4, 'chart', 'CortexChartToolImpl-synthetic', NULL, NULL, '{"synthetic":true}', 'OK'),
        ('orphan', 'af_fixture_orphan', 5, 'orphan', 'synthetic_sql', 'synthetic_sql', 'SELECT 0 AS synthetic_value', NULL, 'ERROR')
), events AS (
    SELECT event_key, trace_id, thread_id, second_offset, span_id,
        'synthetic_root'::VARCHAR AS span_name, 'record_root'::VARCHAR AS span_type,
        user_message, agent_response, NULL::VARCHAR AS tool_name,
        NULL::VARCHAR AS final_sql, NULL::VARCHAR AS chart_spec, status_code
    FROM roots
    UNION ALL
    SELECT event_key, trace_id, NULL, second_offset, span_id, span_name, 'tool',
        NULL, NULL, tool_name, final_sql, chart_spec, status_code
    FROM tools
)
SELECT identities.agent_database || '.' || identities.agent_schema || '.'
        || identities.agent_name || ':' || events.event_key AS event_hash,
    identities.agent_database, identities.agent_schema, identities.agent_name,
    DATEADD('second', events.second_offset, '2001-01-01T00:00:00+00:00'::TIMESTAMP_LTZ) AS event_ts,
    events.trace_id, events.span_id, events.span_name, events.span_type, events.thread_id,
    events.trace_id || '_message' AS message_id, events.user_message, events.agent_response,
    events.tool_name, events.final_sql, events.chart_spec, events.status_code,
    '2001-01-02T00:00:00+00:00'::TIMESTAMP_LTZ AS first_seen_at,
    NULL::NUMBER AS fixture_transaction_id
FROM identities CROSS JOIN events;

BEGIN TRANSACTION;

EXECUTE IMMEDIATE $$
BEGIN
    UPDATE AF_FIXTURE_EVENTS SET fixture_transaction_id = CURRENT_TRANSACTION();
    INSERT INTO AF_EVENTS (
        event_hash, agent_database, agent_schema, agent_name, event_ts, trace_id,
        span_id, span_name, span_type, thread_id, message_id, user_message,
        agent_response, tool_name, final_sql, chart_spec, status_code, first_seen_at)
    SELECT event_hash, agent_database, agent_schema, agent_name, event_ts, trace_id,
        span_id, span_name, span_type, thread_id, message_id, user_message,
        agent_response, tool_name, final_sql, chart_spec, status_code, first_seen_at
    FROM AF_FIXTURE_EVENTS;
EXCEPTION
    WHEN OTHER THEN
        -- No ROLLBACK here: the transaction began at session scope and
        -- Snowflake refuses to let this block modify it. Nothing is committed,
        -- so run ROLLBACK yourself in this session, or disconnect.
        RAISE;
END;
$$;