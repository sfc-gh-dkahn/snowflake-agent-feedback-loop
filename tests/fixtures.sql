-- NEVER run in production. Read tests/README.md first. ONE session, stop on error.
-- Create the empty OUTPUT_DB.AGENT_FEEDBACK_TEST schema manually first.
-- These nine test tables match production columns/types/nullability, without LIKE.
-- CREATE (not REPLACE/IF NOT EXISTS) refuses an existing installation. No rollback claim.
USE DATABASE OUTPUT_DB;
USE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;

CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS (
    settings_id INTEGER NOT NULL, review_start TIMESTAMP_NTZ NOT NULL,
    review_end TIMESTAMP_NTZ NOT NULL, thread_filter VARCHAR,
    max_new_reviews INTEGER NOT NULL, max_new_recommendations INTEGER NOT NULL,
    min_occurrences INTEGER NOT NULL, docs_max_age_hours INTEGER NOT NULL, prompt_revision VARCHAR NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.CHANGE_AREAS (
    area_key VARCHAR NOT NULL, area_description VARCHAR NOT NULL, documentation_query VARCHAR NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY (
    snapshot_id VARCHAR NOT NULL, captured_at TIMESTAMP_LTZ NOT NULL,
    agent_database VARCHAR NOT NULL, agent_schema VARCHAR NOT NULL, agent_name VARCHAR NOT NULL,
    agent_specification VARIANT NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS (
    event_hash VARCHAR NOT NULL, agent_database VARCHAR NOT NULL, agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL, event_time TIMESTAMP_LTZ NOT NULL, trace_id VARCHAR NOT NULL,
    span_id VARCHAR, span_name VARCHAR, span_type VARCHAR, thread_id VARCHAR, message_id VARCHAR,
    user_question VARCHAR, agent_answer VARCHAR, tool_name VARCHAR, executed_sql VARCHAR,
    chart_definition VARCHAR, status_code VARCHAR, first_saved_at TIMESTAMP_LTZ NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEW_INPUTS (
    review_id VARCHAR NOT NULL, pair_hash VARCHAR NOT NULL, config_hash VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL, agent_schema VARCHAR NOT NULL, agent_name VARCHAR NOT NULL,
    thread_id VARCHAR NOT NULL, response_trace_id VARCHAR NOT NULL, feedback_trace_id VARCHAR NOT NULL,
    feedback_time_utc TIMESTAMP_NTZ NOT NULL, evidence VARIANT NOT NULL, current_config VARIANT NOT NULL,
    model_name VARCHAR NOT NULL, prompt_revision VARCHAR NOT NULL, schema_revision VARCHAR NOT NULL,
    prompt_hash VARCHAR NOT NULL, prompt_text VARCHAR NOT NULL, prepared_at TIMESTAMP_NTZ NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.ANSWER_REVIEWS (
    review_id VARCHAR NOT NULL, reviewed_at TIMESTAMP_NTZ NOT NULL, model_response VARIANT
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS (
    retrieval_id VARCHAR NOT NULL, captured_at TIMESTAMP_NTZ NOT NULL, area_key VARCHAR NOT NULL,
    service_name VARCHAR NOT NULL, query_text VARCHAR NOT NULL, response VARIANT
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATION_INPUTS (
    recommendation_id VARCHAR NOT NULL, group_id VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL, agent_schema VARCHAR NOT NULL, agent_name VARCHAR NOT NULL,
    surface VARCHAR NOT NULL, config_hash VARCHAR NOT NULL, current_config VARIANT NOT NULL,
    target_instructions VARCHAR, investigate_only BOOLEAN NOT NULL,
    total_occurrences NUMBER NOT NULL, total_feedback_pairs NUMBER NOT NULL,
    total_good_responses NUMBER NOT NULL, evidence_members ARRAY NOT NULL, good_members ARRAY NOT NULL,
    selected_evidence_members ARRAY NOT NULL, selected_good_members ARRAY NOT NULL,
    examples ARRAY NOT NULL, counterevidence ARRAY NOT NULL,
    service_name VARCHAR NOT NULL, documentation_query VARCHAR NOT NULL,
    retrieval_id VARCHAR NOT NULL, docs_captured_at TIMESTAMP_NTZ NOT NULL,
    docs_content_hash VARCHAR NOT NULL, passages ARRAY NOT NULL,
    model_name VARCHAR NOT NULL, prompt_revision VARCHAR NOT NULL, schema_revision VARCHAR NOT NULL,
    instruction_template_hash VARCHAR NOT NULL, generation_policy VARCHAR NOT NULL,
    sample_policy VARCHAR NOT NULL, prompt_hash VARCHAR NOT NULL, prompt_text VARCHAR NOT NULL,
    prepared_at TIMESTAMP_NTZ NOT NULL
);
CREATE TABLE OUTPUT_DB.AGENT_FEEDBACK_TEST.RECOMMENDATIONS (
    recommendation_id VARCHAR NOT NULL, generated_at TIMESTAMP_NTZ NOT NULL, model_response VARIANT
);

CREATE TEMP TABLE TEST_CLOCK AS
SELECT DATEADD('day', -2, DATE_TRUNC('day', SYSDATE())) AS base_utc,
       SYSDATE() AS started_utc, CURRENT_SESSION() AS session_id;
CREATE TEMP TABLE TEST_CHECKS (test_name VARCHAR, expected VARCHAR, actual VARCHAR);
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.REVIEW_SETTINGS
SELECT 1, base_utc, DATEADD('day', 1, base_utc), NULL, 1, 1, 1, 168, 'test-v1' FROM TEST_CLOCK;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.CHANGE_AREAS
SELECT column1, 'Synthetic test area', column2 FROM VALUES
    ('instructions.response', 'Cortex Agent response instructions formatting presentation'),
    ('instructions.orchestration', 'Cortex Agent orchestration instructions tool routing planning'),
    ('tool_description', 'Cortex Agent tool_spec tool description selection'),
    ('models.orchestration', 'Cortex Agent orchestration model selection supported models'),
    ('semantic_view', 'Cortex Analyst semantic view dimensions metrics synonyms'),
    ('verified_query', 'Cortex Analyst verified query repository'),
    ('skills', 'Cortex Agent skills staged instructions'),
    ('data', 'Cortex Analyst semantic view base tables data coverage filters');

CREATE TEMP TABLE TEST_AGENTS AS
SELECT column1 AS agent_name, PARSE_JSON(column2) AS specification FROM VALUES
    ('SYNTH_A', '{"instructions":{"response":"Synthetic response rule.","orchestration":"Synthetic orchestration rule."},"tools":[],"empty":{}}'),
    ('SYNTH_B', '{"empty":{},"tools":[],"instructions":{"orchestration":"Synthetic orchestration rule.","response":"Synthetic response rule."}}'),
    ('SYNTH_BAD', '[]');
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_SETTINGS_HISTORY
SELECT agent_name, TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, started_utc), 9),
       'SYNTH_DB', 'SYNTH_SCHEMA', agent_name, specification FROM TEST_AGENTS CROSS JOIN TEST_CLOCK;

CREATE TEMP TABLE TEST_NUMBERS AS
SELECT column1 AS turn_number FROM VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15);
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS
SELECT agent_name || ':t' || LPAD(turn_number::VARCHAR, 2, '0'), 'SYNTH_DB', 'SYNTH_SCHEMA', agent_name,
       TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, DATEADD('second', turn_number, base_utc)), 9),
       't' || LPAD(turn_number::VARCHAR, 2, '0'), 'root', 'synthetic_root', 'record_root', 'core',
       'message-' || turn_number, 'Synthetic question.', 'Synthetic answer.', NULL, NULL, NULL, 'OK',
       TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, started_utc), 9)
