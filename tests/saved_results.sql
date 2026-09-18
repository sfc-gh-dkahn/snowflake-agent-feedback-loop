-- NEVER production. Run once, after the view-only installation, in the fixture session.
USE DATABASE OUTPUT_DB;
USE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;
SELECT session_id = CURRENT_SESSION() AS same_session FROM TEST_CLOCK;

CREATE TEMP TABLE TEST_REVIEW_BASE AS SELECT * FROM REVIEW_CANDIDATES;
INSERT INTO TEST_CHECKS
SELECT 'review eligibility before saving', '28', COUNT(*)::VARCHAR FROM TEST_REVIEW_BASE
UNION ALL SELECT 'review cap independent of eligibility', '1', COUNT(*)::VARCHAR FROM TEST_REVIEW_BASE WHERE is_within_budget
UNION ALL SELECT 'reviews deferred before saving', '27', COUNT(*)::VARCHAR FROM TEST_REVIEW_BASE WHERE NOT is_within_budget;

INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEW_INPUTS
SELECT review_id, pair_hash, config_hash, agent_database, agent_schema, agent_name,
       thread_id, response_trace_id, feedback_trace_id, feedback_time_utc, evidence,
       current_config, model_name, prompt_revision, schema_revision, prompt_hash, prompt_text, started_utc
FROM TEST_REVIEW_BASE CROSS JOIN TEST_CLOCK;
CREATE TEMP TABLE TEST_REVIEW_CASES AS
SELECT column1 AS trace_id, column2 AS surface, column3 AS assessment, column4 AS expected FROM VALUES
    ('t01','instructions.response','poor','valid'), ('t02','data','unclear','valid'),
    ('t03','instructions.orchestration','poor','valid'), ('t04','tool_description','poor','valid'),
    ('t05','models.orchestration','poor','valid'), ('t06','semantic_view','poor','valid'),
    ('t07','verified_query','poor','valid'), ('t08','skills','poor','valid'),
    ('t09','none','good','valid'), ('t10','none','unclear','valid'),
    ('t11','none','poor','invalid_output'), ('t12','none','poor','invalid_output'),
    ('t13','none','poor','ai_error'), ('t14','instructions.response','poor','valid');
CREATE TEMP TABLE TEST_REVIEW_OUTPUTS AS
SELECT base.review_id, started_utc AS reviewed_at, OBJECT_CONSTRUCT_KEEP_NULL('value',
       IFF(cases.trace_id = 't13', PARSE_JSON('null'), OBJECT_CONSTRUCT(
           'assessment', cases.assessment, 'issue_type', IFF(surface = 'data', 'reported_data_gap', 'agent_behavior'),
           'severity', 'moderate', 'surface', surface, 'observation', 'Synthetic observation.',
           'evidence_quote', IFF(cases.trace_id = 't11', 'Invented quote.', 'Synthetic answer.'),
           'suspected_cause', 'unknown', 'preserve_behavior', 'Preserve synthetic scope.',
           'requires_review', IFF(cases.trace_id = 't12', TO_VARIANT('true'), TO_VARIANT(TRUE)))),
       'error', IFF(cases.trace_id = 't13', 'synthetic failure', NULL)) AS model_response
FROM TEST_REVIEW_BASE AS base JOIN TEST_REVIEW_CASES AS cases ON cases.trace_id = base.response_trace_id
CROSS JOIN TEST_CLOCK;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SELECT outputs.* FROM TEST_REVIEW_OUTPUTS AS outputs JOIN TEST_REVIEW_BASE USING (review_id) WHERE review_rank = 1;
INSERT INTO TEST_CHECKS
SELECT 'saved review frees one cap slot', '1', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES WHERE is_within_budget
UNION ALL SELECT 'saved review removed before ranking', '27', COUNT(*)::VARCHAR FROM REVIEW_CANDIDATES;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SELECT outputs.* FROM TEST_REVIEW_OUTPUTS AS outputs
WHERE NOT EXISTS (SELECT 1 FROM ANSWER_REVIEWS AS saved WHERE saved.review_id = outputs.review_id);
-- Repeat the same save: errors and invalid outputs must also stay excluded.
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS
SELECT outputs.* FROM TEST_REVIEW_OUTPUTS AS outputs
WHERE NOT EXISTS (SELECT 1 FROM ANSWER_REVIEWS AS saved WHERE saved.review_id = outputs.review_id);

