-- =============================================================================
-- AGENT FEEDBACK LOOP: Check that a review is worth running
-- =============================================================================
-- Three reads, in order, so you can see whether there is anything to review
-- before a later script spends money:
--
--   1. REVIEW_SETTINGS            -> are the settings usable?
--   2. DESCRIBE AGENT             -> can this role read the agent?
--   3. GET_AI_OBSERVABILITY_EVENTS -> are there complete turns in the window?
--
-- Customize before running:
--   1. Replace OUTPUT_DB and AGENT_FEEDBACK with your output location.
--   2. Replace AGENT_DB, AGENT_SCHEMA, and AGENT_NAME everywhere in this file.
-- The review window and the thread filter are NOT edited here: they are read
-- from REVIEW_SETTINGS, so 00_setup.sql stays the one place that sets them.
--
-- This script writes nothing. It creates no tables, calls no AI, sends no
-- email, makes no schedule, and does not change the agent. The only session
-- change is the USE statements below. Run it as often as you like.
--
-- It does not read AGENT_EVENTS. Preflight runs BEFORE 02_capture_context.sql
-- has saved anything, so it reads the observability events directly at source.
--
-- There is no ok = true answer here any more. The old AF_PREFLIGHT procedure
-- returned one boolean; these queries return counts, and you read them. A
-- window with zero complete turns is a normal result, not a failure.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- =============================================================================
-- 0. PREREQUISITES & PRIVILEGES PROBE
-- =============================================================================
-- Run these probes to confirm your role has the necessary privileges and model
-- access BEFORE spending time configuring settings:
--
-- 1. Test Cortex AI function access and model availability:
SELECT SNOWFLAKE.CORTEX.AI_COMPLETE('claude-sonnet-4-6', 'Say OK') AS ai_probe;
-- If this fails with "Unknown function AI_COMPLETE", an ACCOUNTADMIN must grant:
--   GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE <your_role>;
--   GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <your_role>;

-- 2. Test Documentation Search Service access:
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
    '{"query":"Cortex Agent","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":1}') AS docs_probe;

-- =============================================================================
-- 1. ARE THE SETTINGS USABLE?
-- =============================================================================
-- The later scripts read exactly one settings row, keyed on settings_id = 1.
-- This repeats that check rather than assuming 00_setup.sql left it that way:
-- the row is editable, so it can have drifted since setup ran.
--
-- The bounds below are the same sanity bounds 00_setup.sql checks. They are
-- our own limits, not platform limits. This query covers REVIEW_SETTINGS only;
-- section 3 of 00_setup.sql also checks the eight CHANGE_AREAS rows.

WITH settings_state AS (
    -- Aggregate over the whole table, so this still returns a row when the
    -- table is empty -- which is itself one of the problems worth reporting.
    SELECT
        COUNT(*) AS settings_rows,
        COUNT(DISTINCT CASE WHEN settings_id = 1 THEN settings_id END)
            AS rows_keyed_one,
        MIN(review_start) AS review_start,
        MIN(review_end) AS review_end,
        MIN(max_new_reviews) AS max_new_reviews,
        MIN(max_new_recommendations) AS max_new_recommendations,
        MIN(min_occurrences) AS min_occurrences,
        MIN(docs_max_age_hours) AS docs_max_age_hours,
        MIN(LENGTH(TRIM(prompt_revision, ' \t\r\n'))) AS prompt_revision_length,
        -- NULL thread_filter means "all threads" and is fine. Present but
        -- blank once trimmed, or the string '0', is a configuration error:
        -- treating it as "all" would silently widen the run.
        COUNT(
            CASE
                WHEN thread_filter IS NOT NULL
                     AND (LENGTH(TRIM(thread_filter, ' \t\r\n')) = 0
                          OR TRIM(thread_filter, ' \t\r\n') = '0')
                THEN 1
            END
        ) AS unusable_thread_filters
    FROM REVIEW_SETTINGS
),

