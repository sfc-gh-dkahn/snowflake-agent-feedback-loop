-- =============================================================================
-- AGENT FEEDBACK LOOP: Retrieve and save official documentation
-- =============================================================================
-- Customize OUTPUT_DB, AGENT_FEEDBACK, and every DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE
-- literal before running. The existing service must expose SOURCE_URL,
-- DOCUMENT_TITLE, and CHUNK. This file does not create a search service.
--
-- DOCUMENTATION_RETRIEVALS -> DOCUMENTATION_PASSAGES  accepted text, unchanged
--                         -> DOCUMENTATION_STATUS    every saved response
--                         -> DOCUMENTATION_LATEST    latest exact search, good or bad
--
-- Section 2 makes EIGHT paid searches on every full run, even when saved text
-- is fresh. There is no automatic cache or WHERE-based paid-call suppression.
-- For a manual refresh of one area, run only its INSERT, then the inspections.
-- REVIEW_SETTINGS limits do not cap these eight searches.
--
-- Run sequentially, without concurrent writers. Stop on ANY SQL failure:
-- a failed INSERT cannot save its response or an error row. Earlier inserts
-- remain committed with AUTOCOMMIT enabled. Do not proceed to recommendations
-- using old documentation after a failed search; resolve it and retry explicitly.
-- Retries can incur charges again. Status views cannot detect an unsaved failure.
--
-- SEARCH_PREVIEW requires constant arguments and returns an OBJECT with results[].
-- Its documented API remains SNOWFLAKE.CORTEX.SEARCH_PREVIEW, not an AI_* alias:
-- https://docs.snowflake.com/en/sql-reference/functions/search_preview-snowflake-cortex
-- The API can truncate results beyond 300 kB. We keep exactly what it returns,
-- not a claim of full-document coverage. A matching URL does not prove entailment.
--
-- CHANGE_AREAS holds the default query reference, not executable API arguments.
-- Edit BOTH query literals in an INSERT if changing its query, and align the
-- area's documentation_query separately. Never include customer or event text.

USE DATABASE OUTPUT_DB;
USE SCHEMA AGENT_FEEDBACK;

-- =============================================================================
-- 1. APPEND-ONLY STORAGE AND READ-ONLY PROJECTIONS
-- =============================================================================
-- One row per successful INSERT execution, including unusable responses.
-- UUID_STRING is the retrieval identity; it is never the content identity.
-- IF NOT EXISTS preserves history; it does not migrate an older table definition.

CREATE TABLE IF NOT EXISTS DOCUMENTATION_RETRIEVALS (
    retrieval_id VARCHAR NOT NULL,
    captured_at  TIMESTAMP_NTZ NOT NULL,
    area_key     VARCHAR NOT NULL,
    service_name VARCHAR NOT NULL,
    query_text   VARCHAR NOT NULL,
    response     VARIANT
);

CREATE OR REPLACE VIEW DOCUMENTATION_PASSAGES AS
WITH saved_results AS (
    SELECT retrieval_id, captured_at, area_key, service_name, query_text,
           IFF(IS_OBJECT(response) AND IS_ARRAY(response:results)
               AND (response:error IS NULL OR IS_NULL_VALUE(response:error)),
               response:results, ARRAY_CONSTRUCT()) AS results
    FROM DOCUMENTATION_RETRIEVALS
),
typed_passages AS (
    SELECT saved_results.retrieval_id, saved_results.captured_at,
           saved_results.area_key, saved_results.service_name, saved_results.query_text,
           passage.index AS passage_index,
           IFF(IS_VARCHAR(passage.value:SOURCE_URL),
               passage.value:SOURCE_URL::VARCHAR, NULL) AS url,
           IFF(IS_VARCHAR(passage.value:DOCUMENT_TITLE),
               passage.value:DOCUMENT_TITLE::VARCHAR, NULL) AS title,
           IFF(IS_VARCHAR(passage.value:CHUNK),
               passage.value:CHUNK::VARCHAR, NULL) AS chunk
    FROM saved_results, LATERAL FLATTEN(INPUT => saved_results.results) AS passage
    WHERE IS_OBJECT(passage.value)
)
SELECT retrieval_id, captured_at, area_key, service_name, query_text,
       passage_index, url, title, chunk,
       SHA2(TO_JSON(ARRAY_CONSTRUCT(url, title, chunk)), 256) AS passage_id
