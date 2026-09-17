-- README: Run only AFTER fixtures.sql, in the SAME SESSION and OPEN transaction.
-- Use the SAME installed, dedicated disposable schema. Never production.
-- Stop on error. Do not COMMIT, run DDL, run procedures, or enable tasks between files.
-- This block returns a summary on success; on failure it SELECTs names/details then
-- raises an exception. Inspect that SELECT in query history if the client hides it.
-- Rollback occurs before the assertion exception and on other errors after the guard.
-- If the guard cannot identify the fixture transaction, it leaves it untouched:
-- inspect the session and run ROLLBACK yourself if fixtures were interrupted.
-- Mocks test validator contracts only, not LLM judgment, factual support, or quality.
-- Extra-key/citation-content rejection belongs to procedure validation, not these UDFs.
-- Authored offline: static tests are NOT Snowflake compilation or live execution.

USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

EXECUTE IMMEDIATE $$
DECLARE
    fixture_count INTEGER;
    fixture_transactions INTEGER;
    fixture_transaction NUMBER;
    checks RESULTSET;
    checks_query_id VARCHAR;
    failure_count INTEGER;
    failure_details VARCHAR;
    unsafe_session EXCEPTION (-20031, 'Run fixtures.sql first in this same session and transaction, using the same disposable rendered installation.');
    assertion_failed EXCEPTION (-20032, 'Fixture assertions failed; the open transaction is rolled back at session scope. Inspect the preceding failure_count/failure_details SELECT in query history.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NULL
        OR CURRENT_DATABASE() <> '__OUTPUT_DATABASE__'
        OR CURRENT_SCHEMA() <> '__OUTPUT_SCHEMA__') THEN
        RAISE unsafe_session;
    END IF;
    SELECT COUNT(*), COUNT(DISTINCT fixture_transaction_id), MIN(fixture_transaction_id)
    INTO :fixture_count, :fixture_transactions, :fixture_transaction
    FROM AF_FIXTURE_EVENTS;
    IF (fixture_count <> 120 OR fixture_transactions <> 1
        OR NOT COALESCE(fixture_transaction = CURRENT_TRANSACTION(), FALSE)) THEN
        RAISE unsafe_session;
    END IF;

    checks := (
        WITH identities AS (
            SELECT column1::VARCHAR AS agent_database, column2::VARCHAR AS agent_schema,
                column3::VARCHAR AS agent_name,
                column1 || '.' || column2 || '.' || column3 || ':' AS identity_prefix
            FROM VALUES
                ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT'),
                ('AF_SYNTH_DB_B', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT'),
                ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_B', 'AF_SYNTH_AGENT'),
                ('AF_SYNTH_DB_A', 'AF_SYNTH_SCHEMA_A', 'AF_SYNTH_AGENT_OTHER')
        ), expected_rows AS (
            SELECT column1::VARCHAR AS trace_id, column2::VARCHAR AS root_key,
                column3::VARCHAR AS thread_id, column4::INTEGER AS turn_no,
                column5::BOOLEAN AS is_complete, column6::VARCHAR AS response_trace_id,
                column7::VARCHAR AS user_message, column8::VARCHAR AS agent_response,
                column9::INTEGER AS second_offset, column10::VARCHAR AS status_code
            FROM VALUES
                ('af_fixture_identity_01', 'identity_01', 'af_fixture_shared', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 0, 'OK'),
                ('af_fixture_identity_02', 'identity_02', 'af_fixture_shared', 2, TRUE, 'af_fixture_identity_01', 'Repeat the synthetic question.', 'Synthetic follow-up answer.', 0, 'OK'),
                ('af_fixture_zero_01', 'zero_01', '0', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 10, 'OK'),
                ('af_fixture_zero_02', 'zero_02', '0', 2, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 11, 'OK'),
                ('af_fixture_null_01', 'null_01', NULL, 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 20, 'OK'),
                ('af_fixture_null_02', 'null_02', NULL, 2, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 21, 'OK'),
                ('af_fixture_space_01', 'space_01', '   ', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 22, 'OK'),
                ('af_fixture_space_02', 'space_02', '   ', 2, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 23, 'OK'),
                ('af_fixture_blank_01', 'blank_01', 'af_fixture_blank', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 30, 'OK'),
                ('af_fixture_blank_02', 'blank_02', 'af_fixture_blank', 2, FALSE, NULL, NULL, 'Synthetic answer.', 31, 'OK'),
                ('af_fixture_blank_03', 'blank_03', 'af_fixture_blank', 3, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 32, 'OK'),
                ('af_fixture_blank_04', 'blank_04', 'af_fixture_blank', 4, TRUE, 'af_fixture_blank_03', 'Synthetic question.', 'Synthetic answer.', 33, 'OK'),
                ('af_fixture_redacted_01', 'redacted_01', 'af_fixture_redacted', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 40, 'OK'),
                ('af_fixture_redacted_02', 'redacted_02', 'af_fixture_redacted', 2, FALSE, NULL, 'Synthetic question.', '[redacted]', 41, 'OK'),
                ('af_fixture_redacted_03', 'redacted_03', 'af_fixture_redacted', 3, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 42, 'OK'),
                ('af_fixture_missing_01', 'missing_01', 'af_fixture_missing', 1, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 43, 'OK'),
                ('af_fixture_missing_02', 'missing_02', 'af_fixture_missing', 2, FALSE, NULL, 'Synthetic question.', NULL, 44, 'ERROR'),
                ('af_fixture_missing_03', 'missing_03', 'af_fixture_missing', 3, TRUE, NULL, 'Synthetic question.', 'Synthetic answer.', 45, 'OK'),
                ('af_fixture_dedup_01', 'dedup_hash_z', 'af_fixture_dedup', 1, TRUE, NULL, 'First readable synthetic question.', 'Selected synthetic answer.', 50, 'OK'),
                ('af_fixture_dedup_02', 'dedup_02', 'af_fixture_dedup', 2, TRUE, 'af_fixture_dedup_01', 'Synthetic question.', 'Synthetic answer.', 51, 'OK')
        ), expected AS (
            SELECT identities.*, expected_rows.* FROM identities CROSS JOIN expected_rows
        ), actual AS (
            SELECT turns.* FROM AF_TURNS AS turns
            JOIN identities USING (agent_database, agent_schema, agent_name)
        ), expected_pairs AS (
            SELECT * FROM expected WHERE response_trace_id IS NOT NULL
        ), actual_pairs AS (
            SELECT pairs.* FROM AF_FEEDBACK_PAIRS AS pairs
            JOIN identities USING (agent_database, agent_schema, agent_name)
        ), expected_tool_rows AS (
            SELECT column1::INTEGER AS tool_index, column2::VARCHAR AS event_key
            FROM VALUES (0, 'sql_early'), (1, 'sql_tie_a'), (2, 'sql_tie_z'),
                (3, 'sql_late'), (4, 'skill'), (5, 'chart')
        ), expected_tools AS (
            SELECT identities.*, expected_tool_rows.*,
                fixture.span_id, fixture.span_name, fixture.tool_name, fixture.final_sql,
                fixture.chart_spec, fixture.status_code, DATE_PART(epoch_nanosecond, fixture.event_ts) AS event_epoch_ns
            FROM identities CROSS JOIN expected_tool_rows
            JOIN AF_FIXTURE_EVENTS AS fixture
              ON fixture.event_hash = identities.identity_prefix || expected_tool_rows.event_key
        ), actual_tools AS (
            SELECT actual.agent_database, actual.agent_schema, actual.agent_name,
                actual.trace_id, tool.index AS tool_index, tool.value AS payload
            FROM actual, LATERAL FLATTEN(INPUT => actual.tool_evidence) AS tool
        ), expected_event_rows AS (
            SELECT column1::VARCHAR AS trace_id, column2::INTEGER AS event_index,
                column3::VARCHAR AS event_key
            FROM VALUES
                ('af_fixture_identity_01', 0, 'identity_01'),
                ('af_fixture_identity_01', 1, 'sql_early'),
                ('af_fixture_identity_01', 2, 'sql_tie_a'),
                ('af_fixture_identity_01', 3, 'sql_tie_z'),
                ('af_fixture_identity_01', 4, 'sql_late'),
                ('af_fixture_identity_01', 5, 'skill'),
                ('af_fixture_identity_01', 6, 'chart'),
                ('af_fixture_dedup_01', 0, 'dedup_old'),
                ('af_fixture_dedup_01', 1, 'dedup_span_a'),
                ('af_fixture_dedup_01', 2, 'dedup_hash_a'),
                ('af_fixture_dedup_01', 3, 'dedup_hash_z')
        ), expected_events AS (
            SELECT identities.*, expected_event_rows.*
            FROM identities CROSS JOIN expected_event_rows
            UNION ALL
            SELECT agent_database, agent_schema, agent_name, identity_prefix,
                trace_id, 0, root_key FROM expected
            WHERE trace_id NOT IN ('af_fixture_identity_01', 'af_fixture_dedup_01')
        ), actual_events AS (
            SELECT actual.agent_database, actual.agent_schema, actual.agent_name,
                actual.trace_id, event.index AS event_index, event.value::VARCHAR AS event_hash
            FROM actual, LATERAL FLATTEN(INPUT => actual.event_hashes) AS event
        ), verdicts AS (
            SELECT column1::VARCHAR AS kind, PARSE_JSON(column2) AS payload
            FROM VALUES
                ('diagnosis', '{"assessment":"poor","issue_type":"agent_behavior","severity":"moderate","surface":"instructions.response","observation":"Synthetic format mismatch.","evidence_quote":"Synthetic answer.","suspected_cause":"unknown","preserve_behavior":"Preserve synthetic scope.","requires_review":true}'),
                ('recommendation', '{"recommendation_warranted":true,"headline":"Review synthetic formatting.","reasoning":"Synthetic mock only.","suggested_change":"Investigate formatting.","change_mode":"investigate","displaced_text":"","preserve_behavior":"Preserve synthetic scope.","would_regress_good_behavior":false,"confidence":"low","citations":[]}')
        ), contract_cases AS (
            SELECT kind, 'valid_base' AS case_name, payload, TRUE AS expected_valid FROM verdicts
            UNION ALL
            SELECT kind, 'missing_' || field.key, OBJECT_DELETE(payload::OBJECT, field.key), FALSE
            FROM verdicts, LATERAL FLATTEN(INPUT => payload) AS field
            UNION ALL
            SELECT kind, 'null_' || field.key,
                OBJECT_INSERT(payload::OBJECT, field.key, PARSE_JSON('null'), TRUE), FALSE
            FROM verdicts, LATERAL FLATTEN(INPUT => payload) AS field
            UNION ALL
            SELECT kind, 'wrong_type_' || field.key,
                OBJECT_INSERT(payload::OBJECT, field.key,
                    IFF(IS_VARCHAR(field.value), TO_VARIANT(123), TO_VARIANT('false')), TRUE), FALSE
            FROM verdicts, LATERAL FLATTEN(INPUT => payload) AS field
            UNION ALL
            SELECT kind, 'sql_null', NULL, FALSE FROM verdicts
            UNION ALL
            SELECT kind, 'json_null', PARSE_JSON('null'), FALSE FROM verdicts
            UNION ALL
            SELECT kind, 'empty_object', PARSE_JSON('{}'), FALSE FROM verdicts
            UNION ALL
            SELECT kind, 'array', PARSE_JSON('[]'), FALSE FROM verdicts
            UNION ALL
            SELECT kind, 'blank_observation', OBJECT_INSERT(payload::OBJECT, 'observation', '   ', TRUE), FALSE
            FROM verdicts WHERE kind = 'diagnosis'
            UNION ALL
            SELECT kind, 'blank_quote', OBJECT_INSERT(payload::OBJECT, 'evidence_quote', '', TRUE), FALSE
            FROM verdicts WHERE kind = 'diagnosis'
            UNION ALL
            SELECT kind, 'good_mock', OBJECT_INSERT(payload::OBJECT, 'assessment', 'good', TRUE), TRUE
            FROM verdicts WHERE kind = 'diagnosis'
            UNION ALL
            SELECT kind, 'unclear_mock', OBJECT_INSERT(payload::OBJECT, 'assessment', 'unclear', TRUE), TRUE
            FROM verdicts WHERE kind = 'diagnosis'
            UNION ALL
            SELECT kind, 'blank_headline', OBJECT_INSERT(payload::OBJECT, 'headline', '   ', TRUE), FALSE
            FROM verdicts WHERE kind = 'recommendation'
            UNION ALL
            SELECT kind, 'blank_warranted_change', OBJECT_INSERT(payload::OBJECT, 'suggested_change', '', TRUE), FALSE
            FROM verdicts WHERE kind = 'recommendation'
            UNION ALL
            SELECT kind, 'warranted_none', OBJECT_INSERT(payload::OBJECT, 'change_mode', 'none', TRUE), FALSE
            FROM verdicts WHERE kind = 'recommendation'
            UNION ALL
            SELECT kind, 'replace_without_text', OBJECT_INSERT(payload::OBJECT, 'change_mode', 'replace', TRUE), FALSE
            FROM verdicts WHERE kind = 'recommendation'
            UNION ALL
            SELECT kind, 'replace_with_text', OBJECT_INSERT(OBJECT_INSERT(payload::OBJECT,
                'change_mode', 'replace', TRUE), 'displaced_text', 'Synthetic instruction.', TRUE), TRUE
            FROM verdicts WHERE kind = 'recommendation'
            UNION ALL
            SELECT kind, 'not_warranted', OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(payload::OBJECT,
                'recommendation_warranted', FALSE, TRUE), 'change_mode', 'none', TRUE), 'suggested_change', '', TRUE), TRUE
            FROM verdicts WHERE kind = 'recommendation'
        ), contract_results AS (
            SELECT kind, case_name, expected_valid, AF_DIAGNOSIS_VALID(payload) AS actual_valid
            FROM contract_cases WHERE kind = 'diagnosis'
            UNION ALL
            SELECT kind, case_name, expected_valid, AF_RECOMMENDATION_VALID(payload)
            FROM contract_cases WHERE kind = 'recommendation'
        ), text_cases AS (
            SELECT column1::VARCHAR AS text_value, column2::BOOLEAN AS expected_present
            FROM VALUES (NULL, FALSE), ('', FALSE), ('   ', FALSE), ('1', FALSE),
                ('null', FALSE), ('[redacted]', FALSE), ('<redacted>', FALSE),
                (' ReDaCtEd ', FALSE), ('Synthetic content.', TRUE)
        ), failures AS (
            SELECT 'turn_contract' AS check_name,
                COALESCE(expected.agent_database, actual.agent_database) || '.'
                || COALESCE(expected.agent_schema, actual.agent_schema) || '.'
                || COALESCE(expected.agent_name, actual.agent_name) || ':'
                || COALESCE(expected.trace_id, actual.trace_id) AS detail
            FROM expected FULL OUTER JOIN actual
                USING (agent_database, agent_schema, agent_name, trace_id)
            WHERE expected.trace_id IS NULL OR actual.trace_id IS NULL
                OR actual.root_event_hash IS DISTINCT FROM expected.identity_prefix || expected.root_key
                OR actual.thread_id IS DISTINCT FROM expected.thread_id
                OR actual.turn_no IS DISTINCT FROM expected.turn_no
                OR actual.is_complete IS DISTINCT FROM expected.is_complete
                OR actual.user_message IS DISTINCT FROM expected.user_message
                OR actual.agent_response IS DISTINCT FROM expected.agent_response
                OR actual.status_code IS DISTINCT FROM expected.status_code
                OR actual.message_id IS DISTINCT FROM expected.trace_id || '_message'
                OR actual.event_ts IS DISTINCT FROM DATEADD('second', expected.second_offset, '2001-01-01T00:00:00+00:00'::TIMESTAMP_LTZ)
                OR NOT COALESCE(REGEXP_LIKE(actual.turn_hash, '[0-9a-fA-F]{64}'), FALSE)
            UNION ALL
            SELECT 'turn_cardinality', 'Expected 80 turns and 80 distinct identity-sensitive hashes.'
            WHERE (SELECT COUNT(*) FROM actual) <> 80
                OR (SELECT COUNT(DISTINCT turn_hash) FROM actual) <> 80
            UNION ALL
            SELECT 'pair_contract', COALESCE(expected_pairs.trace_id, actual_pairs.trace_id)
            FROM expected_pairs FULL OUTER JOIN actual_pairs
                USING (agent_database, agent_schema, agent_name, trace_id)
            WHERE expected_pairs.trace_id IS NULL OR actual_pairs.trace_id IS NULL
                OR actual_pairs.response_trace_id IS DISTINCT FROM expected_pairs.response_trace_id
            UNION ALL
            SELECT 'pair_cardinality', 'Expected exactly 12 adjacent complete pairs.'
            WHERE (SELECT COUNT(*) FROM actual_pairs) <> 12
            UNION ALL
            SELECT 'response_hash', pairs.trace_id FROM actual_pairs AS pairs
            LEFT JOIN actual AS response
              ON response.agent_database = pairs.agent_database AND response.agent_schema = pairs.agent_schema
             AND response.agent_name = pairs.agent_name AND response.trace_id = pairs.response_trace_id
            WHERE pairs.response_turn_hash IS DISTINCT FROM response.turn_hash
            UNION ALL
            SELECT 'tool_contract', COALESCE(expected_tools.event_key, actual_tools.trace_id)
            FROM expected_tools FULL OUTER JOIN actual_tools
              ON expected_tools.agent_database = actual_tools.agent_database
             AND expected_tools.agent_schema = actual_tools.agent_schema
             AND expected_tools.agent_name = actual_tools.agent_name
             AND actual_tools.trace_id = 'af_fixture_identity_01'
             AND expected_tools.tool_index = actual_tools.tool_index
            WHERE expected_tools.event_key IS NULL OR actual_tools.trace_id IS NULL
                OR actual_tools.payload:event_hash::VARCHAR IS DISTINCT FROM expected_tools.identity_prefix || expected_tools.event_key
                OR actual_tools.payload:span_id::VARCHAR IS DISTINCT FROM expected_tools.span_id
                OR actual_tools.payload:span_name::VARCHAR IS DISTINCT FROM expected_tools.span_name
                OR actual_tools.payload:tool_name::VARCHAR IS DISTINCT FROM expected_tools.tool_name
                OR actual_tools.payload:final_sql::VARCHAR IS DISTINCT FROM expected_tools.final_sql
                OR actual_tools.payload:chart_spec::VARCHAR IS DISTINCT FROM expected_tools.chart_spec
                OR actual_tools.payload:status_code::VARCHAR IS DISTINCT FROM expected_tools.status_code
                OR actual_tools.payload:event_epoch_ns::NUMBER IS DISTINCT FROM expected_tools.event_epoch_ns
                OR ARRAY_SIZE(OBJECT_KEYS(actual_tools.payload)) IS DISTINCT FROM 8
            UNION ALL
            SELECT 'event_order', COALESCE(expected_events.event_key, actual_events.event_hash)
            FROM expected_events FULL OUTER JOIN actual_events
                USING (agent_database, agent_schema, agent_name, trace_id, event_index)
            WHERE expected_events.event_key IS NULL OR actual_events.event_hash IS NULL
                OR actual_events.event_hash IS DISTINCT FROM expected_events.identity_prefix || expected_events.event_key
            UNION ALL
            SELECT kind || '_contract', case_name FROM contract_results
            WHERE actual_valid IS DISTINCT FROM expected_valid
            UNION ALL
            SELECT 'text_present', COALESCE(text_value, 'SQL NULL') FROM text_cases
            WHERE AF_TEXT_PRESENT(text_value) IS DISTINCT FROM expected_present
            UNION ALL
            SELECT 'fixture_rows', 'Expected exactly 120 uncommitted synthetic events.'
            WHERE (SELECT COUNT(*) FROM AF_EVENTS) <> 120
        )
        SELECT check_name, detail FROM failures ORDER BY check_name, detail
    );
    checks_query_id := SQLID;
    SELECT COUNT(*), LISTAGG(check_name || ': ' || detail, '\n')
        WITHIN GROUP (ORDER BY check_name, detail)
    INTO :failure_count, :failure_details
    FROM TABLE(RESULT_SCAN(:checks_query_id));
    IF (failure_count <> 0) THEN
        SELECT :failure_count AS failure_count, :failure_details AS failure_details;
        RAISE assertion_failed;
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'CHECKS_PASS', 'failure_count', failure_count,
        'events_tested', 120, 'turns_tested', 80, 'pairs_tested', 12,
        'rolled_back', FALSE, 'inference_performed', FALSE);
END;
$$;

-- Transaction control stays at session scope. Snowflake refuses to let a
-- scripting block modify a transaction that began outside its own scope, so
-- the rollback cannot live inside the block above. If the block raised, this
-- statement does not run and disconnecting discards the uncommitted rows.
ROLLBACK;

EXECUTE IMMEDIATE $$
DECLARE
    remaining_events INTEGER;
    cleanup_failed EXCEPTION (-20033, 'Rollback did not clear AF_EVENTS; inspect concurrent writers or transaction handling.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL) THEN
        RAISE cleanup_failed;
    END IF;
    SELECT COUNT(*) INTO :remaining_events FROM AF_EVENTS;
    IF (remaining_events <> 0) THEN
        RAISE cleanup_failed;
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'PASS', 'failure_count', 0,
        'events_tested', 120, 'turns_tested', 80, 'pairs_tested', 12,
        'rolled_back', TRUE, 'inference_performed', FALSE);
END;
$$;