settings_checks AS (
    SELECT
        settings_state.*,
        settings_rows = 1 AND rows_keyed_one = 1 AS one_settings_row_keyed_one,
        review_start < review_end AS window_runs_forward,
        -- SYSDATE() is current UTC as TIMESTAMP_NTZ, the same convention
        -- review_end is stored in, so this compares like with like.
        -- CURRENT_TIMESTAMP() would drag the session time zone in.
        review_end <= DATEADD('minute', -15, SYSDATE()) AS window_end_settled,
        -- Exact elapsed time, not calendar days. DATEDIFF('day', ...) counts
        -- midnight boundaries crossed, so it would pass a window of 90 days
        -- plus 23 hours. Adding 90 days to the start is the real limit.
        review_end <= DATEADD('day', 90, review_start) AS window_span_sensible,
        unusable_thread_filters = 0 AS thread_filter_usable,
        max_new_reviews BETWEEN 1 AND 100 AS reviews_cap_sensible,
        max_new_recommendations BETWEEN 1 AND 20 AS recommendations_cap_sensible,
        min_occurrences BETWEEN 1 AND 1000 AS occurrences_sensible,
        docs_max_age_hours BETWEEN 1 AND 720 AS docs_age_sensible,
        prompt_revision_length > 0 AS prompt_revision_present
    FROM settings_state
)

SELECT
    settings_rows,
    review_start,
    review_end,
    CASE
        WHEN one_settings_row_keyed_one
             AND window_runs_forward
             AND window_end_settled
             AND window_span_sensible
             AND thread_filter_usable
             AND reviews_cap_sensible
             AND recommendations_cap_sensible
             AND occurrences_sensible
             AND docs_age_sensible
             AND prompt_revision_present
        THEN 'ready: settings look usable'
        ELSE 'stop: fix the failing check to the right'
    END AS settings_status,
    one_settings_row_keyed_one,
    window_runs_forward,
    window_end_settled,
    window_span_sensible,
    thread_filter_usable,
    reviews_cap_sensible,
    recommendations_cap_sensible,
    occurrences_sensible,
    docs_age_sensible,
    prompt_revision_present
FROM settings_checks;

-- =============================================================================
-- 2. CAN THIS ROLE READ THE AGENT?
-- =============================================================================
-- DESCRIBE takes a literal name, so the agent's three-part name is written out
-- here rather than read from a table. Replace all three parts.
--
-- Read the result yourself. What you want to see:
--   * The statement succeeds. An error here is an access or naming problem,
--     and no later script can work around it.
--   * Exactly one row comes back.
--   * agent_spec holds JSON, with the instructions and model you expect.
-- 02_capture_context.sql is what saves this into AGENT_SETTINGS_HISTORY;
-- nothing is stored by looking at it here.

DESCRIBE AGENT AGENT_DB.AGENT_SCHEMA.AGENT_NAME;

-- =============================================================================
-- 3. ARE THERE COMPLETE TURNS IN THE REVIEW WINDOW?
-- =============================================================================
-- A thread is a conversation. A trace is one agent turn. A span is part of that
-- turn, such as a tool call. Reviewing needs a complete turn: a question, an
-- answer, and the root span that ties them together.
--
-- This counts turns at source and saves nothing, so the counts show what is
-- available to collect -- not what has been collected.
--
-- Two honest limits on the counts below:
--   * The thread filter is applied by mapping each trace to the thread on its
--     root span, then keeping traces in the chosen thread. It is NOT applied by
--     filtering spans on thread_id: tool spans often carry no thread ID, so
--     filtering spans directly would throw away parts of the very turns you
--     want and undercount complete turns. A trace whose root carries no usable
--     thread ID cannot be matched to any thread, and is counted separately.
--   * Both the all-threads and the selected-thread counts are reported, so the
--     filter's effect is visible rather than assumed.

WITH settings_with_count AS (
    -- Count the whole table BEFORE any filtering. A count taken after the
    -- WHERE clause below would be a lie: three rows, two of them broken,
    -- would filter down to one good row and pass as a singleton. The count
    -- travels with every row so the next CTE can test it alongside the rest.
    SELECT
        settings_id,
        review_start,
        review_end,
        thread_filter,
        max_new_reviews,
        max_new_recommendations,
        min_occurrences,
        docs_max_age_hours,
        prompt_revision,
        COUNT(*) OVER () AS settings_rows
    FROM REVIEW_SETTINGS
),

