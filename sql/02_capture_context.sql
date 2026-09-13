USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE OR REPLACE PROCEDURE AF_CAPTURE_CONTEXT(P_RUN_ID VARCHAR)
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
    V_SQL VARCHAR;
    V_QUERY_ID VARCHAR;
    V_SPEC VARIANT;
    V_SPEC_HASH VARCHAR;
    V_CONFIG_HASH VARCHAR;
    V_COUNT INTEGER;
    V_START TIMESTAMP_LTZ;
    V_END TIMESTAMP_LTZ;
    V_START_UTC TIMESTAMP_NTZ;
    V_END_UTC TIMESTAMP_NTZ;
    V_THREAD VARCHAR;
    V_STATUS VARCHAR;
    V_SNAPSHOT_COUNT INTEGER;
    V_EXISTING_HASH VARCHAR;
    V_INSERTED INTEGER;
    V_STAGE VARCHAR DEFAULT 'CAPTURE_CONTEXT';
    V_RUN_FOUND BOOLEAN DEFAULT FALSE;
    V_IN_TRANSACTION BOOLEAN DEFAULT FALSE;
    V_ERROR VARCHAR;
    E_RUN EXCEPTION (-20002, 'Capture requires a sole unfinished run, a valid bounded window, and no caller transaction.');
    E_SPEC EXCEPTION (-20003, 'Agent specification is unreadable or changed for this run; use a new run for changed configuration.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL) THEN
        RAISE E_RUN;
    END IF;
    SELECT COUNT(*), ANY_VALUE(window_start), ANY_VALUE(window_end),
           ANY_VALUE(thread_filter), ANY_VALUE(status)
    INTO :V_COUNT, :V_START, :V_END, :V_THREAD, :V_STATUS
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS WHERE run_id = :P_RUN_ID;
    IF (V_COUNT <> 1 OR NULLIF(TRIM(P_RUN_ID), '') IS NULL
        OR NOT COALESCE(V_STATUS IN ('PENDING', 'RUNNING', 'FAILED'), FALSE)) THEN
        RAISE E_RUN;
    END IF;
    V_RUN_FOUND := TRUE;
    CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_READ_CONFIG() INTO :V_CONFIG;
    V_DATABASE := V_CONFIG:agent_database::VARCHAR;
    V_SCHEMA := V_CONFIG:agent_schema::VARCHAR;
    V_AGENT := V_CONFIG:agent_name::VARCHAR;
    IF (NOT COALESCE(V_STATUS IN ('PENDING', 'RUNNING', 'FAILED')
        AND V_START < V_END AND V_END <= CURRENT_TIMESTAMP()
        AND V_START >= DATEADD('day', -V_CONFIG:lookback_days::INTEGER, V_END)
        AND (V_THREAD IS NULL OR (LENGTH(TRIM(V_THREAD)) BETWEEN 1 AND 256
             AND V_THREAD = TRIM(V_THREAD) AND V_THREAD <> '0')), FALSE)) THEN
        RAISE E_RUN;
    END IF;
    V_START_UTC := CONVERT_TIMEZONE('UTC', V_START)::TIMESTAMP_NTZ;
    V_END_UTC := CONVERT_TIMEZONE('UTC', V_END)::TIMESTAMP_NTZ;
    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET status = 'RUNNING', stage = :V_STAGE, completed_at = NULL, error_message = NULL
    WHERE run_id = :P_RUN_ID;
    COMMIT;
    V_IN_TRANSACTION := FALSE;

    V_STAGE := 'CAPTURE_AGENT_SPEC';
    V_SQL := 'DESCRIBE AGENT "' || V_DATABASE || '"."' || V_SCHEMA || '"."' || V_AGENT || '"';
    EXECUTE IMMEDIATE :V_SQL;
    V_QUERY_ID := SQLID;
    SELECT COUNT(*), ANY_VALUE(TRY_PARSE_JSON("agent_spec"::VARCHAR))
    INTO :V_COUNT, :V_SPEC FROM TABLE(RESULT_SCAN(:V_QUERY_ID));
    IF (V_COUNT <> 1 OR NOT COALESCE(IS_OBJECT(V_SPEC), FALSE)) THEN
        RAISE E_SPEC;
    END IF;
    SELECT SHA2(TO_JSON(ARRAY_AGG(ARRAY_CONSTRUCT(path, TYPEOF(value),
            IFF(IS_OBJECT(value) OR IS_ARRAY(value), NULL, TO_JSON(value))))
        WITHIN GROUP (ORDER BY path, TYPEOF(value),
            IFF(IS_OBJECT(value) OR IS_ARRAY(value), NULL, TO_JSON(value)))), 256)
    INTO :V_SPEC_HASH FROM TABLE(FLATTEN(INPUT => :V_SPEC, RECURSIVE => TRUE));
    V_CONFIG_HASH := SHA2(TO_JSON(ARRAY_CONSTRUCT(V_DATABASE, V_SCHEMA, V_AGENT,
        V_SPEC_HASH, V_CONFIG:runtime_config_hash)), 256);
    SELECT COUNT(*), ANY_VALUE(config_hash)
    INTO :V_SNAPSHOT_COUNT, :V_EXISTING_HASH
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CONFIG_SNAPSHOTS WHERE run_id = :P_RUN_ID;
    IF (V_SNAPSHOT_COUNT > 1 OR (V_SNAPSHOT_COUNT = 1 AND V_EXISTING_HASH <> V_CONFIG_HASH)) THEN
        RAISE E_SPEC;
    END IF;

    V_STAGE := 'CAPTURE_EVENTS';
    V_SQL := 'SELECT TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, timestamp), 9) AS event_ts,
        trace:trace_id::VARCHAR AS trace_id, trace:span_id::VARCHAR AS span_id,
        record:name::VARCHAR AS span_name,
        record_attributes:"ai.observability.span_type"::VARCHAR AS span_type,
        record_attributes:"snow.ai.observability.agent.thread_id"::VARCHAR AS thread_id,
        record_attributes:"snow.ai.observability.agent.message_id"::VARCHAR AS message_id,
        record_attributes:"snow.ai.observability.agent.planning.query"::VARCHAR AS user_message,
        record_attributes:"snow.ai.observability.agent.response"::VARCHAR AS agent_response,
        record_attributes:"snow.ai.observability.agent.planning.tool_execution.name"::VARCHAR AS tool_name,
        record_attributes:"snow.ai.observability.agent.tool.sql_execution.final_sql"::VARCHAR AS final_sql,
        record_attributes:"snow.ai.observability.agent.tool.chart_generation.input_chart_spec"::VARCHAR AS chart_spec,
        record_attributes:"snow.ai.observability.agent.status.code"::VARCHAR AS status_code
        FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(?, ?, ?, ''CORTEX AGENT''))
        WHERE timestamp >= ? AND timestamp < ? AND record_type = ''SPAN''
          AND NULLIF(TRIM(trace:trace_id::VARCHAR), '''') IS NOT NULL';
    EXECUTE IMMEDIATE :V_SQL USING (V_DATABASE, V_SCHEMA, V_AGENT, V_START_UTC, V_END_UTC);
    V_QUERY_ID := SQLID;

    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    MERGE INTO __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_EVENTS AS archived
    USING (
        WITH bounded AS (
            SELECT *, SHA2(TO_JSON(ARRAY_CONSTRUCT(:V_DATABASE, :V_SCHEMA, :V_AGENT,
                DATE_PART(epoch_nanosecond, event_ts), trace_id, span_id, span_name, span_type,
                thread_id, message_id, user_message, agent_response, tool_name, final_sql,
                chart_spec, status_code)), 256) AS event_hash
            FROM TABLE(RESULT_SCAN(:V_QUERY_ID))
        ), roots AS (
            SELECT trace_id, thread_id, event_ts, span_id, event_hash
            FROM bounded WHERE span_type = 'record_root'
            UNION ALL
            SELECT trace_id, thread_id, event_ts, span_id, event_hash
            FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_EVENTS
            WHERE agent_database = :V_DATABASE AND agent_schema = :V_SCHEMA AND agent_name = :V_AGENT
              AND span_type = 'record_root'
        ), selected_traces AS (
            SELECT trace_id, thread_id FROM roots
            QUALIFY ROW_NUMBER() OVER (PARTITION BY trace_id
                ORDER BY event_ts DESC, span_id DESC NULLS LAST, event_hash DESC) = 1
        )
        SELECT bounded.* FROM bounded
        WHERE :V_THREAD IS NULL OR trace_id IN
            (SELECT trace_id FROM selected_traces WHERE thread_id = :V_THREAD)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY event_hash ORDER BY event_ts, trace_id) = 1
    ) AS incoming
    ON archived.event_hash = incoming.event_hash
       AND archived.agent_database = :V_DATABASE
       AND archived.agent_schema = :V_SCHEMA AND archived.agent_name = :V_AGENT
    WHEN NOT MATCHED THEN INSERT (
        event_hash, agent_database, agent_schema, agent_name, event_ts, trace_id,
        span_id, span_name, span_type, thread_id, message_id, user_message, agent_response,
        tool_name, final_sql, chart_spec, status_code, first_seen_at)
    VALUES (incoming.event_hash, :V_DATABASE, :V_SCHEMA, :V_AGENT, incoming.event_ts,
        incoming.trace_id, incoming.span_id, incoming.span_name, incoming.span_type,
        incoming.thread_id, incoming.message_id, incoming.user_message, incoming.agent_response,
        incoming.tool_name, incoming.final_sql, incoming.chart_spec, incoming.status_code, CURRENT_TIMESTAMP());
    V_INSERTED := SQLROWCOUNT;

    IF (V_SNAPSHOT_COUNT = 0) THEN
        INSERT INTO __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_CONFIG_SNAPSHOTS
            (run_id, agent_database, agent_schema, agent_name, captured_at, config_hash, agent_spec)
        SELECT :P_RUN_ID, :V_DATABASE, :V_SCHEMA, :V_AGENT, CURRENT_TIMESTAMP(), :V_CONFIG_HASH, :V_SPEC;
    END IF;
    DELETE FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK WHERE run_id = :P_RUN_ID;
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    SET stage = 'CAPTURE_CONTEXT_COMPLETE', diagnostics = OBJECT_CONSTRUCT(
        'capture', OBJECT_CONSTRUCT('events_inserted', :V_INSERTED,
            'runtime_config_hash', :V_CONFIG:runtime_config_hash,
            'window_start_epoch_ns', DATE_PART(epoch_nanosecond, :V_START),
            'window_end_epoch_ns', DATE_PART(epoch_nanosecond, :V_END),
            'thread_filter_hash', SHA2(TO_JSON(ARRAY_CONSTRUCT(:V_THREAD)), 256),
            'spec_is_capture_time_only', TRUE)), error_message = NULL
    WHERE run_id = :P_RUN_ID;
    COMMIT;
    V_IN_TRANSACTION := FALSE;
    RETURN 'CAPTURE_CONTEXT_COMPLETE';
EXCEPTION
    WHEN OTHER THEN
        V_ERROR := 'Capture failed; SQLSTATE=' || SQLSTATE || '; SQLCODE=' || SQLCODE::VARCHAR;
        IF (V_IN_TRANSACTION) THEN
            ROLLBACK;
        END IF;
        IF (V_RUN_FOUND) THEN
            BEGIN
                BEGIN TRANSACTION;
                UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
                SET status = 'FAILED', stage = :V_STAGE, completed_at = CURRENT_TIMESTAMP(),
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