FROM TEST_AGENTS CROSS JOIN TEST_NUMBERS CROSS JOIN TEST_CLOCK;

INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS
WITH roots AS (
    SELECT column1 AS event_key, column2 AS trace_id, column3 AS thread_id, column4 AS seconds,
           column5 AS question, column6 AS answer FROM VALUES
        ('b1','b1','broken',-100,'Synthetic question.','Synthetic answer.'),
        ('b2','b2','broken',-99,' \t\r\n','Synthetic answer.'),
        ('b3','b3','broken',-98,'Synthetic question.','Synthetic answer.'),
        ('b4','b4','broken',-97,'Synthetic question.','Synthetic answer.'),
        ('n1','n1',NULL,-90,'Synthetic question.','Synthetic answer.'),
        ('n2','n2',NULL,-89,'Synthetic question.','Synthetic answer.'),
        ('z1','z1','0',-88,'Synthetic question.','Synthetic answer.'),
        ('z2','z2','0',-87,'Synthetic question.','Synthetic answer.'),
        ('w1','w1',' \t\r\n',-86,'Synthetic question.','Synthetic answer.'),
        ('w2','w2',' \t\r\n',-85,'Synthetic question.','Synthetic answer.'),
        ('empty','empty','empty',-80,'Synthetic question.',' \t\r\n'),
        ('redacted','redacted','redacted',-79,'Synthetic question.','[redacted]'),
        ('missing','missing','missing',-78,NULL,'Synthetic answer.'),
        ('d-old','d1','dedup',-71,'Earliest question.','Old answer.'),
        ('d-a','d1','dedup',-70,'Later question.','Wrong answer.'),
        ('d-z','d1','dedup',-70,'Later question.','Selected answer.'),
        ('d2','d2','dedup',-69,'Synthetic question.','Synthetic answer.')
)
SELECT event_key, 'SYNTH_DB', 'SYNTH_SCHEMA', 'SYNTH_A',
       TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, DATEADD('second', seconds, base_utc)), 9),
       trace_id, 'root', 'synthetic_root', 'record_root', thread_id, trace_id,
       question, answer, NULL, NULL, NULL, 'OK', TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, started_utc), 9)
