-- =============================================================================
-- AGENT FEEDBACK LOOP: Rebuild turns, then pair each answer with the next message
-- =============================================================================
-- Two views over the saved events:
--
--   AGENT_EVENTS -> CONVERSATION_TURNS      one row per agent turn (trace)
--                -> ANSWER_FOLLOWUP_PAIRS   one row per answer -> follow-up pair
--
-- Customize before running:
--   1. Replace OUTPUT_DB and AGENT_FEEDBACK with the location holding AGENT_EVENTS.
--
-- These views read the FULL saved history: no review window, no thread filter,
-- so one view serves any window. Step 4 reads REVIEW_SETTINGS and filters on
-- feedback_time_utc before selecting input for a paid AI call.
--
-- What a pair claims, and what it does not: the follow-up message is a PROXY
-- for satisfaction, never a rating -- nobody scored the answer, the next thing
-- the person typed is all we have. Nothing here judges a final answer; no score
-- is computed or stored. An answer with no later complete turn stays UNJUDGED
-- and is absent from the pairs view, which is not a verdict on its quality.
--
-- Views only: creates or replaces the two views below. No event or result rows
-- change, no AI calls, no changes to the agent.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- =============================================================================
-- 1. REBUILD EACH TURN FROM ITS SPANS
-- =============================================================================
-- A thread is a conversation, a trace is one turn, a span is part of that turn.
-- A turn exists when it has a root span; the root carries the answer.

CREATE OR REPLACE VIEW CONVERSATION_TURNS AS
WITH recorded_events AS (
    -- Every saved span, normalized once so the rest of the view reads plain
    -- columns: blank and '0' thread IDs mean "unknown thread", not thread zero;
    -- event_time is saved TIMESTAMP_LTZ and step 4 compares it to NTZ settings
    -- dates, so converting here stops the session offset shifting the window.
    -- TRIM names the whitespace it strips -- spaces, tabs, carriage returns and
    -- newlines -- so a question, answer, or thread ID holding only whitespace
    -- reads as empty rather than as content.
    SELECT
        * EXCLUDE (thread_id, first_saved_at),
        NULLIF(NULLIF(TRIM(thread_id, ' \t\r\n'), ''), '0') AS thread_id,
        CONVERT_TIMEZONE('UTC', event_time)::TIMESTAMP_NTZ AS event_time_utc,
        COALESCE(LOWER(TRIM(user_question, ' \t\r\n')) NOT IN
            ('', '1', 'null', '[redacted]', '<redacted>', 'redacted'), FALSE) AS question_is_usable,
        COALESCE(LOWER(TRIM(agent_answer, ' \t\r\n')) NOT IN
            ('', '1', 'null', '[redacted]', '<redacted>', 'redacted'), FALSE) AS answer_is_usable
    FROM AGENT_EVENTS
),

turn_roots AS (
    -- One root per turn: our rule is to take the latest. That is a selection
    -- rule for picking one row, not proof that a later root supersedes an
    -- earlier one. The tie-break runs through span_id to event_hash, which is
    -- NOT NULL and unique per saved event, so repeat runs cannot disagree.
    SELECT
        agent_database, agent_schema, agent_name, thread_id, trace_id, message_id,
        event_time, event_time_utc, agent_answer, answer_is_usable, status_code,
        event_hash AS root_event_hash
    FROM recorded_events
    WHERE span_type = 'record_root'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY agent_database, agent_schema, agent_name, trace_id
        ORDER BY event_time_utc DESC NULLS LAST, span_id DESC NULLS LAST, event_hash DESC) = 1
),

turn_questions AS (
    -- The earliest usable question, because a turn opens with what the person
    -- asked. Later spans can repeat or rewrite it.
    SELECT
        agent_database, agent_schema, agent_name, trace_id,
        user_question, event_hash AS question_event_hash
    FROM recorded_events
    WHERE question_is_usable
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY agent_database, agent_schema, agent_name, trace_id
        ORDER BY event_time_utc ASC NULLS LAST, span_id ASC NULLS LAST, event_hash ASC) = 1
),