FROM typed_passages
WHERE STARTSWITH(url, 'https://docs.snowflake.com/')
  AND LENGTH(url) <= 2048
  AND NOT REGEXP_LIKE(url, '.*[[:space:][:cntrl:]].*', 's')
  AND NOT CONTAINS(url, CHR(92))
  AND LENGTH(TRIM(title, ' \t\r\n')) > 0
  AND LENGTH(TRIM(chunk, ' \t\r\n')) > 0;

-- The exact prefix includes the slash after the host: lookalike domains,
-- userinfo, ports, and HTTP fail. Reject backslashes and whitespace too.
-- TRIM tests presence only. Projected title/chunk and both hashes use the
-- original strings: no trimming, truncation, or rewriting of quotation evidence.

CREATE OR REPLACE VIEW DOCUMENTATION_STATUS AS
WITH response_shape AS (
    SELECT retrieval_id, captured_at, area_key, service_name, query_text,
           NOT COALESCE(IS_OBJECT(response) AND IS_ARRAY(response:results), FALSE)
               AS malformed_envelope,
           COALESCE(IS_OBJECT(response) AND response:error IS NOT NULL
                    AND NOT IS_NULL_VALUE(response:error), FALSE) AS has_error,
           COALESCE(ARRAY_SIZE(IFF(IS_ARRAY(response:results),
                                  response:results, ARRAY_CONSTRUCT())), 0)
               AS result_count
    FROM DOCUMENTATION_RETRIEVALS
),
accepted_counts AS (
    SELECT retrieval_id, COUNT(*) AS accepted_count
    FROM DOCUMENTATION_PASSAGES
    GROUP BY retrieval_id
),
counted_results AS (
    SELECT response_shape.*,
           COALESCE(accepted_counts.accepted_count, 0) AS accepted_count,
           response_shape.result_count - COALESCE(accepted_counts.accepted_count, 0)
               AS rejected_count
    FROM response_shape
    LEFT JOIN accepted_counts USING (retrieval_id)
)
SELECT retrieval_id, captured_at, area_key, service_name, query_text,
       malformed_envelope, has_error, result_count, accepted_count, rejected_count,
       CASE
           WHEN has_error THEN 'error'
           WHEN malformed_envelope THEN 'malformed'
           WHEN result_count = 0 THEN 'empty'
           WHEN accepted_count = 0 THEN 'rejected'
           ELSE 'ready'
       END AS documentation_status
FROM counted_results;

-- Every retrieval stays visible, including NULL/nonobject envelopes and rejected
-- rows. Counts describe array entries only; malformed nonarrays have zero entries.
-- A mixed result is ready with rejected_count > 0; only accepted text is usable.

CREATE OR REPLACE VIEW DOCUMENTATION_LATEST AS
WITH latest_search AS (
    SELECT *
    FROM DOCUMENTATION_STATUS
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY area_key, service_name, query_text
        ORDER BY captured_at DESC, retrieval_id DESC) = 1
),
content_hashes AS (
    SELECT passage.retrieval_id,
           SHA2(TO_JSON(ARRAY_AGG(passage.passage_id)
               WITHIN GROUP (ORDER BY passage.passage_id)), 256) AS content_hash
    FROM DOCUMENTATION_PASSAGES AS passage
    JOIN latest_search ON latest_search.retrieval_id = passage.retrieval_id
    GROUP BY passage.retrieval_id
)
SELECT latest_search.*,
       COALESCE(content_hashes.content_hash, SHA2('[]', 256)) AS content_hash
FROM latest_search
LEFT JOIN content_hashes USING (retrieval_id);

-- Sorted scalar IDs make content_hash independent of search order and capture
-- identity/time. Duplicate passages remain counted and hashed. No objects are
-- serialized for identity. An empty accepted set hashes []; check status too.
-- Latest is selected BEFORE checking status/freshness. Never fall back to an
-- older ready response when the latest exact search is empty, malformed or error.

-- =============================================================================
-- 2. EIGHT EXPLICIT SEARCH WRITES
-- =============================================================================
-- Each SELECT reads only literals. Keep the saved service/query equal to the
-- two API arguments. The JSON columns and limit (5) are intentional constants.

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'instructions.response',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Agent response instructions formatting presentation',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Agent response instructions formatting presentation","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'instructions.orchestration',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Agent orchestration instructions tool routing planning',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Agent orchestration instructions tool routing planning","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'tool_description',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Agent tool_spec tool description selection',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Agent tool_spec tool description selection","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'models.orchestration',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Agent orchestration model selection supported models',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Agent orchestration model selection supported models","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'semantic_view',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Analyst semantic view dimensions metrics synonyms',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Analyst semantic view dimensions metrics synonyms","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'verified_query',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Analyst verified query repository',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Analyst verified query repository","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'skills',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Agent skills staged instructions',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Agent skills staged instructions","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

