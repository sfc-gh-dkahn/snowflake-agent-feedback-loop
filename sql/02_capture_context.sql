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
--   3. Set the UTC window in REVIEW_SETTINGS, created by 00_setup.sql.
-- Use one agent per output schema. Select a role and warehouse that can read
-- that agent's events/settings and create and write these output tables.
-- Run 01_preflight.sql first and fix any invalid settings before continuing.
--
-- Run each statement in order and stop if one fails. The DESCRIBE ->> INSERT
-- chain is one statement: submit it separately, through its ending semicolon.
-- Do not run two copies at once. Each write commits separately with AUTOCOMMIT
-- enabled; this file does not roll back earlier successful statements on failure.
--
-- Capture needs only REVIEW_SETTINGS and the source agent, not later views.
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
-- This snapshot write is independent of the review window: it still saves if
-- REVIEW_SETTINGS is invalid. The event guard below does not undo this write.

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
-- thread_filter narrows reviews in 04, NOT capture. Filtering spans by thread
-- here would drop tool evidence. 03 rebuilds turns from the full saved history.
-- The window can still cut a turn at either edge; capture is not full coverage.
--
-- MERGE writes to AGENT_EVENTS. Existing rows are left untouched. Rerunning an
-- overlapping window picks up late events without duplicating identical ones.
-- Keep the window end at least 15 minutes in the past to allow for arrival lag.
-- Events can still arrive later or be missing; this is not a completeness promise.

MERGE INTO AGENT_EVENTS AS saved_events
USING (
    WITH settings_with_count AS (
        -- Count BEFORE filtering so extra invalid rows cannot hide a duplicate.
        SELECT REVIEW_SETTINGS.*, COUNT(*) OVER () AS settings_rows
        FROM REVIEW_SETTINGS
    ),

    valid_settings AS (
        -- Same full guard as preflight. Invalid settings select no events;
        -- read preflight's status to distinguish that from a valid empty window.
        SELECT review_start, review_end
        FROM settings_with_count
        WHERE settings_rows = 1
          AND settings_id = 1
          AND review_start < review_end
          AND review_end <= DATEADD('minute', -15, SYSDATE())
          AND review_end <= DATEADD('day', 90, review_start)
          AND (thread_filter IS NULL
               OR (LENGTH(TRIM(thread_filter, ' \t\r\n')) > 0 AND TRIM(thread_filter, ' \t\r\n') <> '0'))
          AND max_new_reviews BETWEEN 1 AND 100
          AND max_new_recommendations BETWEEN 1 AND 20
          AND min_occurrences BETWEEN 1 AND 1000
          AND docs_max_age_hours BETWEEN 1 AND 720
          AND LENGTH(TRIM(prompt_revision, ' \t\r\n')) > 0
    ),

    events_in_review_window AS (
        -- One row per recorded span. Use the agent-scoped function rather than
        -- reading the account-wide event table. Start is inclusive; end is not.
        -- Source timestamp is UTC NTZ, just like the settings window. Do not
        -- interpret it as session-local time through a direct LTZ cast.
        SELECT
            timestamp::TIMESTAMP_NTZ AS recorded_at,
            trace,
            record,
            record_attributes
        FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
            'AGENT_DB',
            'AGENT_SCHEMA',
            'AGENT_NAME',
            'CORTEX AGENT'
        ))
        JOIN valid_settings
          ON timestamp::TIMESTAMP_NTZ >= valid_settings.review_start
         AND timestamp::TIMESTAMP_NTZ < valid_settings.review_end
        WHERE record_type = 'SPAN'
          AND NULLIF(TRIM(trace:trace_id::VARCHAR, ' \t\r\n'), '') IS NOT NULL
    ),

    readable_events AS (
        -- Extract the useful fields from Snowflake's event JSON. These are still
        -- individual events, not complete question/answer pairs. NULL fields are
        -- expected: a tool event and a response event contain different details.
        -- Numeric epoch nanoseconds build LTZ from UTC, not the session zone;
        -- only its display changes with TIMEZONE. Keep all nine fractional digits.
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
        -- Keep the field order and numeric epoch nanoseconds stable between runs:
        -- no session timestamp format or display zone participates in this hash.
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

-- Next: 03_prepare_feedback.sql rebuilds turns from AGENT_EVENTS, preserving
-- incomplete turns before pairing adjacent complete turns in the same thread.
-- Answers without a complete adjacent follow-up stay unjudged.