FROM roots CROSS JOIN TEST_CLOCK;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.AGENT_EVENTS
SELECT column1, 'SYNTH_DB', 'SYNTH_SCHEMA', 'SYNTH_A',
       TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, base_utc), 9), column2, column1, column3,
       'tool', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'OK',
       TO_TIMESTAMP_LTZ(DATE_PART(epoch_nanosecond, started_utc), 9)
FROM VALUES ('skill','t01','ServerSkillTool_synthetic'),
            ('chart','t01','CortexChartToolImpl-synthetic'), ('orphan','orphan','synthetic_tool')
CROSS JOIN TEST_CLOCK;

CREATE TEMP TABLE TEST_DOC_RESPONSE AS
SELECT PARSE_JSON('{"results":[{"SOURCE_URL":"https://docs.snowflake.com/en/synthetic-a","DOCUMENT_TITLE":" Synthetic title ","CHUNK":"  Synthetic response guidance.  "},{"SOURCE_URL":"https://docs.snowflake.com/en/synthetic-b","DOCUMENT_TITLE":"Other synthetic title","CHUNK":"Synthetic other passage."}]}') AS response;
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SELECT area_key, DATEADD('hour', IFF(area_key = 'tool_description', -200, -1), started_utc),
       area_key, IFF(area_key = 'semantic_view', 'WRONG.SERVICE.NAME', 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE'),
       IFF(area_key = 'verified_query', 'wrong query', documentation_query), response
FROM CHANGE_AREAS CROSS JOIN TEST_CLOCK CROSS JOIN TEST_DOC_RESPONSE WHERE area_key <> 'skills';
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SELECT 'latest-' || area_key, started_utc, area_key, 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE', documentation_query,
       IFF(area_key = 'instructions.orchestration', PARSE_JSON('{"results":[],"error":"synthetic failure"}'),
           PARSE_JSON('{"results":{}}'))
FROM CHANGE_AREAS CROSS JOIN TEST_CLOCK WHERE area_key IN ('instructions.orchestration','models.orchestration');

CREATE TEMP TABLE TEST_DOC_CASES AS
SELECT column1 AS case_name, PARSE_JSON(column2) AS response, column3 AS expected FROM VALUES
    ('null','null','malformed'), ('array','[]','malformed'), ('missing','{}','malformed'),
    ('empty','{"results":[]}','empty'), ('error','{"results":[],"error":42}','error'),
    ('numeric_url','{"results":[{"SOURCE_URL":42,"DOCUMENT_TITLE":"Title","CHUNK":"Text"}]}','rejected'),
    ('numeric_title','{"results":[{"SOURCE_URL":"https://docs.snowflake.com/x","DOCUMENT_TITLE":42,"CHUNK":"Text"}]}','rejected'),
    ('numeric_chunk','{"results":[{"SOURCE_URL":"https://docs.snowflake.com/x","DOCUMENT_TITLE":"Title","CHUNK":42}]}','rejected'),
    ('lookalike','{"results":[{"SOURCE_URL":"https://docs.snowflake.com.invalid/x","DOCUMENT_TITLE":"Title","CHUNK":"Text"}]}','rejected'),
    ('http','{"results":[{"SOURCE_URL":"http://docs.snowflake.com/x","DOCUMENT_TITLE":"Title","CHUNK":"Text"}]}','rejected'),
    ('blank','{"results":[{"SOURCE_URL":"https://docs.snowflake.com/x","DOCUMENT_TITLE":"Title","CHUNK":" "}]}','rejected');
INSERT INTO OUTPUT_DB.AGENT_FEEDBACK_TEST.DOCUMENTATION_RETRIEVALS
SELECT 'case:' || case_name, started_utc, 'test-only', 'test-only', case_name, response
FROM TEST_DOC_CASES CROSS JOIN TEST_CLOCK;
SELECT 'fixtures' AS stage, (SELECT COUNT(*) FROM AGENT_EVENTS) AS events,
       (SELECT COUNT(*) FROM AGENT_SETTINGS_HISTORY) AS snapshots;
-- Expect 65 events / 3 snapshots. Next install ONLY the named views in tests/README.md.