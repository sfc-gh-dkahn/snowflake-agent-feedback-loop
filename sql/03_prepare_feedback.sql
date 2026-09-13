USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE OR REPLACE VIEW AF_TURNS AS
WITH roots AS (
    SELECT * FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_EVENTS
    WHERE span_type = 'record_root'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY agent_database, agent_schema, agent_name, trace_id
        ORDER BY event_ts DESC, span_id DESC NULLS LAST, event_hash DESC) = 1
), user_messages AS (
    SELECT agent_database, agent_schema, agent_name, trace_id, user_message,
           event_hash AS user_event_hash
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_EVENTS
    WHERE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TEXT_PRESENT(user_message)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY agent_database, agent_schema, agent_name, trace_id
        ORDER BY event_ts, span_id ASC NULLS LAST, event_hash) = 1
), details AS (
    SELECT agent_database, agent_schema, agent_name, trace_id,
        ARRAY_AGG(event_hash) WITHIN GROUP (ORDER BY event_ts, span_id ASC NULLS LAST, event_hash) AS event_hashes,
        ARRAY_AGG(IFF(tool_name IS NOT NULL OR final_sql IS NOT NULL OR chart_spec IS NOT NULL
            OR STARTSWITH(span_name, 'ServerSkillTool_') OR STARTSWITH(span_name, 'CortexChartToolImpl-'),
            OBJECT_CONSTRUCT_KEEP_NULL('event_hash', event_hash, 'span_id', span_id,
                'event_epoch_ns', DATE_PART(epoch_nanosecond, event_ts),
                'span_name', span_name, 'tool_name', tool_name, 'final_sql', final_sql,
                'chart_spec', chart_spec, 'status_code', status_code), NULL))
            WITHIN GROUP (ORDER BY event_ts, span_id ASC NULLS LAST, event_hash) AS tool_evidence
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_EVENTS
    GROUP BY agent_database, agent_schema, agent_name, trace_id
)
SELECT roots.agent_database, roots.agent_schema, roots.agent_name, roots.thread_id,
    roots.trace_id, roots.message_id, roots.event_ts, roots.event_hash AS root_event_hash,
    user_messages.user_message, roots.agent_response, roots.status_code,
    details.tool_evidence, details.event_hashes,
    __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TEXT_PRESENT(user_messages.user_message)
        AND __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TEXT_PRESENT(roots.agent_response) AS is_complete,
    ROW_NUMBER() OVER (
        PARTITION BY roots.agent_database, roots.agent_schema, roots.agent_name, roots.thread_id
        ORDER BY roots.event_ts, roots.trace_id) AS turn_no,
    SHA2(TO_JSON(ARRAY_CONSTRUCT(roots.agent_database, roots.agent_schema, roots.agent_name,
        roots.thread_id, roots.trace_id, roots.event_hash, user_messages.user_event_hash,
        details.event_hashes)), 256) AS turn_hash
FROM roots
LEFT JOIN user_messages USING (agent_database, agent_schema, agent_name, trace_id)
LEFT JOIN details USING (agent_database, agent_schema, agent_name, trace_id);

CREATE OR REPLACE VIEW AF_FEEDBACK_PAIRS AS
SELECT feedback.*, response.trace_id AS response_trace_id,
    response.turn_hash AS response_turn_hash
FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TURNS AS feedback
JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TURNS AS response
  ON response.agent_database = feedback.agent_database
 AND response.agent_schema = feedback.agent_schema AND response.agent_name = feedback.agent_name
 AND response.thread_id = feedback.thread_id AND response.turn_no = feedback.turn_no - 1
WHERE NULLIF(TRIM(feedback.thread_id), '') IS NOT NULL AND feedback.thread_id <> '0'
  AND feedback.is_complete AND response.is_complete;