CREATE TEMP TABLE TEST_REC_BASE AS SELECT * FROM RECOMMENDATION_CANDIDATES;
INSERT INTO TEST_CHECKS
SELECT 'recommendation eligibility before saving', '4', COUNT(*)::VARCHAR FROM TEST_REC_BASE
UNION ALL SELECT 'recommendation cap independent of eligibility', '1', COUNT(*)::VARCHAR FROM TEST_REC_BASE WHERE is_within_budget
UNION ALL SELECT 'recommendations deferred before saving', '3', COUNT(*)::VARCHAR FROM REVIEW_QUEUE WHERE queue_status = 'deferred';

CREATE TEMP TABLE TEST_REC_PAYLOAD AS
SELECT PARSE_JSON('{"recommendation_warranted":true,"headline":"Synthetic advice","reasoning":"Synthetic reasoning.","suggested_change":"Use a short answer.","change_mode":"replace","displaced_text":"Synthetic response rule.","preserve_behavior":"Preserve scope.","would_regress_good_behavior":false,"confidence":"low","data_gap_investigation":"","unknown_data_response_guidance":"","citations":[{"url":"https://docs.snowflake.com/en/synthetic-a","quote":"  Synthetic response guidance.  ","supports":"Synthetic support."}]}') AS payload;
CREATE TEMP TABLE TEST_REC_CASES AS
WITH base_cases AS (
    SELECT 'valid_replace' AS case_name, 'instructions.response' AS surface, payload, 'needs_human_review' AS expected FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'cross_surface_replace', 'instructions.response', OBJECT_INSERT(payload, 'displaced_text', 'Synthetic orchestration rule.', TRUE), 'invalid_output' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'wrong_quote', 'instructions.response', OBJECT_INSERT(payload, 'citations', PARSE_JSON('[{"url":"https://docs.snowflake.com/en/synthetic-a","quote":"Synthetic other passage.","supports":"Synthetic support."}]'), TRUE), 'invalid_output' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'no_citation', 'instructions.response', OBJECT_INSERT(payload, 'citations', ARRAY_CONSTRUCT(), TRUE), 'invalid_output' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'extra_field', 'instructions.response', OBJECT_INSERT(payload, 'extra', TRUE), 'invalid_output' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'regression', 'instructions.response', OBJECT_INSERT(payload, 'would_regress_good_behavior', TRUE, TRUE), 'suppressed' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'unwarranted', 'instructions.response', OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(payload, 'recommendation_warranted', FALSE, TRUE), 'change_mode', 'none', TRUE), 'displaced_text', '', TRUE), 'suppressed' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'gap_valid', 'data', OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(payload, 'change_mode', 'investigate', TRUE), 'displaced_text', '', TRUE), 'data_gap_investigation', 'Check the reported scope.', TRUE), 'unknown_data_response_guidance', 'Explain uncertainty and use the approved contact path.', TRUE), 'needs_human_review' FROM TEST_REC_PAYLOAD
    UNION ALL SELECT 'error', 'instructions.response', PARSE_JSON('null'), 'ai_error'
    UNION ALL SELECT 'null_output', 'instructions.response', PARSE_JSON('null'), 'invalid_output'
    UNION ALL SELECT 'missing_' || field.key, 'instructions.response', OBJECT_DELETE(payload, field.key), 'invalid_output'
        FROM TEST_REC_PAYLOAD, LATERAL FLATTEN(INPUT => payload) AS field
    UNION ALL SELECT 'type_' || field.key, 'instructions.response', OBJECT_INSERT(payload, field.key, TO_VARIANT(42), TRUE), 'invalid_output'
        FROM TEST_REC_PAYLOAD, LATERAL FLATTEN(INPUT => payload) AS field
)
SELECT * FROM base_cases
UNION ALL SELECT 'gap_same_actions', surface, OBJECT_INSERT(payload, 'unknown_data_response_guidance', payload:data_gap_investigation, TRUE), 'invalid_output' FROM base_cases WHERE case_name = 'gap_valid'
UNION ALL SELECT 'gap_missing_action', surface, OBJECT_INSERT(payload, 'data_gap_investigation', '', TRUE), 'invalid_output' FROM base_cases WHERE case_name = 'gap_valid'
UNION ALL SELECT 'gap_contact', surface, OBJECT_INSERT(payload, 'data_gap_investigation', 'Ask @invented.', TRUE), 'invalid_output' FROM base_cases WHERE case_name = 'gap_valid'
UNION ALL SELECT 'gap_confirmation', surface, OBJECT_INSERT(payload, 'data_gap_investigation', 'The gap is confirmed.', TRUE), 'invalid_output' FROM base_cases WHERE case_name = 'gap_valid';

