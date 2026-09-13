USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE OR REPLACE FUNCTION AF_TEXT_PRESENT(P_TEXT VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
    COALESCE(LOWER(TRIM(P_TEXT)) NOT IN
        ('', '1', 'null', '[redacted]', '<redacted>', 'redacted'), FALSE)
$$;

CREATE OR REPLACE PROCEDURE AF_READ_CONFIG()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_COUNT INTEGER;
    V_CONFIG VARIANT;
    V_HASH VARCHAR;
    E_CONFIG EXCEPTION (-20001, 'AF_CONFIG requires one valid, fully configured row; see preflight limits.');
BEGIN
    SELECT COUNT(*), ANY_VALUE(OBJECT_CONSTRUCT_KEEP_NULL(
        'config_id', config_id, 'agent_database', agent_database,
        'agent_schema', agent_schema, 'agent_name', agent_name,
        'judge_model', judge_model, 'docs_service', docs_service,
        'lookback_days', lookback_days, 'max_diagnoses', max_diagnoses,
        'max_recommendations', max_recommendations, 'min_occurrences', min_occurrences,
        'docs_cache_hours', docs_cache_hours, 'prompt_revision', prompt_revision))
    INTO :V_COUNT, :V_CONFIG
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CONFIG;

    IF (V_COUNT <> 1) THEN
        RAISE E_CONFIG;
    END IF;
    IF (NOT COALESCE(
        V_CONFIG:config_id::INTEGER = 1
        AND REGEXP_LIKE(V_CONFIG:agent_database::VARCHAR, '[A-Z_][A-Z0-9_$]{0,254}')
        AND REGEXP_LIKE(V_CONFIG:agent_schema::VARCHAR, '[A-Z_][A-Z0-9_$]{0,254}')
        AND REGEXP_LIKE(V_CONFIG:agent_name::VARCHAR, '[A-Z_][A-Z0-9_$]{0,254}')
        AND NOT CONTAINS(V_CONFIG:agent_database::VARCHAR, '__')
        AND NOT CONTAINS(V_CONFIG:agent_schema::VARCHAR, '__')
        AND NOT CONTAINS(V_CONFIG:agent_name::VARCHAR, '__')
        AND REGEXP_LIKE(V_CONFIG:judge_model::VARCHAR, '[A-Za-z0-9][A-Za-z0-9_.-]{0,127}')
        AND V_CONFIG:lookback_days::INTEGER BETWEEN 1 AND 90
        AND V_CONFIG:max_diagnoses::INTEGER BETWEEN 1 AND 100
        AND V_CONFIG:max_recommendations::INTEGER BETWEEN 1 AND 20
        AND V_CONFIG:min_occurrences::INTEGER BETWEEN 1 AND 1000
        AND V_CONFIG:docs_cache_hours::INTEGER BETWEEN 1 AND 720
        AND LENGTH(TRIM(V_CONFIG:prompt_revision::VARCHAR)) BETWEEN 1 AND 128
        AND NOT CONTAINS(V_CONFIG:prompt_revision::VARCHAR, '__')
        AND (IS_NULL_VALUE(V_CONFIG:docs_service)
             OR (REGEXP_LIKE(V_CONFIG:docs_service::VARCHAR,
                 '[A-Z_][A-Z0-9_$]{0,254}[.][A-Z_][A-Z0-9_$]{0,254}[.][A-Z_][A-Z0-9_$]{0,254}')
                 AND NOT CONTAINS(V_CONFIG:docs_service::VARCHAR, '__'))), FALSE)) THEN
        RAISE E_CONFIG;
    END IF;

    V_HASH := SHA2(TO_JSON(ARRAY_CONSTRUCT(
        V_CONFIG:config_id, V_CONFIG:agent_database, V_CONFIG:agent_schema,
        V_CONFIG:agent_name, V_CONFIG:judge_model, V_CONFIG:docs_service,
        V_CONFIG:lookback_days, V_CONFIG:max_diagnoses, V_CONFIG:max_recommendations,
        V_CONFIG:min_occurrences, V_CONFIG:docs_cache_hours, V_CONFIG:prompt_revision)), 256);
    RETURN OBJECT_INSERT(V_CONFIG::OBJECT, 'runtime_config_hash', V_HASH);
END;
$$;

CREATE OR REPLACE PROCEDURE AF_PREFLIGHT()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CONFIG VARIANT;
    V_DATABASE VARCHAR;
    V_SCHEMA VARCHAR;
    V_AGENT VARCHAR;
    V_SQL VARCHAR;
    V_QUERY_ID VARCHAR;
    V_STAGE VARCHAR DEFAULT 'CONFIG';
    V_START TIMESTAMP_NTZ;
    V_END TIMESTAMP_NTZ;
    V_SPEC_ROWS INTEGER;
    V_ROOTS INTEGER;
    V_USERS INTEGER;
    V_ANSWERS INTEGER;
    V_COMPLETE INTEGER;
BEGIN
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_READ_CONFIG() INTO :V_CONFIG;
    V_DATABASE := V_CONFIG:agent_database::VARCHAR;
    V_SCHEMA := V_CONFIG:agent_schema::VARCHAR;
    V_AGENT := V_CONFIG:agent_name::VARCHAR;
    V_END := CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ;
    V_START := DATEADD('day', -V_CONFIG:lookback_days::INTEGER, V_END);

    V_STAGE := 'AGENT_SPEC';
    V_SQL := 'DESCRIBE AGENT "' || V_DATABASE || '"."' || V_SCHEMA || '"."' || V_AGENT || '"';
    EXECUTE IMMEDIATE :V_SQL;
    V_QUERY_ID := SQLID;
    SELECT COALESCE(COUNT_IF(IS_OBJECT(TRY_PARSE_JSON("agent_spec"::VARCHAR))), 0)
    INTO :V_SPEC_ROWS FROM TABLE(RESULT_SCAN(:V_QUERY_ID));

    V_STAGE := 'TELEMETRY';
    V_SQL := 'SELECT trace:trace_id::VARCHAR AS trace_id,
        record_attributes:"ai.observability.span_type"::VARCHAR AS span_type,
        record_attributes:"snow.ai.observability.agent.planning.query"::VARCHAR AS user_message,
        record_attributes:"snow.ai.observability.agent.response"::VARCHAR AS agent_response
        FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(?, ?, ?, ''CORTEX AGENT''))
        WHERE timestamp >= ? AND timestamp < ? AND record_type = ''SPAN''';
    EXECUTE IMMEDIATE :V_SQL USING (V_DATABASE, V_SCHEMA, V_AGENT, V_START, V_END);
    V_QUERY_ID := SQLID;
    SELECT COALESCE(COUNT_IF(has_root), 0), COALESCE(COUNT_IF(has_user), 0),
           COALESCE(COUNT_IF(has_answer), 0),
           COALESCE(COUNT_IF(has_root AND has_user AND has_answer), 0)
    INTO :V_ROOTS, :V_USERS, :V_ANSWERS, :V_COMPLETE
    FROM (
        SELECT trace_id, BOOLOR_AGG(span_type = 'record_root') AS has_root,
            BOOLOR_AGG(__OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TEXT_PRESENT(user_message)) AS has_user,
            BOOLOR_AGG(span_type = 'record_root'
                AND __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_TEXT_PRESENT(agent_response)) AS has_answer
        FROM TABLE(RESULT_SCAN(:V_QUERY_ID))
        WHERE NULLIF(TRIM(trace_id), '') IS NOT NULL
        GROUP BY trace_id
    );
    RETURN OBJECT_CONSTRUCT(
        'ok', V_SPEC_ROWS = 1 AND V_COMPLETE > 0,
        'config_readable', TRUE, 'agent_spec_readable', V_SPEC_ROWS = 1,
        'root_traces', V_ROOTS, 'user_message_traces', V_USERS,
        'answer_traces', V_ANSWERS, 'complete_traces', V_COMPLETE,
        'lookback_days', V_CONFIG:lookback_days,
        'limits', OBJECT_CONSTRUCT('lookback_days_max', 90, 'max_diagnoses_max', 100,
            'max_recommendations_max', 20, 'min_occurrences_max', 1000,
            'docs_cache_hours_max', 720, 'prior_turns_max', 6),
        'inference_performed', FALSE,
        'reason', IFF(V_SPEC_ROWS = 1 AND V_COMPLETE > 0, 'READABLE_EVIDENCE_FOUND',
            'REQUIRED_READABLE_EVIDENCE_NOT_OBSERVED; CAUSE_NOT_INFERRED'));
EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'stage', V_STAGE,
            'sqlstate', SQLSTATE, 'sqlcode', SQLCODE,
            'reason', 'PREFLIGHT_CHECK_FAILED; NO_CONTENT_RETURNED', 'inference_performed', FALSE);
END;
$$;