CREATE OR REPLACE PROCEDURE AF_PREPARE_FEEDBACK(P_RUN_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
    V_DATABASE VARCHAR;
    V_SCHEMA VARCHAR;
    V_AGENT VARCHAR;
    V_MODEL VARCHAR;
    V_REVISION VARCHAR;
    V_LIMIT INTEGER;
    V_SPEC VARIANT;
    V_CONFIG_HASH VARCHAR;
    V_COUNT INTEGER;
    V_START TIMESTAMP_LTZ;
    V_END TIMESTAMP_LTZ;
    V_THREAD VARCHAR;
    V_STATUS VARCHAR;
    V_PREVIOUS_STAGE VARCHAR;
    V_DIAGNOSTICS VARIANT;
    V_CANDIDATES INTEGER;
    V_PREPARED INTEGER;
    V_CACHED INTEGER;
    V_RUN_FOUND BOOLEAN DEFAULT FALSE;
    V_IN_TRANSACTION BOOLEAN DEFAULT FALSE;
    V_ERROR VARCHAR;
    E_RUN EXCEPTION (-20004, 'Preparation requires a sole captured run with unchanged config/window/filter and no caller transaction.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL) THEN
        RAISE E_RUN;
    END IF;
    SELECT COUNT(*), ANY_VALUE(window_start), ANY_VALUE(window_end), ANY_VALUE(thread_filter),
        ANY_VALUE(status), ANY_VALUE(stage), ANY_VALUE(diagnostics)
    INTO :V_COUNT, :V_START, :V_END, :V_THREAD, :V_STATUS, :V_PREVIOUS_STAGE, :V_DIAGNOSTICS
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS WHERE run_id = :P_RUN_ID;
    IF (V_COUNT <> 1 OR NULLIF(TRIM(P_RUN_ID), '') IS NULL
        OR NOT COALESCE(V_STATUS IN ('RUNNING', 'FAILED')
            AND V_PREVIOUS_STAGE IN ('CAPTURE_CONTEXT_COMPLETE',
                'PREPARE_FEEDBACK', 'PREPARE_FEEDBACK_COMPLETE'), FALSE)) THEN
        RAISE E_RUN;
    END IF;
    V_RUN_FOUND := TRUE;
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_READ_CONFIG() INTO :V_CONFIG;
    V_DATABASE := V_CONFIG:agent_database::VARCHAR;
    V_SCHEMA := V_CONFIG:agent_schema::VARCHAR;
    V_AGENT := V_CONFIG:agent_name::VARCHAR;
    V_MODEL := V_CONFIG:judge_model::VARCHAR;
    V_REVISION := V_CONFIG:prompt_revision::VARCHAR;
    V_LIMIT := V_CONFIG:max_diagnoses::INTEGER;
    IF (NOT COALESCE(V_STATUS IN ('RUNNING', 'FAILED')
        AND V_PREVIOUS_STAGE IN ('CAPTURE_CONTEXT_COMPLETE', 'PREPARE_FEEDBACK', 'PREPARE_FEEDBACK_COMPLETE')
        AND V_DIAGNOSTICS:capture:runtime_config_hash::VARCHAR = V_CONFIG:runtime_config_hash::VARCHAR
        AND V_DIAGNOSTICS:capture:window_start_epoch_ns::NUMBER = DATE_PART(epoch_nanosecond, V_START)
        AND V_DIAGNOSTICS:capture:window_end_epoch_ns::NUMBER = DATE_PART(epoch_nanosecond, V_END)
        AND V_DIAGNOSTICS:capture:thread_filter_hash::VARCHAR = SHA2(TO_JSON(ARRAY_CONSTRUCT(V_THREAD)), 256)
        AND V_START < V_END AND V_END <= CURRENT_TIMESTAMP()
        AND V_START >= DATEADD('day', -V_CONFIG:lookback_days::INTEGER, V_END), FALSE)) THEN
        RAISE E_RUN;
    END IF;
    SELECT COUNT(*), ANY_VALUE(agent_spec), ANY_VALUE(config_hash)
    INTO :V_COUNT, :V_SPEC, :V_CONFIG_HASH
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CONFIG_SNAPSHOTS
    WHERE run_id = :P_RUN_ID AND agent_database = :V_DATABASE
      AND agent_schema = :V_SCHEMA AND agent_name = :V_AGENT;
    IF (V_COUNT <> 1 OR NOT COALESCE(IS_OBJECT(V_SPEC), FALSE)) THEN
        RAISE E_RUN;
    END IF;
    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET status = 'RUNNING', stage = 'PREPARE_FEEDBACK', error_message = NULL, completed_at = NULL
    WHERE run_id = :P_RUN_ID;
    COMMIT;
    V_IN_TRANSACTION := FALSE;

    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    DELETE FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK WHERE run_id = :P_RUN_ID;
    SELECT COUNT(*) INTO :V_CANDIDATES
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_FEEDBACK_PAIRS
    WHERE agent_database = :V_DATABASE AND agent_schema = :V_SCHEMA AND agent_name = :V_AGENT
      AND event_ts >= :V_START AND event_ts < :V_END
      AND (:V_THREAD IS NULL OR thread_id = :V_THREAD);
    INSERT INTO __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK (
        run_id, diagnosis_id, agent_database, agent_schema, agent_name, thread_id,
        response_trace_id, feedback_trace_id, feedback_ts, evidence, current_config,
        config_hash, judge_model, prompt_revision)
    WITH pairs AS (
        SELECT * FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_FEEDBACK_PAIRS
        WHERE agent_database = :V_DATABASE AND agent_schema = :V_SCHEMA AND agent_name = :V_AGENT
          AND event_ts >= :V_START AND event_ts < :V_END
          AND (:V_THREAD IS NULL OR thread_id = :V_THREAD)
    ), context_hashes AS (
        SELECT pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id,
            pairs.trace_id,
            ARRAY_AGG(prior.turn_hash) WITHIN GROUP (ORDER BY prior.event_ts, prior.trace_id) AS prior_hashes
        FROM pairs
        JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TURNS AS prior
          ON prior.agent_database = pairs.agent_database AND prior.agent_schema = pairs.agent_schema
         AND prior.agent_name = pairs.agent_name AND prior.thread_id = pairs.thread_id
         AND prior.turn_no BETWEEN pairs.turn_no - 6 AND pairs.turn_no - 1
         AND prior.is_complete
        GROUP BY pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id, pairs.trace_id
    ), identities AS (
        SELECT pairs.*, SHA2(TO_JSON(ARRAY_CONSTRUCT(
            pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id,
            pairs.response_trace_id, pairs.trace_id, context_hashes.prior_hashes,
            pairs.response_turn_hash, pairs.turn_hash, :V_CONFIG_HASH, :V_MODEL, :V_REVISION)), 256) AS diagnosis_id
        FROM pairs
        JOIN context_hashes ON context_hashes.agent_database = pairs.agent_database
            AND context_hashes.agent_schema = pairs.agent_schema AND context_hashes.agent_name = pairs.agent_name
            AND context_hashes.thread_id = pairs.thread_id AND context_hashes.trace_id = pairs.trace_id
    ), selected AS (
        SELECT identities.*, persisted.diagnosis_id IS NOT NULL AS is_cached
        FROM identities
        LEFT JOIN (SELECT DISTINCT diagnosis_id FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES) AS persisted
          ON persisted.diagnosis_id = identities.diagnosis_id
        QUALIFY is_cached OR ROW_NUMBER() OVER (
            PARTITION BY is_cached ORDER BY event_ts DESC, trace_id, response_trace_id) <= :V_LIMIT
    ), cached_evidence AS (
        SELECT previous.diagnosis_id, previous.evidence
        FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK AS previous
        JOIN selected ON selected.diagnosis_id = previous.diagnosis_id AND selected.is_cached
        QUALIFY ROW_NUMBER() OVER (PARTITION BY previous.diagnosis_id ORDER BY previous.run_id) = 1
    ), context AS (
        SELECT pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id,
            pairs.trace_id,
            ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
                'trace_id', prior.trace_id, 'message_id', prior.message_id,
                'event_epoch_ns', DATE_PART(epoch_nanosecond, prior.event_ts),
                'user_message', prior.user_message, 'agent_response', prior.agent_response,
                'status_code', prior.status_code, 'tool_evidence', prior.tool_evidence,
                'event_hashes', prior.event_hashes))
                WITHIN GROUP (ORDER BY prior.event_ts, prior.trace_id) AS prior_turns
        FROM selected AS pairs
        JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TURNS AS prior
          ON prior.agent_database = pairs.agent_database AND prior.agent_schema = pairs.agent_schema
         AND prior.agent_name = pairs.agent_name AND prior.thread_id = pairs.thread_id
         AND prior.turn_no BETWEEN pairs.turn_no - 6 AND pairs.turn_no - 1
         AND prior.is_complete
        WHERE NOT EXISTS (SELECT 1 FROM cached_evidence WHERE diagnosis_id = pairs.diagnosis_id)
        GROUP BY pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id, pairs.trace_id
    )
    SELECT :P_RUN_ID, pairs.diagnosis_id,
        pairs.agent_database, pairs.agent_schema, pairs.agent_name, pairs.thread_id,
        pairs.response_trace_id, pairs.trace_id, pairs.event_ts,
        COALESCE(cached_evidence.evidence, OBJECT_CONSTRUCT_KEEP_NULL('response_trace_id', pairs.response_trace_id,
            'feedback_trace_id', pairs.trace_id, 'prior_turns', context.prior_turns,
            'feedback_turn', OBJECT_CONSTRUCT_KEEP_NULL('trace_id', pairs.trace_id,
                'message_id', pairs.message_id, 'event_epoch_ns', DATE_PART(epoch_nanosecond, pairs.event_ts),
                'user_message', pairs.user_message, 'agent_response', pairs.agent_response,
                'status_code', pairs.status_code, 'tool_evidence', pairs.tool_evidence,
                'event_hashes', pairs.event_hashes),
            'coverage', 'FOLLOWUP_PROXY; NOT_EXPLICIT_FEEDBACK; NO_FINAL_ANSWER_WITHOUT_FOLLOWUP',
            'config_scope', 'CAPTURE_TIME_ONLY; INVOCATION_VERSION_UNKNOWN')),
        :V_SPEC, :V_CONFIG_HASH, :V_MODEL, :V_REVISION
    FROM selected AS pairs
    LEFT JOIN cached_evidence ON cached_evidence.diagnosis_id = pairs.diagnosis_id
    LEFT JOIN context ON context.agent_database = pairs.agent_database AND context.agent_schema = pairs.agent_schema
        AND context.agent_name = pairs.agent_name AND context.thread_id = pairs.thread_id
        AND context.trace_id = pairs.trace_id;
    V_PREPARED := SQLROWCOUNT;
    SELECT COUNT(*) INTO :V_CACHED
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK AS feedback
    WHERE feedback.run_id = :P_RUN_ID AND EXISTS (
        SELECT 1 FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES AS persisted
        WHERE persisted.diagnosis_id = feedback.diagnosis_id);
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET stage = 'PREPARE_FEEDBACK_COMPLETE', diagnostics = OBJECT_INSERT(:V_DIAGNOSTICS::OBJECT,
        'prepare', OBJECT_CONSTRUCT('candidate_pairs', :V_CANDIDATES, 'prepared_pairs', :V_PREPARED,
            'cached_pairs', :V_CACHED, 'new_pairs', :V_PREPARED - :V_CACHED,
            'pairs_over_limit', :V_CANDIDATES - :V_PREPARED, 'prior_turns_max', 6,
            'selection', 'ALL_CACHED; MOST_RECENT_UNSEEN_FOLLOWUPS; STABLE_TRACE_TIES',
            'coverage', 'COMPLETE_ADJACENT_TURNS_ONLY; ARCHIVED_HISTORY_ONLY'), TRUE)
    WHERE run_id = :P_RUN_ID;
    COMMIT;
    V_IN_TRANSACTION := FALSE;
    RETURN 'PREPARE_FEEDBACK_COMPLETE';
EXCEPTION
    WHEN OTHER THEN
        V_ERROR := 'Preparation failed; SQLSTATE=' || SQLSTATE || '; SQLCODE=' || SQLCODE::VARCHAR;
        IF (V_IN_TRANSACTION) THEN
            ROLLBACK;
        END IF;
        IF (V_RUN_FOUND) THEN
            BEGIN
                BEGIN TRANSACTION;
                UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
                SET status = 'FAILED', stage = 'PREPARE_FEEDBACK', completed_at = CURRENT_TIMESTAMP(),
                    error_message = :V_ERROR WHERE run_id = :P_RUN_ID;
                COMMIT;
            EXCEPTION
                WHEN OTHER THEN
                    ROLLBACK;
            END;
        END IF;
        RAISE;
END;
$$;