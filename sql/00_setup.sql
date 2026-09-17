USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE TABLE AF_CONFIG (
    config_id INTEGER NOT NULL,
    agent_database VARCHAR NOT NULL,
    agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL,
    judge_model VARCHAR NOT NULL,
    docs_service VARCHAR,
    lookback_days INTEGER NOT NULL,
    max_diagnoses INTEGER NOT NULL,
    max_recommendations INTEGER NOT NULL,
    min_occurrences INTEGER NOT NULL,
    docs_cache_hours INTEGER NOT NULL,
    prompt_revision VARCHAR NOT NULL
);

INSERT INTO AF_CONFIG VALUES (
    1, '__AGENT_DATABASE__', '__AGENT_SCHEMA__', '__AGENT_NAME__',
    '__JUDGE_MODEL__', NULL, 14, 20, 5, 2, 168, '2'
);

CREATE TABLE AF_RUNS (
    run_id VARCHAR NOT NULL,
    started_at TIMESTAMP_LTZ NOT NULL,
    completed_at TIMESTAMP_LTZ,
    window_start TIMESTAMP_LTZ NOT NULL,
    window_end TIMESTAMP_LTZ NOT NULL,
    thread_filter VARCHAR,
    status VARCHAR NOT NULL,
    stage VARCHAR NOT NULL,
    diagnostics VARIANT,
    error_message VARCHAR
);

CREATE TABLE AF_CONFIG_SNAPSHOTS (
    run_id VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL,
    agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL,
    captured_at TIMESTAMP_LTZ NOT NULL,
    config_hash VARCHAR NOT NULL,
    agent_spec VARIANT NOT NULL
);

CREATE TABLE AF_EVENTS (
    event_hash VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL,
    agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL,
    event_ts TIMESTAMP_LTZ NOT NULL,
    trace_id VARCHAR NOT NULL,
    span_id VARCHAR,
    span_name VARCHAR,
    span_type VARCHAR,
    thread_id VARCHAR,
    message_id VARCHAR,
    user_message VARCHAR,
    agent_response VARCHAR,
    tool_name VARCHAR,
    final_sql VARCHAR,
    chart_spec VARCHAR,
    status_code VARCHAR,
    first_seen_at TIMESTAMP_LTZ NOT NULL
);

CREATE TABLE AF_RUN_FEEDBACK (
    run_id VARCHAR NOT NULL,
    diagnosis_id VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL,
    agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL,
    thread_id VARCHAR NOT NULL,
    response_trace_id VARCHAR NOT NULL,
    feedback_trace_id VARCHAR NOT NULL,
    feedback_ts TIMESTAMP_LTZ NOT NULL,
    evidence VARIANT NOT NULL,
    current_config VARIANT NOT NULL,
    config_hash VARCHAR NOT NULL,
    judge_model VARCHAR NOT NULL,
    prompt_revision VARCHAR NOT NULL
);

CREATE TABLE AF_DIAGNOSES (
    diagnosis_id VARCHAR NOT NULL,
    created_at TIMESTAMP_LTZ NOT NULL,
    raw_output VARIANT,
    validation_status VARCHAR NOT NULL,
    error_message VARCHAR
);

CREATE TABLE AF_SUPPORTED_AREAS (
    surface VARCHAR NOT NULL,
    retrieval_query VARCHAR NOT NULL
);

INSERT INTO AF_SUPPORTED_AREAS VALUES
    ('instructions.response', 'Cortex Agent response instructions formatting presentation'),
    ('instructions.orchestration', 'Cortex Agent orchestration instructions tool routing planning'),
    ('tool_description', 'Cortex Agent tool_spec tool description selection'),
    ('models.orchestration', 'Cortex Agent orchestration model selection supported models'),
    ('semantic_view', 'Cortex Analyst semantic view dimensions metrics synonyms'),
    ('verified_query', 'Cortex Analyst verified query repository'),
    ('skills', 'Cortex Agent skills staged instructions'),
    ('data', 'Cortex Analyst semantic view base tables data coverage filters');

CREATE TABLE AF_DOC_CACHE (
    service_name VARCHAR NOT NULL,
    surface VARCHAR NOT NULL,
    query_hash VARCHAR NOT NULL,
    retrieved_at TIMESTAMP_LTZ NOT NULL,
    content_hash VARCHAR NOT NULL,
    passages VARIANT NOT NULL
);

CREATE TABLE AF_RECOMMENDATIONS (
    recommendation_id VARCHAR NOT NULL,
    run_id VARCHAR NOT NULL,
    agent_database VARCHAR NOT NULL,
    agent_schema VARCHAR NOT NULL,
    agent_name VARCHAR NOT NULL,
    surface VARCHAR NOT NULL,
    evidence VARIANT NOT NULL,
    docs VARIANT,
    docs_status VARCHAR NOT NULL,
    created_at TIMESTAMP_LTZ NOT NULL,
    raw_output VARIANT,
    review_status VARCHAR NOT NULL,
    error_message VARCHAR
);

CREATE FUNCTION AF_DIAGNOSIS_VALID(result VARIANT)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
    COALESCE(
        IS_OBJECT(result)
        AND result:assessment::VARCHAR IN ('good', 'poor', 'unclear')
        AND result:issue_type::VARCHAR IN ('agent_behavior', 'reported_data_gap', 'none', 'unclear')
        AND result:severity::VARCHAR IN ('low', 'moderate', 'severe')
        AND result:surface::VARCHAR IN (
            'instructions.response', 'instructions.orchestration', 'tool_description',
            'models.orchestration', 'semantic_view', 'verified_query', 'skills', 'data', 'none')
        AND IS_VARCHAR(result:observation)
        AND LENGTH(TRIM(result:observation::VARCHAR)) > 0
        AND IS_VARCHAR(result:evidence_quote)
        AND LENGTH(TRIM(result:evidence_quote::VARCHAR)) > 0
        AND IS_VARCHAR(result:suspected_cause)
        AND IS_VARCHAR(result:preserve_behavior)
        AND IS_BOOLEAN(result:requires_review), FALSE)
$$;

CREATE FUNCTION AF_RECOMMENDATION_VALID(result VARIANT)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
    COALESCE(
        IS_OBJECT(result)
        AND IS_BOOLEAN(result:recommendation_warranted)
        AND IS_VARCHAR(result:headline)
        AND LENGTH(TRIM(result:headline::VARCHAR)) > 0
        AND IS_VARCHAR(result:suggested_change)
        AND IS_VARCHAR(result:reasoning)
        AND IS_VARCHAR(result:preserve_behavior)
        AND result:change_mode::VARCHAR IN ('append', 'replace', 'investigate', 'none')
        AND IS_VARCHAR(result:displaced_text)
        AND IS_VARCHAR(result:data_gap_investigation)
        AND IS_VARCHAR(result:unknown_data_response_guidance)
        AND IS_BOOLEAN(result:would_regress_good_behavior)
        AND result:confidence::VARCHAR IN ('low', 'medium', 'high')
        AND IS_ARRAY(result:citations)
        AND (NOT result:recommendation_warranted::BOOLEAN
             OR (LENGTH(TRIM(result:suggested_change::VARCHAR)) > 0
                 AND result:change_mode::VARCHAR <> 'none'))
        AND (result:change_mode::VARCHAR <> 'replace'
             OR LENGTH(TRIM(result:displaced_text::VARCHAR)) > 0), FALSE)
$$;