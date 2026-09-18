-- =============================================================================
-- AGENT FEEDBACK LOOP: Collect the evidence
-- =============================================================================
-- Read the agent's current settings and conversation events, then save them:
--
--   DESCRIBE AGENT                -> AGENT_SETTINGS_HISTORY
--   GET_AI_OBSERVABILITY_EVENTS   -> AGENT_EVENTS
--
-- Customize before running:
--   1. Replace OUTPUT_DB and AGENT_FEEDBACK with an existing output location.
--   2. Replace AGENT_DB, AGENT_SCHEMA, and AGENT_NAME everywhere in this file.
--   3. Change the two UTC dates in events_in_review_window below.
-- Use one agent per output schema. Select a role and warehouse that can read
-- that agent's events/settings and create and write these output tables.
--
-- Run each statement in order and stop if one fails. The DESCRIBE ->> INSERT
-- chain is one statement: submit it separately, through its ending semicolon.
-- Do not run two copies at once. Each write commits separately with AUTOCOMMIT
-- enabled; this file does not roll back earlier successful statements on failure.
--
-- This is the first plain-SQL pilot. It does not use the old AF_* objects or
-- procedures. The other numbered scripts are not yet adapted to these tables.
-- No AI calls, emails, schedules, or changes to the agent happen here.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- =============================================================================
-- 1. CREATE THE DESTINATION TABLES
-- =============================================================================
-- Settings history: one row each time we read the agent's current configuration.
-- Keep older snapshots rather than overwriting them when the agent changes.
-- IF NOT EXISTS preserves saved data on reruns; it does not upgrade old schemas.

CREATE TABLE IF NOT EXISTS AGENT_SETTINGS_HISTORY (
    snapshot_id          VARCHAR NOT NULL,
    captured_at          TIMESTAMP_LTZ NOT NULL,
    agent_database       VARCHAR NOT NULL,
    agent_schema         VARCHAR NOT NULL,
    agent_name           VARCHAR NOT NULL,
    agent_specification  VARIANT NOT NULL
);

-- Events: one row per distinct event collected for the agent.
-- A thread is a conversation. A trace is one agent turn. A span is part of that
-- turn, such as a tool call. The next script will combine spans into full turns.

CREATE TABLE IF NOT EXISTS AGENT_EVENTS (
    event_hash       VARCHAR NOT NULL,
    agent_database   VARCHAR NOT NULL,
    agent_schema     VARCHAR NOT NULL,
    agent_name       VARCHAR NOT NULL,
    event_time       TIMESTAMP_LTZ NOT NULL,
    trace_id         VARCHAR NOT NULL,
    span_id          VARCHAR,
    span_name        VARCHAR,
    span_type        VARCHAR,
    thread_id        VARCHAR,
    message_id       VARCHAR,
    user_question    VARCHAR,
    agent_answer     VARCHAR,
    tool_name        VARCHAR,
    executed_sql     VARCHAR,
    chart_definition VARCHAR,
    status_code      VARCHAR,
    first_saved_at   TIMESTAMP_LTZ NOT NULL
);

-- =============================================================================
-- 2. SAVE THE AGENT'S CURRENT SETTINGS
-- =============================================================================
-- DESCRIBE reads settings; INSERT saves them. The ->> passes the DESCRIBE result
-- directly to the INSERT query. FROM $1 means "read the preceding result."
-- This is a SQL result reference, not a variable you need to set.
--
-- These settings describe the agent NOW. They do not prove which instructions
-- or model produced older answers. Every execution adds a dated snapshot,
-- even if the settings have not changed. No snapshot is treated as a run ID.

DESCRIBE AGENT AGENT_DB.AGENT_SCHEMA.AGENT_NAME
    ->> INSERT INTO AGENT_SETTINGS_HISTORY (
        snapshot_id,
        captured_at,
        agent_database,
        agent_schema,
        agent_name,
        agent_specification
    )
    SELECT
        UUID_STRING(),
        CURRENT_TIMESTAMP(),
        "database_name",
        "schema_name",
        "name",
        PARSE_JSON("agent_spec"::VARCHAR)
    FROM $1;

-- Inspect the snapshot before collecting events. The full configuration stays
-- in agent_specification; these columns show the instructions and model directly.

SELECT
    captured_at,
    agent_name,
    agent_specification:instructions:response::VARCHAR AS response_instructions,
    agent_specification:instructions:orchestration::VARCHAR AS orchestration_instructions,
    agent_specification:models:orchestration::VARCHAR AS orchestration_model
FROM AGENT_SETTINGS_HISTORY
ORDER BY captured_at DESC, snapshot_id
LIMIT 1;

-- =============================================================================
-- 3. READ EVENTS, GIVE THEM CLEAR COLUMN NAMES, AND SAVE ONLY NEW ROWS
-- =============================================================================
-- This reads all conversations for ONE agent in the selected window. Keep tool
-- events even when they have no thread ID; their trace ID links them to a turn.
-- Conversation filtering belongs after those links have been rebuilt.
--
-- MERGE writes to AGENT_EVENTS. Existing rows are left untouched. Rerunning an
-- overlapping window picks up late events without duplicating identical ones.
-- Keep the window end at least 15 minutes in the past to allow for arrival lag.
-- Events can still arrive later or be missing; this is not a completeness promise.