turn_evidence AS (
    -- What the agent did, in the order it happened, so a hash built from these
    -- arrays is stable. event_hashes covers every span; tool_evidence keeps the
    -- working spans. The two STARTSWITH tests catch internal skill and chart
    -- spans, which may omit tool_name, executed_sql, and chart_definition; they
    -- are kept even when those field names are absent, so they do not vanish
    -- from the record of what ran.
    SELECT
        agent_database, agent_schema, agent_name, trace_id,
        ARRAY_AGG(event_hash) WITHIN GROUP (
            ORDER BY event_time_utc, span_id ASC NULLS LAST, event_hash) AS event_hashes,
        ARRAY_AGG(IFF(
            tool_name IS NOT NULL OR executed_sql IS NOT NULL OR chart_definition IS NOT NULL
                OR STARTSWITH(span_name, 'ServerSkillTool_')
                OR STARTSWITH(span_name, 'CortexChartToolImpl-'),
            OBJECT_CONSTRUCT_KEEP_NULL(
                'event_hash', event_hash, 'span_id', span_id,
                'event_epoch_ns', DATE_PART(epoch_nanosecond, event_time),
                'span_name', span_name, 'tool_name', tool_name,
                'executed_sql', executed_sql, 'chart_definition', chart_definition,
                'status_code', status_code),
            NULL)) WITHIN GROUP (
            ORDER BY event_time_utc, span_id ASC NULLS LAST, event_hash) AS tool_evidence
    FROM recorded_events
    GROUP BY agent_database, agent_schema, agent_name, trace_id
)

-- turn_no counts EVERY root-backed turn in the thread, numbered before any
-- completeness test. That keeps adjacency honest: an incomplete turn still
-- occupies its position, so the answers either side are never treated as
-- neighbours. Turns with no usable thread ID share one NULL partition per
-- agent; they are numbered but never paired, as section 2 needs a real thread.
-- turn_hash is identity from content only -- agent, thread, trace and the span
-- hashes the turn was built from. No capture timestamp and no snapshot ID take
-- part, so the same evidence reproduces the same hash and editing a span
-- changes it.
SELECT
    turn_roots.agent_database, turn_roots.agent_schema, turn_roots.agent_name,
    turn_roots.thread_id, turn_roots.trace_id, turn_roots.message_id,
    turn_roots.event_time, turn_roots.event_time_utc, turn_roots.root_event_hash,
    turn_questions.user_question, turn_roots.agent_answer, turn_roots.status_code,
    turn_evidence.tool_evidence, turn_evidence.event_hashes,
    -- Complete means both halves are readable. Neither operand can be NULL:
    -- IS NOT NULL never is, and answer_is_usable was coalesced above.
    (turn_questions.question_event_hash IS NOT NULL
        AND turn_roots.answer_is_usable) AS is_complete,
    ROW_NUMBER() OVER (
        PARTITION BY turn_roots.agent_database, turn_roots.agent_schema,
                     turn_roots.agent_name, turn_roots.thread_id
        ORDER BY turn_roots.event_time_utc, turn_roots.trace_id) AS turn_no,
    SHA2(TO_JSON(ARRAY_CONSTRUCT(
        turn_roots.agent_database, turn_roots.agent_schema, turn_roots.agent_name,
        turn_roots.thread_id, turn_roots.trace_id, turn_roots.root_event_hash,
        turn_questions.question_event_hash, turn_evidence.event_hashes)), 256) AS turn_hash
FROM turn_roots
LEFT JOIN turn_questions USING (agent_database, agent_schema, agent_name, trace_id)
LEFT JOIN turn_evidence USING (agent_database, agent_schema, agent_name, trace_id);

-- Inspect the turns. Incomplete turns are kept on purpose. Read
-- turns_without_thread_id as unpairable, not as an error.

SELECT
    agent_database, agent_schema, agent_name,
    COUNT(*) AS turns,
    COALESCE(COUNT_IF(is_complete), 0) AS complete_turns,
    COALESCE(COUNT_IF(NOT is_complete), 0) AS incomplete_turns,
    COALESCE(COUNT_IF(thread_id IS NULL), 0) AS turns_without_thread_id,
    COUNT(DISTINCT thread_id) AS threads,
    MIN(event_time_utc) AS earliest_turn_utc, MAX(event_time_utc) AS latest_turn_utc
FROM CONVERSATION_TURNS
GROUP BY agent_database, agent_schema, agent_name;

