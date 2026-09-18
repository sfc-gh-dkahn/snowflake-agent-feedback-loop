-- Baseline only. Run once after saved_results.sql, before mutations.sql. NEVER production.
USE DATABASE OUTPUT_DB;
USE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;

INSERT INTO TEST_CHECKS
SELECT 'same fixture session', 'true', (session_id = CURRENT_SESSION())::VARCHAR FROM TEST_CLOCK
UNION ALL SELECT 'valid settings', 'true', settings_are_valid::VARCHAR FROM ANSWER_REVIEW_SETTINGS_STATUS
UNION ALL SELECT 'valid eight areas', 'true', areas_are_valid::VARCHAR FROM CHANGE_AREAS_STATUS
UNION ALL SELECT 'event count', '65', COUNT(*)::VARCHAR FROM AGENT_EVENTS
UNION ALL SELECT 'root-backed turns, not orphan', '60', COUNT(*)::VARCHAR FROM CONVERSATION_TURNS
UNION ALL SELECT 'agent-sensitive turn hashes', '60', COUNT(DISTINCT turn_hash)::VARCHAR FROM CONVERSATION_TURNS
UNION ALL SELECT 'incomplete whitespace/redacted/missing', '4', COUNT(*)::VARCHAR FROM CONVERSATION_TURNS WHERE NOT is_complete
UNION ALL SELECT 'unknown threads normalize to null', '6', COUNT(*)::VARCHAR FROM CONVERSATION_TURNS WHERE thread_id IS NULL
UNION ALL SELECT 'all-history pair count', '44', COUNT(*)::VARCHAR FROM ANSWER_FOLLOWUP_PAIRS
UNION ALL SELECT 'agent-sensitive pair hashes', '44', COUNT(DISTINCT pair_hash)::VARCHAR FROM ANSWER_FOLLOWUP_PAIRS
UNION ALL SELECT 'incomplete middle blocks distant pairing', 'b3>b4', LISTAGG(response_trace_id || '>' || feedback_trace_id, ',') WITHIN GROUP (ORDER BY response_trace_id) FROM ANSWER_FOLLOWUP_PAIRS WHERE thread_id = 'broken'
UNION ALL SELECT 'incomplete middle keeps position two', '2', turn_no::VARCHAR FROM CONVERSATION_TURNS WHERE trace_id = 'b2'
UNION ALL SELECT 'last answer stays unjudged', '0', COUNT(*)::VARCHAR FROM ANSWER_FOLLOWUP_PAIRS WHERE response_trace_id = 't15'
UNION ALL SELECT 'each agent owns shared trace', '3', COUNT(*)::VARCHAR FROM CONVERSATION_TURNS WHERE trace_id = 't01'
UNION ALL SELECT 'internal spans kept without tool fields', '2', ARRAY_SIZE(tool_evidence)::VARCHAR FROM CONVERSATION_TURNS WHERE agent_name = 'SYNTH_A' AND trace_id = 't01'
UNION ALL SELECT 'internal spans ordered by span at same time', 'chart,skill', tool_evidence[0]:event_hash::VARCHAR || ',' || tool_evidence[1]:event_hash::VARCHAR FROM CONVERSATION_TURNS WHERE agent_name = 'SYNTH_A' AND trace_id = 't01'
UNION ALL SELECT 'latest root tie-break and earliest question', 'd-z|Earliest question.|Selected answer.', root_event_hash || '|' || user_question || '|' || agent_answer FROM CONVERSATION_TURNS WHERE trace_id = 'd1'
UNION ALL SELECT 'six prior positions at long-thread end', '6', MIN(ARRAY_SIZE(evidence:prior_turns))::VARCHAR FROM ANSWER_FOLLOWUP_PAIRS WHERE feedback_trace_id = 't15'
UNION ALL SELECT 'response closes prior context', 't14', MIN(evidence:prior_turns[5]:trace_id::VARCHAR) FROM ANSWER_FOLLOWUP_PAIRS WHERE feedback_trace_id = 't15'
UNION ALL SELECT 'invalid specification stays visible', '1', COUNT(*)::VARCHAR FROM CURRENT_AGENT_SETTINGS WHERE NOT specification_is_valid AND config_hash IS NULL
UNION ALL SELECT 'key order does not change config hash across agents', '1', COUNT(DISTINCT config_hash)::VARCHAR FROM CURRENT_AGENT_SETTINGS WHERE specification_is_valid
UNION ALL SELECT 'bad root excluded from reviews', '0', COUNT(*)::VARCHAR FROM TEST_REVIEW_BASE WHERE agent_name = 'SYNTH_BAD'
UNION ALL SELECT 'saved reviews including failures excluded on rerun', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'repeat mock save does not duplicate reviews', '28', COUNT(*)::VARCHAR FROM ANSWER_REVIEWS
UNION ALL SELECT 'invalid/error reviews excluded from observations', '22', COUNT(*)::VARCHAR FROM RECOMMENDATION_OBSERVATIONS
UNION ALL SELECT 'full group count before cap', '16', COUNT(*)::VARCHAR FROM RECOMMENDATION_GROUPS
UNION ALL SELECT 'response counts include both observations', '2', MIN(total_occurrences)::VARCHAR FROM RECOMMENDATION_GROUPS WHERE surface = 'instructions.response'
UNION ALL SELECT 'good counterevidence counted per agent', '1', MIN(total_good_responses)::VARCHAR FROM RECOMMENDATION_GROUPS
UNION ALL SELECT 'all current suggestions reused including failures', '4', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE has_saved_result
UNION ALL SELECT 'saved suggestions never spend cap', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE is_within_budget
UNION ALL SELECT 'repeat save preserves exactly 42 suggestion results', '42', COUNT(*)::VARCHAR FROM RECOMMENDATIONS
UNION ALL SELECT 'every suggestion needs human review', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_RESULTS WHERE NOT requires_human_review
UNION ALL SELECT 'recommendation cases exercise all twelve fields', '24', COUNT(*)::VARCHAR FROM TEST_REC_CASES WHERE case_name LIKE 'missing_%' OR case_name LIKE 'type_%';

