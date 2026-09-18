-- =============================================================================
-- AGENT FEEDBACK LOOP: Set the review settings
-- =============================================================================
-- Create the two small reference tables the later scripts read:
--
--   REVIEW_SETTINGS  -> which time window to review, and the work limits
--   CHANGE_AREAS     -> the eight review categories a suggestion may address
--
-- Customize before running:
--   1. Replace OUTPUT_DB and AGENT_FEEDBACK with an existing output location.
--   2. Change the two UTC dates in the REVIEW_SETTINGS seed below.
--   3. Set thread_filter to one thread ID for a first small run, or leave NULL.
-- Select a role and warehouse that can create and write tables here.
--
-- Run each statement in order and stop if one fails. Each write commits
-- separately with AUTOCOMMIT enabled; this file does not roll back earlier
-- successful statements on failure. Do not run two copies at once.
--
-- This script does not read the agent, call AI, send email, create a schedule,
-- or change the agent. It writes only these two tables.
--
-- It also does NOT create AGENT_SETTINGS_HISTORY or AGENT_EVENTS. Those belong
-- to 02_capture_context.sql, which owns their definitions and holds the saved
-- evidence. Defining them twice would risk overwriting collected events.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- =============================================================================
-- 1. THE REVIEW SETTINGS TABLE
-- =============================================================================
-- One row. Later scripts join to it instead of repeating these numbers, so the
-- window and the limits are edited in one readable place.
--
-- What this table does NOT hold: the output location, the agent name, the
-- judging model, and the documentation search service. Those stay written as
-- literals at the point of use.
--
-- Two different reasons sit behind that, and they are worth keeping apart:
--   * The documentation search function accepts only literal arguments, so a
--     service name stored here could not be passed to it without dynamic SQL.
--     That one is a hard limit.
--   * The judging model is a readability choice, not a limit. A model name is
--     an ordinary string and could be read from a table; we keep it beside the
--     call so a reader sees which model runs where, and so this table does not
--     look like it decides what the AI steps do.
-- Object names stay literal for the same readability reason.
--
-- IF NOT EXISTS preserves your edited settings on reruns; it does not upgrade
-- an older table's columns. If you are adopting a newer version of this script
-- and the columns differ, migrate deliberately: read the existing row, decide
-- what each old value becomes, and keep a copy before you change anything.
-- These are your operating settings, so treat replacing the table as a planned
-- edit rather than a quick fix.

CREATE TABLE IF NOT EXISTS REVIEW_SETTINGS (
    -- Always 1. A second row is a configuration error, not a second profile:
    -- the later scripts read one row and cannot choose between two. Any other
    -- value is also wrong, because the later scripts look for 1.
    settings_id              INTEGER NOT NULL,

    -- The review window, in UTC, to match the recorded event timestamps.
    -- Start is inclusive, end is exclusive. TIMESTAMP_NTZ carries no time zone,
    -- so '00:00:00' is midnight UTC only because this project agrees to read
    -- these two columns as UTC. Nothing in the type enforces that convention.
    --
    -- AGENT_EVENTS.event_time is TIMESTAMP_LTZ, which does carry a zone and
    -- displays in the session's time zone. Do not compare it to these columns
    -- directly: convert it first, in the query that does the comparison, with
    --   CONVERT_TIMEZONE('UTC', event_time)::TIMESTAMP_NTZ
    -- Comparing the raw LTZ value silently shifts the window by the session
    -- offset, which quietly reviews the wrong hours instead of failing.
    --
    -- Keep review_end at least 15 minutes before the current UTC clock so
    -- late-arriving events are not cut off mid-window.
    review_start             TIMESTAMP_NTZ NOT NULL,
    review_end               TIMESTAMP_NTZ NOT NULL,

    -- One conversation thread ID, or NULL for every thread in the window.
    -- Set a single thread for a first run to keep the evidence small. NULL is
    -- the way to say "all threads"; an empty string or '0' is not, and the
    -- status query in section 3 reports either as a configuration error.
    thread_filter            VARCHAR,

    -- Caps on NEW paid AI calls only. They do not cap how much evidence is
    -- counted as eligible: work over the cap is deferred, not discarded, and a
    -- later run can pick it up. They also do not cap tokens or total credits.
    max_new_reviews          INTEGER NOT NULL,
    max_new_recommendations  INTEGER NOT NULL,

    -- How many separate poor answers in one change area before that area is
    -- worth a suggestion. Guards against acting on a single complaint.
    min_occurrences          INTEGER NOT NULL,

    -- How old saved documentation may be before it is retrieved again. This
    -- measures when we fetched the text, not when Snowflake published it.
    docs_max_age_hours       INTEGER NOT NULL,

    -- Names the prompt and output shape used for AI results. Change it to redo
    -- judging deliberately: saved results are never overwritten, so a new
    -- revision produces new rows beside the old ones and costs new calls.
    prompt_revision          VARCHAR NOT NULL
);