CREATE TEMP TABLE TEST_REC_INPUTS AS
SELECT * FROM TEST_REC_BASE WHERE agent_name = 'SYNTH_A';
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATION_INPUTS
SELECT base.recommendation_id || ':' || cases.case_name, group_id, agent_database, agent_schema, agent_name,
       base.surface, config_hash, current_config, target_instructions, investigate_only,
       total_occurrences, total_feedback_pairs, total_good_responses, evidence_members, good_members,
       selected_evidence_members, selected_good_members, examples, counterevidence, service_name,
       documentation_query, retrieval_id, docs_captured_at, docs_content_hash, passages, model_name,
       prompt_revision, schema_revision, instruction_template_hash, generation_policy, sample_policy,
       prompt_hash, prompt_text, started_utc
FROM TEST_REC_INPUTS AS base JOIN TEST_REC_CASES AS cases ON cases.surface = base.surface CROSS JOIN TEST_CLOCK;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATIONS
SELECT base.recommendation_id || ':' || cases.case_name, started_utc,
       OBJECT_CONSTRUCT_KEEP_NULL('value', cases.payload, 'error', IFF(case_name = 'error', 'synthetic failure', NULL))
FROM TEST_REC_INPUTS AS base JOIN TEST_REC_CASES AS cases ON cases.surface = base.surface CROSS JOIN TEST_CLOCK;

INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATION_INPUTS
SELECT recommendation_id, group_id, agent_database, agent_schema, agent_name, surface,
       config_hash, current_config, target_instructions, investigate_only,
       total_occurrences, total_feedback_pairs, total_good_responses, evidence_members, good_members,
       selected_evidence_members, selected_good_members, examples, counterevidence, service_name,
       documentation_query, retrieval_id, docs_captured_at, docs_content_hash, passages, model_name,
       prompt_revision, schema_revision, instruction_template_hash, generation_policy, sample_policy,
       prompt_hash, prompt_text, started_utc
FROM TEST_REC_BASE CROSS JOIN TEST_CLOCK;
CREATE TEMP TABLE TEST_REC_OUTPUTS AS
SELECT base.recommendation_id, started_utc AS generated_at,
       OBJECT_CONSTRUCT_KEEP_NULL('value', cases.payload,
           'error', IFF(cases.case_name = 'error', 'synthetic failure', NULL)) AS model_response,
       cases.expected
FROM TEST_REC_BASE AS base JOIN TEST_REC_CASES AS cases ON cases.case_name =
    CASE WHEN agent_name = 'SYNTH_A' AND base.surface = 'instructions.response' THEN 'valid_replace'
         WHEN agent_name = 'SYNTH_A' THEN 'gap_valid'
         WHEN base.surface = 'instructions.response' THEN 'error' ELSE 'gap_missing_action' END
CROSS JOIN TEST_CLOCK;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATIONS
SELECT outputs.recommendation_id, generated_at, model_response
FROM TEST_REC_OUTPUTS AS outputs JOIN TEST_REC_BASE USING (recommendation_id) WHERE is_within_budget;
INSERT INTO TEST_CHECKS
SELECT 'saved recommendation frees cap slot', '1', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE is_within_budget
UNION ALL SELECT 'three unsaved recommendations remain', '3', COUNT(*)::VARCHAR FROM RECOMMENDATION_CANDIDATES WHERE NOT has_saved_result;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATIONS
SELECT recommendation_id, generated_at, model_response FROM TEST_REC_OUTPUTS AS outputs
WHERE NOT EXISTS (SELECT 1 FROM RECOMMENDATIONS AS saved WHERE saved.recommendation_id = outputs.recommendation_id);
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATIONS
SELECT recommendation_id, generated_at, model_response FROM TEST_REC_OUTPUTS AS outputs
WHERE NOT EXISTS (SELECT 1 FROM RECOMMENDATIONS AS saved WHERE saved.recommendation_id = outputs.recommendation_id);
SELECT 'mock results saved; run assertions.sql next' AS next_step;