valid_settings AS (
    -- The one row the later scripts read, returned only if the table holds
    -- exactly that row and it passes every check section 1 reports -- not
    -- just the ones that pick the window. If anything fails, this returns no
    -- rows, section 3 returns no row at all, and no half-valid configuration
    -- can steer a read. This is the same guard the paid steps must carry.
    SELECT
        review_start,
        review_end,
        thread_filter
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

recorded_spans AS (
    -- One row per recorded span for THIS agent. Use the agent-scoped function
    -- rather than the account-wide event table. Spans with no trace ID cannot
    -- be tied to a turn, so they are dropped here.
    --
    -- The event timestamp is already a UTC TIMESTAMP_NTZ, which is the same
    -- convention the settings columns use, so it is cast and compared as it
    -- stands. Do NOT wrap it in CONVERT_TIMEZONE('UTC', ...): the two-argument
    -- form reads its input as session-local time, so on any session that is
    -- not UTC it would shift an already-UTC value and review the wrong hours.
    --
    -- A thread ID that is blank or '0' is no thread ID. It is nulled here so
    -- one column means "unknown thread" everywhere below.
    --
    -- The two text flags below mark whether the text is usable as evidence.
    -- Blank, '1', 'null', and the redaction markers all mean "nothing to read
    -- here". Absent text does not prove the agent failed to answer.
    SELECT
        events.timestamp::TIMESTAMP_NTZ AS event_time_utc,
        events.trace:trace_id::VARCHAR AS trace_id,
        events.trace:span_id::VARCHAR AS span_id,
        events.record_attributes:"ai.observability.span_type"::VARCHAR AS span_type,
        NULLIF(
            NULLIF(TRIM(events.record_attributes:"snow.ai.observability.agent.thread_id"::VARCHAR, ' \t\r\n'), ''),
            '0'
        ) AS thread_id,
        COALESCE(
            LOWER(TRIM(events.record_attributes:"snow.ai.observability.agent.planning.query"::VARCHAR, ' \t\r\n'))
                NOT IN ('', '1', 'null', '[redacted]', '<redacted>', 'redacted'),
            FALSE
        ) AS question_is_usable,
        COALESCE(
            LOWER(TRIM(events.record_attributes:"snow.ai.observability.agent.response"::VARCHAR, ' \t\r\n'))
                NOT IN ('', '1', 'null', '[redacted]', '<redacted>', 'redacted'),
            FALSE
        ) AS answer_is_usable
    FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
        'AGENT_DB',
        'AGENT_SCHEMA',
        'AGENT_NAME',
        'CORTEX AGENT'
    )) AS events
    WHERE events.record_type = 'SPAN'
      AND NULLIF(TRIM(events.trace:trace_id::VARCHAR, ' \t\r\n'), '') IS NOT NULL
),

spans_in_window AS (
    -- Start inclusive, end exclusive, from the settings row.
    SELECT recorded_spans.*
    FROM recorded_spans
    JOIN valid_settings
      ON recorded_spans.event_time_utc >= valid_settings.review_start
     AND recorded_spans.event_time_utc <  valid_settings.review_end
),

trace_roots AS (
    -- One row per trace: its root span. The root's response is the agent's
    -- answer for the turn -- tool spans carry partial text, so they are not
    -- treated as the answer.
    --
    -- A trace should have one root. If it has more, the latest wins, and the
    -- ordering below keeps going until the two values this CTE actually
    -- projects are settled, so two roots recorded at the same instant cannot
    -- give different answers on different runs. NULLS LAST makes the missing
    -- values sort in a stated place rather than a default one.
    SELECT
        trace_id,
        thread_id AS root_thread_id,
        answer_is_usable AS root_answer_is_usable
    FROM spans_in_window
    WHERE span_type = 'record_root'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY trace_id
        ORDER BY
            event_time_utc DESC NULLS LAST,
            span_id DESC NULLS LAST,
            thread_id DESC NULLS LAST,
            answer_is_usable DESC,
            HASH(thread_id, answer_is_usable) DESC
    ) = 1
),

trace_questions AS (
    -- Which traces carry a usable question. Only existence matters here, so
    -- this does not pick a particular span or claim an order; the question
    -- text itself is not read at this stage.
    SELECT DISTINCT trace_id
    FROM spans_in_window
    WHERE question_is_usable
),

turns AS (
    -- Every trace seen in the window, with what it has and which thread its
    -- root claims. LEFT JOINs keep traces that are missing a root or text:
    -- those are the ones worth reporting, so they must not be filtered away.
    SELECT
        observed_traces.trace_id,
        trace_roots.root_thread_id,
        trace_roots.trace_id IS NOT NULL AS has_root,
        COALESCE(trace_roots.root_answer_is_usable, FALSE) AS has_answer,
        trace_questions.trace_id IS NOT NULL AS has_question
    FROM (SELECT DISTINCT trace_id FROM spans_in_window) AS observed_traces
    LEFT JOIN trace_roots
           ON trace_roots.trace_id = observed_traces.trace_id
    LEFT JOIN trace_questions
           ON trace_questions.trace_id = observed_traces.trace_id
)