-- Seed the single row. WHERE NOT EXISTS means a rerun of this file leaves your
-- edited settings alone instead of resetting them to these defaults. To change
-- a setting later, UPDATE the row; do not INSERT a second one.
-- The dates below are UTC examples: replace both before running.

INSERT INTO REVIEW_SETTINGS (
    settings_id,
    review_start,
    review_end,
    thread_filter,
    max_new_reviews,
    max_new_recommendations,
    min_occurrences,
    docs_max_age_hours,
    prompt_revision
)
SELECT
    1,
    '2026-09-01 00:00:00'::TIMESTAMP_NTZ,
    '2026-09-02 00:00:00'::TIMESTAMP_NTZ,
    CAST(NULL AS VARCHAR),
    20,
    5,
    2,
    168,
    '2'
WHERE NOT EXISTS (SELECT 1 FROM REVIEW_SETTINGS);

-- Read back what is actually stored, including the window length, so the scope
-- is visible before any later script spends money on it.

SELECT
    settings_id,
    review_start,
    review_end,
    DATEDIFF('hour', review_start, review_end) AS review_window_hours,
    COALESCE(thread_filter, 'all threads') AS threads_reviewed,
    max_new_reviews,
    max_new_recommendations,
    min_occurrences,
    docs_max_age_hours,
    prompt_revision
FROM REVIEW_SETTINGS
ORDER BY settings_id;

-- =============================================================================
-- 2. THE CHANGE AREAS TABLE
-- =============================================================================
-- One row per part of the agent a suggestion is allowed to address. A review
-- names one of these area keys, and documentation retrieval uses that area's
-- query to look up the official guidance for it.
--
-- These eight keys are the review categories this project supports. They are
-- not a map of the agent specification: some read like a path into it, such as
-- 'instructions.response' for agent_specification:instructions:response, while
-- others ('semantic_view', 'verified_query', 'data') name things that live
-- outside the specification entirely. Read a key as "which part of the setup a
-- reviewer is talking about", not as a JSON address.
--
-- Keep the keys exactly as written: later scripts compare against these
-- strings, and a renamed key silently matches nothing.

CREATE TABLE IF NOT EXISTS CHANGE_AREAS (
    area_key            VARCHAR NOT NULL,
    area_description    VARCHAR NOT NULL,
    documentation_query VARCHAR NOT NULL
);

-- Eight areas. The descriptions are for the person reading the results; the
-- queries are the search text sent to the Snowflake documentation service.
-- Queries stay generic on purpose: they describe the agent feature, never a
-- conversation, a customer, or the text of a specific answer.

INSERT INTO CHANGE_AREAS (
    area_key,
    area_description,
    documentation_query
)
SELECT
    seeded_areas.area_key,
    seeded_areas.area_description,
    seeded_areas.documentation_query
FROM VALUES
    ('instructions.response',
     'How the agent words and formats its answers',
     'Cortex Agent response instructions formatting presentation'),
    ('instructions.orchestration',
     'How the agent plans and chooses which tool to use',
     'Cortex Agent orchestration instructions tool routing planning'),
    ('tool_description',
     'How each tool describes itself, which drives tool choice',
     'Cortex Agent tool_spec tool description selection'),
    ('models.orchestration',
     'Which model plans the agent turn',
     'Cortex Agent orchestration model selection supported models'),
    ('semantic_view',
     'Dimensions, metrics, and synonyms the agent queries through',
     'Cortex Analyst semantic view dimensions metrics synonyms'),
    ('verified_query',
     'Saved example questions and their approved SQL',
     'Cortex Analyst verified query repository'),
    ('skills',
     'Staged instructions the agent can load as a skill',
     'Cortex Agent skills staged instructions'),
    ('data',
     'The underlying tables and filters, including missing coverage',
     'Cortex Analyst semantic view base tables data coverage filters')
    AS seeded_areas (area_key, area_description, documentation_query)
WHERE NOT EXISTS (SELECT 1 FROM CHANGE_AREAS);

-- Read the seeded areas back.

SELECT
    area_key,
    area_description,
    documentation_query
FROM CHANGE_AREAS
ORDER BY area_key;

-- =============================================================================
-- 3. CHECK THE SETTINGS BEFORE CONTINUING
-- =============================================================================
-- Later scripts read one settings row, keyed on settings_id = 1, and the eight
-- area keys seeded above. Read this status and fix anything it reports before
-- running 01_preflight.sql or anything after it.
--
-- What this query is, and is not:
--   * It is advisory. Plain SQL returns a row; it cannot halt a later script,
--     and a 'stop' status here does not physically block anything downstream.
--   * It is not the only protection. Every later script that selects the input
--     for a paid AI call MUST carry the same guard in its own SQL: read the
--     single settings row on settings_id = 1, and select no input at all when
--     the configuration is invalid or is not a singleton. The later scripts
--     defend themselves against wrong settings by choosing nothing to spend
--     money on, and their inspection queries then explain why zero inputs were
--     eligible. Do not read "advisory" as "the later scripts cannot protect
--     themselves" — they must.
--
-- The ranges below are sanity bounds, not platform limits. Widen them
-- deliberately if your review genuinely needs a larger scope.