INSERT INTO DOCUMENTATION_RETRIEVALS
    (retrieval_id, captured_at, area_key, service_name, query_text, response)
SELECT UUID_STRING(), SYSDATE(), 'data',
       'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
       'Cortex Analyst semantic view base tables data coverage filters',
       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE',
           '{"query":"Cortex Analyst semantic view base tables data coverage filters","columns":["SOURCE_URL","DOCUMENT_TITLE","CHUNK"],"limit":5}');

-- =============================================================================
-- 3. INSPECT SAVED RESULTS BEFORE CONTINUING
-- =============================================================================
-- No search or inference below. Inspect all history, not only successful rows.
-- Confirm captured_at for each area belongs to the refresh you just performed.

SELECT *
FROM DOCUMENTATION_STATUS
WHERE service_name = 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE'
ORDER BY captured_at DESC, retrieval_id DESC;

-- Mismatches remain visible: changing CHANGE_AREAS does not change the API calls.
-- An older query may legitimately differ; the exact-query readiness check follows.

SELECT COALESCE(areas.area_key, latest.area_key) AS area_key,
       areas.documentation_query, latest.query_text AS saved_query_text,
       latest.service_name, latest.retrieval_id,
       CASE
           WHEN areas.area_key IS NULL THEN 'area_not_configured'
           WHEN latest.retrieval_id IS NULL THEN 'not_retrieved'
           WHEN areas.documentation_query <> latest.query_text THEN 'query_mismatch'
           ELSE 'query_matches'
       END AS query_alignment
FROM CHANGE_AREAS AS areas
FULL OUTER JOIN (
    SELECT * FROM DOCUMENTATION_LATEST
    WHERE service_name = 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE'
) AS latest ON latest.area_key = areas.area_key
ORDER BY area_key, saved_query_text;

-- This inspection is advisory. Step 6 must enforce the same exact area/query/
-- literal-service join, valid settings, ready status and UTC age in its paid-input
-- selection, then join passages by retrieval_id. Do not filter success before
-- choosing latest. Read the settings status even if there are no configured areas.

SELECT * FROM ANSWER_REVIEW_SETTINGS_STATUS;

WITH valid_settings AS (
    SELECT settings.docs_max_age_hours
    FROM REVIEW_SETTINGS AS settings
    CROSS JOIN ANSWER_REVIEW_SETTINGS_STATUS AS checks
    WHERE checks.settings_are_valid
)
SELECT areas.area_key, areas.documentation_query,
       latest.retrieval_id, latest.captured_at, latest.documentation_status,
       latest.accepted_count, latest.rejected_count, latest.content_hash,
       CASE
           WHEN settings.docs_max_age_hours IS NULL THEN 'invalid_settings'
           WHEN latest.retrieval_id IS NULL THEN 'missing_exact_search'
           WHEN latest.documentation_status <> 'ready' THEN latest.documentation_status
           WHEN latest.captured_at > SYSDATE() THEN 'future_capture'
           WHEN latest.captured_at < DATEADD('hour', -settings.docs_max_age_hours, SYSDATE())
               THEN 'stale'
           ELSE 'ready_for_suggestion_input'
       END AS input_status
FROM CHANGE_AREAS AS areas
LEFT JOIN valid_settings AS settings ON TRUE
LEFT JOIN DOCUMENTATION_LATEST AS latest
  ON latest.area_key = areas.area_key
 AND latest.query_text = areas.documentation_query
 AND latest.service_name = 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE'
ORDER BY areas.area_key;

-- Inspect exact accepted text. Raw rejected entries remain in response:results
-- in DOCUMENTATION_RETRIEVALS; DOCUMENTATION_STATUS supplies the retrieval_id.

SELECT passage.*
FROM DOCUMENTATION_PASSAGES AS passage
JOIN DOCUMENTATION_LATEST AS latest ON latest.retrieval_id = passage.retrieval_id
WHERE latest.service_name = 'DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE'
ORDER BY passage.area_key, passage.query_text, passage.passage_index;

-- Next: build suggestions from saved findings and these saved passages only.
-- Freshness measures retrieval time in UTC, not publication or service-index age.
-- Nothing here applies an agent change or sends a notification.