-- Counted from the settings row outward, with a LEFT JOIN, so valid settings
-- over an empty window return one row of zeros rather than nothing at all.
-- "No traffic" and "unusable settings" are different answers and must not
-- look the same. Every count reads turns.trace_id or a flag, never the join
-- itself, so the placeholder row the LEFT JOIN supplies counts as nothing.
SELECT
    -- What the filter is, so the numbers are read in the right scope.
    COALESCE('thread ' || TRIM(valid_settings.thread_filter, ' \t\r\n'), 'all threads')
        AS thread_scope,
    valid_settings.review_start,
    valid_settings.review_end,

    -- Every trace in the window, whatever thread it belongs to.
    COUNT(turns.trace_id) AS traces_in_window,
    COALESCE(COUNT_IF(turns.has_root), 0) AS traces_with_root,
    COALESCE(COUNT_IF(NOT turns.has_root), 0) AS traces_missing_root,
    COALESCE(COUNT_IF(turns.has_question), 0) AS traces_with_usable_question,
    COALESCE(COUNT_IF(turns.has_answer), 0) AS traces_with_usable_answer,
    COALESCE(
        COUNT_IF(turns.has_root AND turns.has_question AND turns.has_answer),
        0
    ) AS complete_traces,

    -- Traces carrying no usable thread ID on their root, which includes the
    -- traces missing a root entirely. The thread filter cannot match these
    -- either way, so they are called out instead of silently dropped.
    COALESCE(
        COUNT_IF(turns.trace_id IS NOT NULL AND turns.root_thread_id IS NULL),
        0
    ) AS traces_without_thread_id,

    -- The same completeness count, narrowed to the chosen thread. With no
    -- filter set this equals complete_traces above.
    COALESCE(
        COUNT_IF(
            turns.has_root AND turns.has_question AND turns.has_answer
            AND (valid_settings.thread_filter IS NULL
                 OR turns.root_thread_id = TRIM(valid_settings.thread_filter, ' \t\r\n'))
        ),
        0
    ) AS complete_traces_in_scope,

    CASE
        WHEN COUNT_IF(
                 turns.has_root AND turns.has_question AND turns.has_answer
                 AND (valid_settings.thread_filter IS NULL
                      OR turns.root_thread_id = TRIM(valid_settings.thread_filter, ' \t\r\n'))
             ) > 0
        THEN 'complete turns found: there is something to review'
        ELSE 'no complete turns in scope: widen the window, clear the thread filter, or review the counts'
    END AS evidence_status
FROM valid_settings
LEFT JOIN turns ON TRUE
GROUP BY
    valid_settings.thread_filter,
    valid_settings.review_start,
    valid_settings.review_end;

-- Usable settings always return exactly one row here, even when every count is
-- zero. So no row at all means the settings guard rejected the row, not that
-- the agent had no traffic. Read section 1 to see which check failed.

-- What a good result here does NOT prove:
--   * Grants are complete. Reading the agent and its events says nothing about
--     writing the output tables, calling a model, or reading documentation.
--     Each later script proves its own access by running.
--   * The judging model is available to this account and role.
--   * The documentation search service exists or returns the expected columns.
--   * Events are complete. Events can arrive late or be missing, so these
--     counts are what is readable now, not everything that happened.

-- Next step: 02_capture_context.sql saves the agent settings and these events
-- into AGENT_SETTINGS_HISTORY and AGENT_EVENTS. It stores event_time as
-- TIMESTAMP_LTZ, so a later script comparing that SAVED column against the
-- settings window does need CONVERT_TIMEZONE('UTC', event_time)::TIMESTAMP_NTZ.
-- That conversion belongs to the saved LTZ column, not to the UTC NTZ
-- timestamp this script reads at source. Still no AI calls.

-- =============================================================================
-- 4. PROFILE AGENT ACTIVITY DISTRIBUTION (RECOMMENDED BEFORE CAPTURE)
-- =============================================================================
-- Agent traffic is often bursty. Run this query to inspect trace volume by day,
-- so you can set review_start and review_end in 00_setup.sql / REVIEW_SETTINGS
-- to a window that actually contains turns.

SELECT
    DATE_TRUNC('day', timestamp::TIMESTAMP_NTZ) AS trace_day,
    COUNT(DISTINCT trace:trace_id::VARCHAR) AS traces,
    COUNT(DISTINCT record_attributes:"snow.ai.observability.agent.thread_id"::VARCHAR) AS threads
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
    'AGENT_DB',
    'AGENT_SCHEMA',
    'AGENT_NAME',
    'CORTEX AGENT'
))
WHERE record_type = 'SPAN'
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;