WITH settings_state AS (
    -- Aggregate over the whole table so this returns a row even when the
    -- table is empty, which is itself one of the problems worth reporting.
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
        -- Count the rows whose thread filter is unusable: present, but blank
        -- once trimmed, or the string '0'. NULL means "all threads" and is
        -- fine, so NULL rows are not counted here.
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

area_state AS (
    -- Distinct keys, because a duplicated key would multiply rows in any
    -- later join and inflate the evidence behind a suggestion. Counting the
    -- keys is not enough on its own: eight rows could be eight misspellings,
    -- so also count how many of the eight expected keys are actually present.
    SELECT
        COUNT(*) AS area_rows,
        COUNT(DISTINCT area_key) AS distinct_area_keys,
        COUNT(
            DISTINCT CASE
                WHEN area_key IN (
                    'instructions.response',
                    'instructions.orchestration',
                    'tool_description',
                    'models.orchestration',
                    'semantic_view',
                    'verified_query',
                    'skills',
                    'data'
                )
                THEN area_key
            END
        ) AS expected_area_keys_present,
        MIN(LENGTH(TRIM(area_description, ' \t\r\n'))) AS shortest_area_description,
        MIN(LENGTH(TRIM(documentation_query, ' \t\r\n'))) AS shortest_documentation_query
    FROM CHANGE_AREAS
),

checks AS (
    SELECT
        settings_state.*,
        area_state.*,

        -- Exactly one row, and it is the row the later scripts look for.
        settings_state.settings_rows = 1
            AND settings_state.rows_keyed_one = 1 AS one_settings_row_keyed_one,

        settings_state.review_start < settings_state.review_end
            AS window_runs_forward,

        -- SYSDATE() is the current UTC time as TIMESTAMP_NTZ, which is the
        -- same convention review_end is stored in, so this compares like with
        -- like. CURRENT_TIMESTAMP() would bring the session time zone in.
        settings_state.review_end
            <= DATEADD('minute', -15, SYSDATE()) AS window_end_settled,

        -- A very long window is usually a typo, and it is also the setting
        -- most likely to turn one run into a large bill. DATEADD measures exact
        -- elapsed time; DATEDIFF('day', ...) counts midnight boundaries crossed,
        -- so it passed a window of 90 days plus 23 hours.
        settings_state.review_end
            <= DATEADD('day', 90, settings_state.review_start)
            AS window_span_sensible,

        settings_state.unusable_thread_filters = 0 AS thread_filter_usable,

        settings_state.max_new_reviews BETWEEN 1 AND 100 AS reviews_cap_sensible,
        settings_state.max_new_recommendations BETWEEN 1 AND 20 AS recommendations_cap_sensible,
        settings_state.min_occurrences BETWEEN 1 AND 1000 AS occurrences_sensible,
        settings_state.docs_max_age_hours BETWEEN 1 AND 720 AS docs_age_sensible,
        settings_state.prompt_revision_length > 0 AS prompt_revision_present,

        -- Eight rows, eight distinct keys, and all eight are the expected
        -- ones, so the set matches exactly. Descriptions and queries must also
        -- hold real text: a blank query would search for nothing.
        area_state.area_rows = 8
            AND area_state.distinct_area_keys = 8
            AND area_state.expected_area_keys_present = 8
            AND area_state.shortest_area_description > 0
            AND area_state.shortest_documentation_query > 0 AS areas_complete
    FROM settings_state, area_state
)

SELECT
    settings_rows,
    area_rows,
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
             AND areas_complete
        THEN 'ready: settings and change areas look usable'
        ELSE 'stop: fix the failing check below before running later scripts'
    END AS configuration_status,
    one_settings_row_keyed_one,
    window_runs_forward,
    window_end_settled,
    window_span_sensible,
    thread_filter_usable,
    reviews_cap_sensible,
    recommendations_cap_sensible,
    occurrences_sensible,
    docs_age_sensible,
    prompt_revision_present,
    areas_complete
FROM checks;

-- A 'ready' status only means these two tables are internally consistent. It
-- says nothing about your role's grants, whether the agent exists, or whether
-- any events were recorded. 01_preflight.sql checks what is actually readable.

-- Next step: 01_preflight.sql reads the agent specification and recent events
-- to confirm the review window has something in it, still without calling AI.