-- Read threads end to end. turn_no has no gaps, so consecutive numbers really
-- are neighbours. Conversation text is sensitive; check results before sharing.

SELECT
    thread_id, turn_no, trace_id, event_time_utc, is_complete,
    user_question, agent_answer,
    ARRAY_SIZE(tool_evidence) AS tool_spans
FROM CONVERSATION_TURNS
ORDER BY agent_database, agent_schema, agent_name, thread_id, turn_no
LIMIT 40;

-- =============================================================================
-- 2. PAIR EACH ANSWER WITH THE FOLLOW-UP THAT CAME NEXT
-- =============================================================================
-- Join a turn to the one numbered directly before it in the same thread.
-- Because turn_no was assigned before the completeness test, requiring both
-- turns complete DROPS the pair instead of reaching past an incomplete turn to
-- a distant answer.

CREATE OR REPLACE VIEW ANSWER_FOLLOWUP_PAIRS AS
WITH adjacent_pairs AS (
    -- followup is the later turn; response is the answer being judged. The
    -- follow-up turn is assembled here so evidence below reads as one object.
    SELECT
        agent_database, agent_schema, agent_name, thread_id, followup.turn_no,
        followup.trace_id AS feedback_trace_id,
        followup.event_time AS feedback_time,
        followup.event_time_utc AS feedback_time_utc,
        followup.user_question AS followup_message,
        followup.turn_hash AS followup_turn_hash,
        OBJECT_CONSTRUCT_KEEP_NULL(
            'trace_id', followup.trace_id, 'message_id', followup.message_id,
            'event_epoch_ns', DATE_PART(epoch_nanosecond, followup.event_time),
            'user_question', followup.user_question, 'agent_answer', followup.agent_answer,
            'status_code', followup.status_code, 'tool_evidence', followup.tool_evidence,
            'event_hashes', followup.event_hashes) AS followup_turn,
        response.trace_id AS response_trace_id,
        response.user_question, response.agent_answer,
        response.turn_hash AS response_turn_hash
    FROM CONVERSATION_TURNS AS followup
    JOIN CONVERSATION_TURNS AS response
         USING (agent_database, agent_schema, agent_name, thread_id)
    WHERE response.turn_no = followup.turn_no - 1
      AND thread_id IS NOT NULL
      AND followup.is_complete
      AND response.is_complete
),

pair_context AS (
    -- The six turn positions ending at the response, so the response turn is
    -- always the last entry. Complete turns only: an incomplete turn holds its
    -- position for adjacency but has no readable text for a reviewer. One pass
    -- produces the turns and the two hash arrays the pair identity uses.
    SELECT
        agent_database, agent_schema, agent_name, thread_id, feedback_trace_id,
        ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
            'trace_id', prior.trace_id, 'message_id', prior.message_id,
            'event_epoch_ns', DATE_PART(epoch_nanosecond, prior.event_time),
            'user_question', prior.user_question, 'agent_answer', prior.agent_answer,
            'status_code', prior.status_code, 'tool_evidence', prior.tool_evidence,
            'event_hashes', prior.event_hashes)
        ) WITHIN GROUP (ORDER BY prior.turn_no, prior.trace_id) AS prior_turns,
        ARRAY_AGG(prior.turn_hash) WITHIN GROUP (
            ORDER BY prior.turn_no, prior.trace_id) AS prior_turn_hashes,
        ARRAY_AGG(prior.event_hashes) WITHIN GROUP (
            ORDER BY prior.turn_no, prior.trace_id) AS prior_event_hashes
    FROM adjacent_pairs
    JOIN CONVERSATION_TURNS AS prior
         USING (agent_database, agent_schema, agent_name, thread_id)
    WHERE prior.turn_no BETWEEN adjacent_pairs.turn_no - 6 AND adjacent_pairs.turn_no - 1
      AND prior.is_complete
    GROUP BY agent_database, agent_schema, agent_name, thread_id, feedback_trace_id
)

