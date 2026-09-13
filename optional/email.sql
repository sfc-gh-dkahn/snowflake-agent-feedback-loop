USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;

CREATE TABLE IF NOT EXISTS AF_DELIVERY (
    delivery_id VARCHAR NOT NULL,
    run_id VARCHAR NOT NULL,
    payload_hash VARCHAR NOT NULL,
    integration_name VARCHAR NOT NULL,
    recipient VARCHAR NOT NULL,
    status VARCHAR NOT NULL,
    claimed_at TIMESTAMP_LTZ NOT NULL,
    completed_at TIMESTAMP_LTZ,
    error_message VARCHAR
);

CREATE OR REPLACE PROCEDURE AF_SEND_EMAIL(
    P_RUN_ID VARCHAR, P_INTEGRATION VARCHAR, P_RECIPIENT VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_COUNT INTEGER;
    V_BODY VARCHAR;
    V_PAYLOAD_HASH VARCHAR;
    V_DELIVERY_ID VARCHAR;
    V_RECIPIENT VARCHAR;
    V_ACCEPTED BOOLEAN;
    V_CLAIMED BOOLEAN DEFAULT FALSE;
    V_IN_TRANSACTION BOOLEAN DEFAULT FALSE;
    E_REQUEST EXCEPTION (-20020, 'Email requires one completed COMPLETE/PARTIAL run, an integration name, one recipient, and no caller transaction. Serialize delivery calls.');
    E_SEND EXCEPTION (-20021, 'Email was not acknowledged. Delivery is uncertain; automatic resend is blocked.');
BEGIN
    IF (CURRENT_TRANSACTION() IS NOT NULL OR NOT COALESCE(
        REGEXP_LIKE(P_INTEGRATION, '[A-Z_][A-Z0-9_$]{0,254}')
        AND NOT CONTAINS(P_INTEGRATION, '__')
        AND LENGTH(P_RECIPIENT) <= 254
        AND REGEXP_LIKE(P_RECIPIENT, '[^[:space:][:cntrl:],;<>@]+@[^[:space:][:cntrl:],;<>@]+[.][^[:space:][:cntrl:],;<>@]+'), FALSE)) THEN
        RAISE E_REQUEST;
    END IF;
    SELECT COUNT(*) INTO :V_COUNT
    FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUNS
    WHERE run_id = :P_RUN_ID AND status IN ('COMPLETE', 'PARTIAL') AND completed_at IS NOT NULL;
    IF (V_COUNT <> 1) THEN
        RAISE E_REQUEST;
    END IF;
    V_RECIPIENT := LOWER(P_RECIPIENT);
    SELECT COUNT(*), LISTAGG(summary_line, '\n\n') WITHIN GROUP (ORDER BY summary_line)
    INTO :V_COUNT, :V_BODY
    FROM (
        SELECT DISTINCT agent_database || '.' || agent_schema || '.' || agent_name
            || '\nSurface: ' || surface
            || '\nReview: ' || review_status || '; docs: ' || docs_status
            || '\nSummary: ' || LEFT(REGEXP_REPLACE(
                COALESCE(NULLIF(TRIM(summary), ''), 'Recommendation needs human investigation.'),
                '[[:cntrl:]]', ' '), 1000) AS summary_line
        FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_REVIEW_QUEUE
        WHERE run_id = :P_RUN_ID AND review_status IN ('ready_for_review', 'needs_review')
    );
    IF (V_COUNT = 0) THEN
        RETURN 'NO_REVIEW_SUMMARIES';
    END IF;
    IF (V_COUNT > 20 OR LENGTH(V_BODY) > 40000) THEN
        RAISE E_REQUEST;
    END IF;
    V_BODY := 'Agent feedback review summaries. Human review required; no changes applied.'
        || '\nThis is not a full run-health report. Check AF_RUNS and AF_REVIEW_QUEUE in Snowflake.'
        || '\n\n' || V_BODY;
    V_PAYLOAD_HASH := SHA2(V_BODY, 256);
    V_DELIVERY_ID := SHA2(TO_JSON(ARRAY_CONSTRUCT(
        'AF_EMAIL_V1', V_PAYLOAD_HASH, P_INTEGRATION, V_RECIPIENT)), 256);
    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    INSERT INTO __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DELIVERY (
        delivery_id, run_id, payload_hash, integration_name, recipient, status, claimed_at)
    SELECT :V_DELIVERY_ID, :P_RUN_ID, :V_PAYLOAD_HASH, :P_INTEGRATION, :V_RECIPIENT,
        'CLAIMED', CURRENT_TIMESTAMP()
    WHERE NOT EXISTS (
        SELECT 1 FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DELIVERY
        WHERE delivery_id = :V_DELIVERY_ID);
    V_CLAIMED := SQLROWCOUNT = 1;
    COMMIT;
    V_IN_TRANSACTION := FALSE;
    IF (NOT V_CLAIMED) THEN
        RETURN 'SUPPRESSED_EXISTING_DELIVERY';
    END IF;
    CALL SYSTEM$SEND_EMAIL(:P_INTEGRATION, :V_RECIPIENT,
        'Agent feedback review summaries', :V_BODY, 'text/plain') INTO :V_ACCEPTED;
    IF (NOT COALESCE(V_ACCEPTED, FALSE)) THEN
        RAISE E_SEND;
    END IF;
    BEGIN TRANSACTION;
    V_IN_TRANSACTION := TRUE;
    UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DELIVERY
    SET status = 'SENT', completed_at = CURRENT_TIMESTAMP()
    WHERE delivery_id = :V_DELIVERY_ID AND run_id = :P_RUN_ID AND status = 'CLAIMED';
    COMMIT;
    V_IN_TRANSACTION := FALSE;
    RETURN 'SENT';
EXCEPTION
    WHEN OTHER THEN
        IF (V_IN_TRANSACTION) THEN
            ROLLBACK;
        END IF;
        IF (V_CLAIMED) THEN
            BEGIN
                BEGIN TRANSACTION;
                UPDATE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DELIVERY
                SET status = 'UNCERTAIN', completed_at = CURRENT_TIMESTAMP(),
                    error_message = 'Delivery may have occurred; reconcile manually before any resend.'
                WHERE delivery_id = :V_DELIVERY_ID AND run_id = :P_RUN_ID AND status = 'CLAIMED';
                COMMIT;
            EXCEPTION
                WHEN OTHER THEN
                    ROLLBACK;
            END;
            RETURN 'UNCERTAIN_DO_NOT_RESEND';
        END IF;
        RAISE;
END;
$$;