INSERT INTO TEST_CHECKS
SELECT 'review: ' || base.agent_name || '/' || cases.trace_id, cases.expected, COALESCE(findings.validation_status, 'MISSING')
FROM TEST_REVIEW_BASE AS base JOIN TEST_REVIEW_CASES AS cases ON cases.trace_id = base.response_trace_id
LEFT JOIN REVIEW_FINDINGS AS findings ON findings.review_id = base.review_id;
INSERT INTO TEST_CHECKS
SELECT 'recommendation: ' || cases.case_name, cases.expected, COALESCE(results.review_status, 'MISSING')
FROM TEST_REC_CASES AS cases JOIN TEST_REC_INPUTS AS base ON base.surface = cases.surface
LEFT JOIN RECOMMENDATION_RESULTS AS results ON results.recommendation_id = base.recommendation_id || ':' || cases.case_name;
INSERT INTO TEST_CHECKS
SELECT 'current queue: ' || base.agent_name || '/' || base.surface, outputs.expected, COALESCE(queue.queue_status, 'MISSING')
FROM TEST_REC_BASE AS base JOIN TEST_REC_OUTPUTS AS outputs USING (recommendation_id)
LEFT JOIN REVIEW_QUEUE AS queue ON queue.recommendation_id = base.recommendation_id;
INSERT INTO TEST_CHECKS
SELECT 'docs raw type: ' || case_name, expected, COALESCE(documentation_status, 'MISSING')
FROM TEST_DOC_CASES LEFT JOIN DOCUMENTATION_STATUS ON retrieval_id = 'case:' || case_name;
INSERT INTO TEST_CHECKS
SELECT 'docs preserves exact text', ' Synthetic title |  Synthetic response guidance.  ', title || '|' || chunk
FROM DOCUMENTATION_PASSAGES WHERE retrieval_id = 'instructions.response' AND passage_index = 0;
INSERT INTO TEST_CHECKS
SELECT 'docs gate: ' || agent_name || '/' || surface, column2, eligibility_status
FROM VALUES ('instructions.response','eligible'), ('data','eligible'),
    ('instructions.orchestration','bad_docs'), ('models.orchestration','bad_docs'),
    ('tool_description','stale_docs'), ('semantic_view','missing_docs'),
    ('verified_query','missing_docs'), ('skills','missing_docs')
JOIN RECOMMENDATION_GROUPS ON surface = column1;

SELECT test_name, COALESCE(expected = actual, FALSE) AS passed, expected, actual
FROM TEST_CHECKS ORDER BY test_name;
SELECT COUNT(*) AS tests, COALESCE(COUNT_IF(actual IS DISTINCT FROM expected), 0) AS failures,
       IFF(COUNT(*) > 0 AND COALESCE(COUNT_IF(actual IS DISTINCT FROM expected), 0) = 0, 'PASS', 'FAIL') AS status
FROM TEST_CHECKS;
-- Stop on any failure. PASS covers saved-data view behavior only, not live APIs.