MERGE INTO AGENT_EVENTS AS saved_events
USING (
    WITH events_in_review_window AS (
        -- One row per recorded span. Use the agent-scoped function rather than
        -- reading the account-wide event table. Start is inclusive; end is not.
        -- The dates below are UTC examples: replace both before running.
        SELECT
            timestamp AS recorded_at,
            trace,
            record,
            record_attributes
        FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
            'AGENT_DB',
            'AGENT_SCHEMA',
            'AGENT_NAME',
            'CORTEX AGENT'
        ))
        WHERE timestamp >= '2026-09-01 00:00:00'::TIMESTAMP_NTZ
          AND timestamp < '2026-09-02 00:00:00'::TIMESTAMP_NTZ
          AND record_type = 'SPAN'
          AND NULLIF(TRIM(trace:trace_id::VARCHAR), '') IS NOT NULL
    ),

    readable_events AS (
        -- Extract the useful fields from Snowflake's event JSON. These are still
        -- individual events, not complete question/answer pairs. NULL fields are
        -- expected: a tool event and a response event contain different details.
        SELECT
            'AGENT_DB' AS agent_database,
            'AGENT_SCHEMA' AS agent_schema,
            'AGENT_NAME' AS agent_name,
            TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, recorded_at), 9) AS event_time,
            trace:trace_id::VARCHAR AS trace_id,
            trace:span_id::VARCHAR AS span_id,
            record:name::VARCHAR AS span_name,
            record_attributes:"ai.observability.span_type"::VARCHAR AS span_type,
            record_attributes:"snow.ai.observability.agent.thread_id"::VARCHAR AS thread_id,
            record_attributes:"snow.ai.observability.agent.message_id"::VARCHAR AS message_id,
            record_attributes:"snow.ai.observability.agent.planning.query"::VARCHAR AS user_question,
            record_attributes:"snow.ai.observability.agent.response"::VARCHAR AS agent_answer,
            record_attributes:"snow.ai.observability.agent.planning.tool_execution.name"::VARCHAR AS tool_name,
            record_attributes:"snow.ai.observability.agent.tool.sql_execution.final_sql"::VARCHAR AS executed_sql,
            record_attributes:"snow.ai.observability.agent.tool.chart_generation.input_chart_spec"::VARCHAR AS chart_definition,
            record_attributes:"snow.ai.observability.agent.status.code"::VARCHAR AS status_code
        FROM events_in_review_window
    ),

    events_with_identifiers AS (
        -- Hash the agent identity and selected fields to recognize repeat rows.
        -- Keep the field order and timestamp precision stable between runs.
        -- Changes to these fields produce a new row rather than replacing evidence.
        SELECT
            readable_events.*,
            SHA2(TO_JSON(ARRAY_CONSTRUCT(
                agent_database,
                agent_schema,
                agent_name,
                DATE_PART(epoch_nanosecond, event_time),
                trace_id,
                span_id,
                span_name,
                span_type,
                thread_id,
                message_id,
                user_question,
                agent_answer,
                tool_name,
                executed_sql,
                chart_definition,
                status_code
            )), 256) AS event_hash
        FROM readable_events
    )

    -- Keep one copy within this batch. MERGE then skips copies already stored.
    -- This result has the same column names as AGENT_EVENTS, including save time.
    SELECT
        events_with_identifiers.*,
        CURRENT_TIMESTAMP() AS first_saved_at
    FROM events_with_identifiers
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY event_hash
        ORDER BY event_time, trace_id
    ) = 1
) AS collected_events
    ON saved_events.event_hash = collected_events.event_hash
   AND saved_events.agent_database = collected_events.agent_database
   AND saved_events.agent_schema = collected_events.agent_schema
   AND saved_events.agent_name = collected_events.agent_name
WHEN NOT MATCHED THEN INSERT ALL BY NAME;

-- ALL BY NAME above matches the query's columns to table columns by name, not
-- position. There is no UPDATE branch: previously saved events remain unchanged.

-- =============================================================================
-- 4. INSPECT THE SAVED EVIDENCE
-- =============================================================================
-- Counts include earlier collections, not just the latest window. A repeat run
-- can insert zero new events because the same evidence is already stored.

SELECT
    agent_database,
    agent_schema,
    agent_name,
    COUNT(*) AS saved_events,
    COUNT(DISTINCT trace_id) AS recorded_turns,
    MIN(event_time) AS earliest_event,
    MAX(event_time) AS latest_event
FROM AGENT_EVENTS
GROUP BY agent_database, agent_schema, agent_name;

-- Read a small sample. Some text may be redacted or absent in the source; NULL
-- does not prove the agent failed to answer. Treat stored conversation text as
-- sensitive and review it before sharing query results.

SELECT
    event_time,
    thread_id,
    trace_id,
    span_name,
    user_question,
    agent_answer,
    tool_name
FROM AGENT_EVENTS
ORDER BY event_time DESC, trace_id, event_hash
LIMIT 20;

-- Next step: rebuild complete conversation turns from AGENT_EVENTS, then pair
-- each answer with its next user message. That script will be revised after
-- this pilot's structure and naming have been reviewed.