-- evidence carries what a reviewer needs in one column, with the limits of that
-- evidence recorded beside it rather than left to a reader's memory.
-- pair_hash is a stable identity over the actual ordered content: agent, thread,
-- both traces, both turn hashes, and the context by turn hash AND by its full
-- event-hash arrays. Editing a span changes an event hash, then a turn hash,
-- then this. Nothing random and no capture timestamp takes part, so unchanged
-- evidence reuses the key. Step 4 adds its model and prompt revision; it must
-- not reuse pair_hash as a review identity.
SELECT
    agent_database, agent_schema, agent_name, thread_id,
    adjacent_pairs.response_trace_id, feedback_trace_id,
    adjacent_pairs.feedback_time, adjacent_pairs.feedback_time_utc,
    adjacent_pairs.user_question, adjacent_pairs.agent_answer,
    adjacent_pairs.followup_message,
    OBJECT_CONSTRUCT_KEEP_NULL(
        'response_trace_id', adjacent_pairs.response_trace_id,
        'feedback_trace_id', feedback_trace_id,
        'prior_turns', pair_context.prior_turns,
        'followup_turn', adjacent_pairs.followup_turn,
        'coverage', 'FOLLOWUP_PROXY; NOT_EXPLICIT_FEEDBACK; NO_FINAL_ANSWER_JUDGMENT; NO_FINAL_ANSWER_WITHOUT_FOLLOWUP',
        'config_scope', 'CAPTURE_TIME_ONLY; INVOCATION_VERSION_UNKNOWN') AS evidence,
    SHA2(TO_JSON(ARRAY_CONSTRUCT(
        agent_database, agent_schema, agent_name, thread_id,
        adjacent_pairs.response_trace_id, feedback_trace_id,
        adjacent_pairs.response_turn_hash, adjacent_pairs.followup_turn_hash,
        pair_context.prior_turn_hashes, pair_context.prior_event_hashes)), 256) AS pair_hash
FROM adjacent_pairs
JOIN pair_context
     USING (agent_database, agent_schema, agent_name, thread_id, feedback_trace_id);

-- An inner join, deliberately: the response turn is complete and sits inside the
-- six positions, so a valid pair always has context. A pair missing here failed
-- the adjacency rule, not the context lookup.

-- Inspect the pairs. answers_with_followup is smaller than complete_turns; the
-- difference is answers that stay unjudged. Expected, not a fault.

SELECT
    agent_database, agent_schema, agent_name,
    COUNT(*) AS pairs,
    COUNT(DISTINCT pair_hash) AS distinct_pair_identities,
    COUNT(DISTINCT thread_id) AS threads_with_pairs,
    COUNT(DISTINCT response_trace_id) AS answers_with_followup,
    MIN(feedback_time_utc) AS earliest_followup_utc,
    MAX(feedback_time_utc) AS latest_followup_utc
FROM ANSWER_FOLLOWUP_PAIRS
GROUP BY agent_database, agent_schema, agent_name;

-- Read a few pairs. Judge by eye whether the follow-up reads like a correction,
-- a repeat of the question, or simply the next topic.

SELECT
    thread_id, feedback_time_utc, user_question, agent_answer, followup_message,
    ARRAY_SIZE(evidence:prior_turns) AS context_turns,
    pair_hash
FROM ANSWER_FOLLOWUP_PAIRS
ORDER BY feedback_time_utc DESC, response_trace_id, feedback_trace_id
LIMIT 20;

-- The unjudged answers: complete, in a real thread, and with no pair. That
-- covers two cases -- no later turn yet, and a next turn that is incomplete, so
-- adjacency holds but the pair is dropped. Listed for inspection only. This is
-- not a list of bad answers.

SELECT
    turns.thread_id, turns.turn_no, turns.trace_id,
    turns.event_time_utc, turns.user_question
FROM CONVERSATION_TURNS AS turns
LEFT JOIN ANSWER_FOLLOWUP_PAIRS AS pairs
       ON pairs.agent_database = turns.agent_database
      AND pairs.agent_schema = turns.agent_schema
      AND pairs.agent_name = turns.agent_name
      AND pairs.response_trace_id = turns.trace_id
WHERE turns.is_complete
  AND turns.thread_id IS NOT NULL
  AND pairs.response_trace_id IS NULL
ORDER BY turns.event_time_utc DESC, turns.trace_id
LIMIT 20;

-- Next step: judge each pair with an AI call and save the result. That step
-- reads REVIEW_SETTINGS, applies the window to feedback_time_utc and the thread
-- filter to thread_id, selects no input at all when the settings are invalid,
-- and keeps every saved result, including errors.
