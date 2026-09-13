USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE OR REPLACE PROCEDURE AF_ASSERT_CONFIG()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
BEGIN
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_READ_CONFIG() INTO :V_CONFIG;
    RETURN V_CONFIG;
END;
$$;

CREATE OR REPLACE PROCEDURE AF_START_RUN(
    P_RUN_ID VARCHAR, P_WINDOW_START TIMESTAMP_LTZ,
    P_WINDOW_END TIMESTAMP_LTZ, P_THREAD_FILTER VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
    V_NOW TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    V_START TIMESTAMP_LTZ;
    V_END TIMESTAMP_LTZ;
    V_COUNT INTEGER;
    E_REQUEST EXCEPTION (-20010, 'Invalid run request: use a UUID, a window within 90 days and lookback_days, an end at least 15 minutes old, and a valid thread filter.');
    E_OVERLAP EXCEPTION (-20011, 'An active run or this run ID already exists. Serialize manual calls, keep AF_START suspended, and wait for the graph to finish.');
    E_TRANSACTION EXCEPTION (-20012, 'Run outside a caller transaction with AUTOCOMMIT enabled.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL) THEN
        RAISE E_TRANSACTION;
    END IF;
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_CONFIG() INTO :V_CONFIG;
    V_END := COALESCE(P_WINDOW_END, DATEADD('minute', -15, V_NOW));
    V_START := COALESCE(P_WINDOW_START,
        DATEADD('day', -V_CONFIG:lookback_days::INTEGER, COALESCE(P_WINDOW_END, V_NOW)));
    IF (NOT COALESCE(
        REGEXP_LIKE(P_RUN_ID, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        AND V_START < V_END AND V_END <= DATEADD('minute', -15, V_NOW)
        AND V_START >= DATEADD('day', -90, V_NOW)
        AND V_START >= DATEADD('day', -V_CONFIG:lookback_days::INTEGER, V_END)
        AND (P_THREAD_FILTER IS NULL OR (
            LENGTH(P_THREAD_FILTER) BETWEEN 1 AND 256
            AND P_THREAD_FILTER = TRIM(P_THREAD_FILTER) AND P_THREAD_FILTER <> '0'
            AND NOT REGEXP_LIKE(P_THREAD_FILTER, '.*[[:cntrl:]].*', 's'))), FALSE)) THEN
        RAISE E_REQUEST;
    END IF;
    SELECT COUNT(*) INTO :V_COUNT
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    WHERE UPPER(status) = 'RUNNING' OR run_id = :P_RUN_ID;
    IF (V_COUNT <> 0) THEN
        RAISE E_OVERLAP;
    END IF;
    BEGIN
        BEGIN TRANSACTION;
        INSERT INTO __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS (
            run_id, started_at, window_start, window_end, thread_filter, status, stage, diagnostics)
        SELECT :P_RUN_ID, :V_NOW, :V_START, :V_END, :P_THREAD_FILTER, 'RUNNING', 'START',
            OBJECT_CONSTRUCT('runtime_config_hash', :V_CONFIG:runtime_config_hash);
        COMMIT;
    EXCEPTION
        WHEN OTHER THEN
            ROLLBACK;
            RAISE;
    END;
    RETURN P_RUN_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE AF_ASSERT_STAGE(P_RUN_ID VARCHAR, P_STAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
    V_COUNT INTEGER;
    E_STAGE EXCEPTION (-20013, 'Expected one active run at the required stage with unchanged configuration. Start a new run after fixing the failure.');
BEGIN
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_CONFIG() INTO :V_CONFIG;
    SELECT COUNT(*) INTO :V_COUNT
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    WHERE run_id = :P_RUN_ID AND status = 'RUNNING' AND stage = :P_STAGE
      AND COALESCE(diagnostics:capture:runtime_config_hash::VARCHAR,
                   diagnostics:runtime_config_hash::VARCHAR) = :V_CONFIG:runtime_config_hash::VARCHAR;
    IF (V_COUNT <> 1) THEN
        RAISE E_STAGE;
    END IF;
    RETURN P_RUN_ID;
END;
$$;

CREATE OR REPLACE VIEW AF_REVIEW_QUEUE AS
SELECT mapping.run_id, recommendation.recommendation_id,
    recommendation.agent_database, recommendation.agent_schema, recommendation.agent_name,
    recommendation.surface, recommendation.created_at,
    recommendation.raw_output:headline::VARCHAR AS summary,
    recommendation.raw_output:reasoning::VARCHAR AS reasoning,
    recommendation.raw_output:suggested_change::VARCHAR AS suggested_change,
    recommendation.raw_output:change_mode::VARCHAR AS change_mode,
    recommendation.raw_output:displaced_text::VARCHAR AS displaced_text,
    recommendation.raw_output:preserve_behavior::VARCHAR AS preserve_behavior,
    recommendation.raw_output:confidence::VARCHAR AS confidence,
    recommendation.raw_output:citations AS citations,
    recommendation.review_status, recommendation.docs_status,
    runs.status AS run_status, runs.completed_at
FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_RECOMMENDATIONS AS mapping
JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RECOMMENDATIONS AS recommendation
  ON recommendation.recommendation_id = mapping.recommendation_id
JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS AS runs ON runs.run_id = mapping.run_id;

CREATE OR REPLACE PROCEDURE AF_FINISH(P_RUN_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
    V_DIAGNOSTICS VARIANT;
    V_PENDING INTEGER;
    V_INVALID INTEGER;
    V_ERRORS INTEGER;
    V_RECOMMENDATION_PENDING INTEGER;
    V_RECOMMENDATION_INVALID INTEGER;
    V_RECOMMENDATION_ERRORS INTEGER;
    V_NEEDS_REVIEW INTEGER;
    V_DOCS_UNAVAILABLE INTEGER;
    V_SAMPLED INTEGER;
    V_ELIGIBLE INTEGER;
    V_MAPPED INTEGER;
    V_OMITTED INTEGER;
    V_STATUS VARCHAR;
BEGIN
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:P_RUN_ID, 'recommend');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_CONFIG() INTO :V_CONFIG;
    SELECT diagnostics INTO :V_DIAGNOSTICS
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS WHERE run_id = :P_RUN_ID;
    SELECT COALESCE(COUNT_IF(diagnosis.diagnosis_id IS NULL), 0),
        COALESCE(COUNT_IF(LOWER(diagnosis.validation_status) = 'invalid_output'), 0),
        COALESCE(COUNT_IF(diagnosis.diagnosis_id IS NOT NULL
            AND LOWER(diagnosis.validation_status) NOT IN ('valid', 'invalid_output')), 0)
    INTO :V_PENDING, :V_INVALID, :V_ERRORS
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK AS feedback
    LEFT JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES AS diagnosis
      ON diagnosis.diagnosis_id = feedback.diagnosis_id
    WHERE feedback.run_id = :P_RUN_ID;

    SELECT COALESCE(COUNT_IF(recommendation.recommendation_id IS NULL), 0),
        COALESCE(COUNT_IF(LOWER(recommendation.review_status) = 'invalid_output'), 0),
        COALESCE(COUNT_IF(LOWER(recommendation.review_status) IN ('ai_error', 'error')), 0),
        COALESCE(COUNT_IF(LOWER(recommendation.review_status) NOT IN
            ('ready_for_review', 'not_warranted', 'invalid_output', 'ai_error', 'error')), 0),
        COALESCE(COUNT_IF(LOWER(recommendation.docs_status) <> 'ready'), 0),
        COALESCE(COUNT_IF(recommendation.evidence:total_feedback_pairs::INTEGER > 10
            OR recommendation.evidence:total_good_responses::INTEGER > 10), 0)
    INTO :V_RECOMMENDATION_PENDING, :V_RECOMMENDATION_INVALID, :V_RECOMMENDATION_ERRORS,
        :V_NEEDS_REVIEW, :V_DOCS_UNAVAILABLE, :V_SAMPLED
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_RECOMMENDATIONS AS mapping
    LEFT JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RECOMMENDATIONS AS recommendation
      ON recommendation.recommendation_id = mapping.recommendation_id
    WHERE mapping.run_id = :P_RUN_ID;

    SELECT COUNT(*) INTO :V_ELIGIBLE
    FROM (
        WITH latest AS (
            SELECT feedback.*, diagnosis.raw_output, diagnosis.validation_status
            FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK AS feedback
            JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES AS diagnosis
              ON diagnosis.diagnosis_id = feedback.diagnosis_id
            WHERE feedback.run_id = :P_RUN_ID
              AND feedback.agent_database = :V_CONFIG:agent_database::VARCHAR
              AND feedback.agent_schema = :V_CONFIG:agent_schema::VARCHAR
              AND feedback.agent_name = :V_CONFIG:agent_name::VARCHAR
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY feedback.agent_database, feedback.agent_schema, feedback.agent_name,
                    feedback.response_trace_id, feedback.feedback_trace_id
                ORDER BY diagnosis.created_at DESC, feedback.feedback_ts DESC,
                    feedback.diagnosis_id DESC, diagnosis.validation_status DESC,
                    TO_JSON(diagnosis.raw_output) DESC) = 1
        )
        SELECT latest.agent_database, latest.agent_schema, latest.agent_name, supported.surface
        FROM latest
        JOIN __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_SUPPORTED_AREAS AS supported
          ON supported.surface = latest.raw_output:surface::VARCHAR
        WHERE latest.validation_status = 'valid' AND latest.raw_output:assessment::VARCHAR = 'poor'
        GROUP BY latest.agent_database, latest.agent_schema, latest.agent_name, supported.surface
        HAVING COUNT(DISTINCT latest.response_trace_id) >= :V_CONFIG:min_occurrences::INTEGER
            OR COUNT_IF(latest.raw_output:severity::VARCHAR = 'severe') > 0
    );
    SELECT COUNT(DISTINCT recommendation_id) INTO :V_MAPPED
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_RECOMMENDATIONS WHERE run_id = :P_RUN_ID;
    V_OMITTED := GREATEST(V_ELIGIBLE - LEAST(V_MAPPED,
        COALESCE(V_DIAGNOSTICS:recommend:groups_selected::INTEGER, 0)), 0);
    V_STATUS := IFF(
        V_PENDING + V_INVALID + V_ERRORS + V_RECOMMENDATION_PENDING + V_RECOMMENDATION_INVALID
            + V_RECOMMENDATION_ERRORS + V_NEEDS_REVIEW + V_DOCS_UNAVAILABLE + V_SAMPLED + V_OMITTED = 0
        AND COALESCE(V_DIAGNOSTICS:prepare:pairs_over_limit::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:diagnose:invalid_outputs::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:diagnose:ai_errors::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:recommend:ai_errors::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:recommend:docs_unavailable::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:recommend:invalid_output::INTEGER, -1) = 0
        AND COALESCE(V_DIAGNOSTICS:recommend:needs_review::INTEGER, -1) = 0
        AND COALESCE(LOWER(V_DIAGNOSTICS:recommend:status::VARCHAR), 'error') = 'complete',
        'COMPLETE', 'PARTIAL');
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET status = :V_STATUS, stage = 'FINISH', completed_at = CURRENT_TIMESTAMP(), error_message = NULL,
        diagnostics = OBJECT_INSERT(:V_DIAGNOSTICS::OBJECT, 'finish', OBJECT_CONSTRUCT(
            'pending_diagnoses', :V_PENDING, 'invalid_diagnoses', :V_INVALID, 'diagnosis_errors', :V_ERRORS,
            'pending_recommendations', :V_RECOMMENDATION_PENDING,
            'invalid_recommendations', :V_RECOMMENDATION_INVALID,
            'recommendation_errors', :V_RECOMMENDATION_ERRORS, 'needs_review', :V_NEEDS_REVIEW,
            'docs_unavailable', :V_DOCS_UNAVAILABLE, 'sampled_groups', :V_SAMPLED,
            'eligible_groups', :V_ELIGIBLE, 'omitted_groups', :V_OMITTED,
            'coverage', 'FOLLOWUP_PROXY_ONLY; COMPLETE_IS_PROCESSING_STATUS_NOT_AGENT_QUALITY'), TRUE)
    WHERE run_id = :P_RUN_ID AND status = 'RUNNING';
    RETURN V_STATUS;
END;
$$;

CREATE OR REPLACE PROCEDURE AF_RUN(
    P_WINDOW_START TIMESTAMP_LTZ, P_WINDOW_END TIMESTAMP_LTZ, P_THREAD_FILTER VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_RUN_ID VARCHAR DEFAULT UUID_STRING();
    V_STARTED BOOLEAN DEFAULT FALSE;
BEGIN
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_START_RUN(
        :V_RUN_ID, :P_WINDOW_START, :P_WINDOW_END, :P_THREAD_FILTER);
    V_STARTED := TRUE;
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'START');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CAPTURE_CONTEXT(:V_RUN_ID);
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'CAPTURE_CONTEXT_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_PREPARE_FEEDBACK(:V_RUN_ID);
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'PREPARE_FEEDBACK_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSE(:V_RUN_ID);
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'DIAGNOSE_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RECOMMEND(:V_RUN_ID);
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_FINISH(:V_RUN_ID);
    RETURN V_RUN_ID;
EXCEPTION
    WHEN OTHER THEN
        IF (V_STARTED) THEN
            UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
            SET status = 'FAILED', completed_at = CURRENT_TIMESTAMP(),
                error_message = 'Manual run failed; inspect stage and restricted task/query history.'
            WHERE run_id = :V_RUN_ID AND UPPER(status) IN ('RUNNING', 'FAILED');
        END IF;
        RAISE;
END;
$$;

CREATE TASK AF_START
    WAREHOUSE = __WAREHOUSE__
    CONFIG = '{}'
    OVERLAP_POLICY = NO_OVERLAP
    TASK_AUTO_RETRY_ATTEMPTS = 0
    AUTOCOMMIT = TRUE
AS
DECLARE
    V_REQUEST VARIANT;
    V_RUN_ID VARCHAR;
    V_START TIMESTAMP_LTZ;
    V_END TIMESTAMP_LTZ;
    V_THREAD VARCHAR;
    V_UNKNOWN INTEGER;
    E_CONFIG EXCEPTION (-20014, 'Task CONFIG accepts only window_start, window_end, thread_filter; timestamps must be ISO strings with an explicit offset.');
BEGIN
    V_REQUEST := PARSE_JSON(SYSTEM$GET_TASK_GRAPH_CONFIG()::VARCHAR);
    IF (NOT COALESCE(IS_OBJECT(V_REQUEST), FALSE)) THEN
        RAISE E_CONFIG;
    END IF;
    SELECT COUNT(*) INTO :V_UNKNOWN FROM TABLE(FLATTEN(INPUT => :V_REQUEST))
    WHERE key NOT IN ('window_start', 'window_end', 'thread_filter');
    IF (V_UNKNOWN > 0) THEN
        RAISE E_CONFIG;
    END IF;
    IF (V_REQUEST:window_start IS NOT NULL AND NOT IS_NULL_VALUE(V_REQUEST:window_start)) THEN
        IF (NOT IS_VARCHAR(V_REQUEST:window_start)
            OR NOT REGEXP_LIKE(V_REQUEST:window_start::VARCHAR,
                '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})')) THEN
            RAISE E_CONFIG;
        END IF;
        V_START := TRY_TO_TIMESTAMP_TZ(V_REQUEST:window_start::VARCHAR, 'AUTO')::TIMESTAMP_LTZ;
        IF (V_START IS NULL) THEN
            RAISE E_CONFIG;
        END IF;
    END IF;
    IF (V_REQUEST:window_end IS NOT NULL AND NOT IS_NULL_VALUE(V_REQUEST:window_end)) THEN
        IF (NOT IS_VARCHAR(V_REQUEST:window_end)
            OR NOT REGEXP_LIKE(V_REQUEST:window_end::VARCHAR,
                '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})')) THEN
            RAISE E_CONFIG;
        END IF;
        V_END := TRY_TO_TIMESTAMP_TZ(V_REQUEST:window_end::VARCHAR, 'AUTO')::TIMESTAMP_LTZ;
        IF (V_END IS NULL) THEN
            RAISE E_CONFIG;
        END IF;
    END IF;
    IF (V_REQUEST:thread_filter IS NOT NULL AND NOT IS_NULL_VALUE(V_REQUEST:thread_filter)) THEN
        IF (NOT IS_VARCHAR(V_REQUEST:thread_filter)) THEN
            RAISE E_CONFIG;
        END IF;
        V_THREAD := V_REQUEST:thread_filter::VARCHAR;
    END IF;
    V_RUN_ID := SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_START_RUN(:V_RUN_ID, :V_START, :V_END, :V_THREAD);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;

CREATE TASK AF_CAPTURE
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    AFTER AF_START
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('AF_START');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'START');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CAPTURE_CONTEXT(:V_RUN_ID);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;

CREATE TASK AF_PREPARE
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    AFTER AF_CAPTURE
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('AF_CAPTURE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'CAPTURE_CONTEXT_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_PREPARE_FEEDBACK(:V_RUN_ID);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;

CREATE TASK AF_DIAGNOSE
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    AFTER AF_PREPARE
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('AF_PREPARE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'PREPARE_FEEDBACK_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSE(:V_RUN_ID);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;

CREATE TASK AF_RECOMMEND
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    AFTER AF_DIAGNOSE
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('AF_DIAGNOSE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_ASSERT_STAGE(:V_RUN_ID, 'DIAGNOSE_COMPLETE');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RECOMMEND(:V_RUN_ID);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
EXCEPTION
    WHEN OTHER THEN
        UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
        SET status = 'FAILED', completed_at = CURRENT_TIMESTAMP(),
            error_message = 'Recommendation stage failed; inspect restricted task history.'
        WHERE run_id = :V_RUN_ID AND UPPER(status) IN ('RUNNING', 'FAILED');
        RAISE;
END;

CREATE TASK AF_FINISH
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    AFTER AF_RECOMMEND
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('AF_RECOMMEND');
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_FINISH(:V_RUN_ID);
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;

CREATE TASK AF_FINALIZE
    WAREHOUSE = __WAREHOUSE__
    AUTOCOMMIT = TRUE
    FINALIZE = AF_START
AS
DECLARE
    V_RUN_ID VARCHAR;
BEGIN
    V_RUN_ID := SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID');
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET status = 'FAILED', completed_at = CURRENT_TIMESTAMP(),
        error_message = 'Graph did not finish; inspect stage and restricted task history. No inference retried.'
    WHERE run_id = :V_RUN_ID AND UPPER(status) IN ('RUNNING', 'FAILED');
    CALL SYSTEM$SET_RETURN_VALUE(:V_RUN_ID);
END;