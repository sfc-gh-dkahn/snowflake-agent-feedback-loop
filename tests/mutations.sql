-- NEVER production. Run once after baseline PASS. Every change is isolated and restored.
-- Do not continue after SQL errors; use a new fixture session/schema to restart.
USE DATABASE OUTPUT_DB;
USE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;

INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SELECT 'recapture:' || agent_name, TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, DATEADD('second', 1, started_utc)), 9),
       'SYNTH_DB', 'SYNTH_SCHEMA', agent_name, specification FROM TEST_AGENTS CROSS JOIN TEST_CLOCK;
INSERT INTO TEST_CHECKS
SELECT 'recapture does not reopen saved reviews', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'recapture reuses four saved suggestions', '4', COUNT(*)::VARCHAR
FROM RECOMMENDATION_CANDIDATES JOIN TEST_REC_BASE USING (recommendation_id);
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SELECT 'refresh:' || area_key, DATEADD('second', -1, started_utc), area_key,
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE', documentation_query,
       OBJECT_CONSTRUCT('results', ARRAY_CONSTRUCT(response:results[1], response:results[0]))
FROM CHANGE_AREAS CROSS JOIN TEST_DOC_RESPONSE CROSS JOIN TEST_CLOCK WHERE area_key IN ('instructions.response','data');
INSERT INTO TEST_CHECKS
SELECT 'reordered fresh docs reuse four identities', '4', COUNT(*)::VARCHAR
FROM RECOMMENDATION_CANDIDATES JOIN TEST_REC_BASE USING (recommendation_id)
UNION ALL SELECT 'fresh equivalent retrieval authorizes four saved inputs', '4', COUNT(*)::VARCHAR
FROM RECOMMENDATION_INPUT_STATUS JOIN TEST_REC_BASE USING (recommendation_id);

UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET max_new_reviews = 2, max_new_recommendations = 2;
INSERT INTO TEST_CHECKS
SELECT 'budget does not change suggestion identity', '4', COUNT(*)::VARCHAR
FROM RECOMMENDATION_CANDIDATES JOIN TEST_REC_BASE USING (recommendation_id);
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET max_new_reviews = 1, max_new_recommendations = 1, min_occurrences = 2;
INSERT INTO TEST_CHECKS
SELECT 'threshold two permits only response groups', '2', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES
UNION ALL SELECT 'single gaps remain insufficient at threshold two', '2', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE surface = 'data' AND queue_status = 'insufficient_evidence';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET min_occurrences = 1, prompt_revision = 'test-v2';
INSERT INTO TEST_CHECKS
SELECT 'revision creates new reviews', '28', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'new revision does not reuse old reviews', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES JOIN TEST_REVIEW_BASE USING (review_id)
UNION ALL SELECT 'old judgments cannot feed new revision', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_OBSERVATIONS;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET thread_filter = ' \tcore\r\n';
INSERT INTO TEST_CHECKS SELECT 'padded real thread is not invalid', '28', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET thread_filter = ' \t\r\n';
INSERT INTO TEST_CHECKS
SELECT 'blank filter blocks all candidates', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'invalid filter sentinel survives no groups', '1', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE queue_status = 'invalid_settings';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS SET thread_filter = NULL;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS
SELECT 2, review_start, review_end, NULL, 0, 1, 1, 168, 'test-v2' FROM REVIEW_SETTINGS;
INSERT INTO TEST_CHECKS SELECT 'invalid second row cannot hide from singleton guard', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES;
DELETE FROM OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS WHERE settings_id = 2;
DELETE FROM OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS WHERE settings_id = 1;
INSERT INTO TEST_CHECKS
SELECT 'empty settings block reviews', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'empty settings retain invalid sentinel', '1', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE queue_status = 'invalid_settings';
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS
SELECT 1, base_utc, DATEADD('day', 1, base_utc), NULL, 1, 1, 1, 168, 'test-v2' FROM TEST_CLOCK;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS
SET review_start = DATEADD('second', 2, (SELECT base_utc FROM TEST_CLOCK)),
    review_end = DATEADD('second', 3, (SELECT base_utc FROM TEST_CLOCK));
INSERT INTO TEST_CHECKS
SELECT 'UTC start included and end excluded', '2', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'window filters followup not response time', 't02', MIN(feedback_trace_id) FROM REVIEW_CANDIDATES;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS
SET review_start = (SELECT base_utc FROM TEST_CLOCK), review_end = DATEADD('day', 1, (SELECT base_utc FROM TEST_CLOCK)), prompt_revision = 'test-v1';

UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SET agent_specification = OBJECT_INSERT(agent_specification, 'empty', ARRAY_CONSTRUCT(), TRUE)
WHERE snapshot_id = 'recapture:SYNTH_A';
INSERT INTO TEST_CHECKS
SELECT 'empty object changed to array changes config identity', '14', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'other agent remains reused after config change', '2', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE agent_name = 'SYNTH_B' AND has_saved_result;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SET agent_specification = (SELECT specification FROM TEST_AGENTS WHERE agent_name = 'SYNTH_A') WHERE snapshot_id = 'recapture:SYNTH_A';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SET agent_specification = PARSE_JSON('{}') WHERE snapshot_id = 'recapture:SYNTH_BAD';
INSERT INTO TEST_CHECKS SELECT 'empty object root is valid and hashable', '14', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES WHERE agent_name = 'SYNTH_BAD';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SET agent_specification = PARSE_JSON('null') WHERE snapshot_id = 'recapture:SYNTH_BAD';
INSERT INTO TEST_CHECKS SELECT 'JSON null root is invalid', '0', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES WHERE agent_name = 'SYNTH_BAD';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SET agent_specification = PARSE_JSON('[]') WHERE snapshot_id = 'recapture:SYNTH_BAD';

UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS SET event_hash = 'changed:skill' WHERE event_hash = 'skill';
INSERT INTO TEST_CHECKS
SELECT 'changed span affects exactly six context pairs', '6', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES
UNION ALL SELECT 'changed evidence excludes six old observations', '16', COUNT(*)::VARCHAR FROM RECOMMENDATION_OBSERVATIONS;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS SET event_hash = 'skill' WHERE event_hash = 'changed:skill';

UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SET model_response = OBJECT_CONSTRUCT_KEEP_NULL('value', OBJECT_INSERT(model_response:value, 'observation', 'Changed synthetic observation.', TRUE), 'error', NULL)
WHERE review_id = (SELECT review_id FROM TEST_REVIEW_BASE WHERE agent_name = 'SYNTH_A' AND response_trace_id = 't01');
INSERT INTO TEST_CHECKS
SELECT 'review content changes only its suggestion identity', '1', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE NOT has_saved_result
UNION ALL SELECT 'historical suggestion no longer fills current queue', '1', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE queue_status = 'awaiting_inference';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS AS saved SET model_response = original.model_response
FROM TEST_REVIEW_OUTPUTS AS original WHERE saved.review_id = original.review_id;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SET model_response = OBJECT_CONSTRUCT_KEEP_NULL('value', OBJECT_INSERT(model_response:value, 'observation', 'Changed synthetic success.', TRUE), 'error', NULL)
WHERE review_id = (SELECT review_id FROM TEST_REVIEW_BASE WHERE agent_name = 'SYNTH_A' AND response_trace_id = 't09');
INSERT INTO TEST_CHECKS SELECT 'counterevidence changes both same-agent suggestions', '2', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE NOT has_saved_result;
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS AS saved SET model_response = original.model_response
FROM TEST_REVIEW_OUTPUTS AS original WHERE saved.review_id = original.review_id;

INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SELECT review_id, DATEADD('second', 1, started_utc), PARSE_JSON('{"value":null,"error":"newer synthetic failure"}')
FROM TEST_REVIEW_BASE CROSS JOIN TEST_CLOCK WHERE agent_name = 'SYNTH_A' AND response_trace_id = 't01';
INSERT INTO TEST_CHECKS SELECT 'newer error masks old valid observation', '21', COUNT(*)::VARCHAR FROM RECOMMENDATION_OBSERVATIONS;
DELETE FROM OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS WHERE reviewed_at > (SELECT started_utc FROM TEST_CLOCK);

UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SET response = OBJECT_CONSTRUCT('results', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
    'SOURCE_URL', 'https://docs.snowflake.com/en/synthetic-a', 'DOCUMENT_TITLE', 'Synthetic title', 'CHUNK', 'Changed synthetic docs.')))
WHERE retrieval_id = 'refresh:instructions.response';
INSERT INTO TEST_CHECKS
SELECT 'docs content changes two response identities', '2', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE NOT has_saved_result
UNION ALL SELECT 'changed docs revoke saved input readiness', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_INPUT_STATUS JOIN TEST_REC_BASE USING (recommendation_id) WHERE surface = 'instructions.response';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SET response = PARSE_JSON('{"results":[],"error":"newest synthetic failure"}') WHERE retrieval_id = 'refresh:instructions.response';
INSERT INTO TEST_CHECKS
SELECT 'latest bad docs mask older fresh docs', '2', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE surface = 'instructions.response' AND queue_status = 'bad_docs'
UNION ALL SELECT 'bad docs revoke saved input readiness', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_INPUT_STATUS JOIN TEST_REC_BASE USING (recommendation_id) WHERE surface = 'instructions.response';
DELETE FROM OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS WHERE retrieval_id LIKE 'refresh:%';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SET captured_at = DATEADD('hour', -200, (SELECT started_utc FROM TEST_CLOCK)) WHERE retrieval_id = 'instructions.response';
INSERT INTO TEST_CHECKS SELECT 'expired docs cannot reuse saved response proposals', '2', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE surface = 'instructions.response' AND queue_status = 'stale_docs';
UPDATE OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SET captured_at = DATEADD('hour', -1, (SELECT started_utc FROM TEST_CLOCK)) WHERE retrieval_id = 'instructions.response';
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.CHANGE_AREAS SELECT * FROM CHANGE_AREAS WHERE area_key = 'data';
INSERT INTO TEST_CHECKS SELECT 'duplicate area blocks suggestions', '0', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES;
DELETE FROM OUTPUT_DB.AGENT_FEEDBACK_TEST.CHANGE_AREAS WHERE area_key = 'data';
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.CHANGE_AREAS VALUES ('data','Synthetic test area','Cortex Analyst semantic view base tables data coverage filters');

INSERT INTO TEST_CHECKS
SELECT 'restored reviews still immutable in count', '28', COUNT(*)::VARCHAR FROM ANSWER_REVIEWS
UNION ALL SELECT 'restored current suggestions match baseline', '4', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES JOIN TEST_REC_BASE USING (recommendation_id)
UNION ALL SELECT 'restored suggestions retain all results', '42', COUNT(*)::VARCHAR FROM RECOMMENDATIONS;
SELECT test_name, COALESCE(expected = actual, FALSE) AS passed, expected, actual FROM TEST_CHECKS ORDER BY test_name;
SELECT COUNT(*) AS tests, COALESCE(COUNT_IF(actual IS DISTINCT FROM expected), 0) AS failures,
       IFF(COUNT(*) > 0 AND COALESCE(COUNT_IF(actual IS DISTINCT FROM expected), 0) = 0, 'PASS', 'FAIL') AS status FROM TEST_CHECKS;