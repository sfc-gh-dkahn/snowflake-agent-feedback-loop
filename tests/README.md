# Isolated SQL Tests

**NEVER run these tests in production or in `AGENT_FEEDBACK`.** Use a new, empty
`OUTPUT_DB.AGENT_FEEDBACK_TEST` schema in a disposable test database. Replace
`OUTPUT_DB` consistently with that database, not your production database. Use a
test-only role without production write access and select an existing warehouse.
Warehouse queries cost compute; this suite makes no model, search, observability,
agent-description, email or scheduling calls. All content is synthetic.

## Run Order

1. In one SQL session, select your test role, existing warehouse and test database.
   Manually run `CREATE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;` without `OR REPLACE`
   or `IF NOT EXISTS`. If it exists, stop and choose a fresh disposable database.
   Use AUTOCOMMIT, no open transaction and no concurrent writers. Keep this session
   through every step. Stop immediately on any SQL error. Separate CLI invocations
   do not share the temporary fixture tables.
2. Run `tests/fixtures.sql`. Expect **65 events and 3 snapshots**. It creates all
   nine underlying tables with the production column order, types and nullability
   from 00/02/04/05/06. No installed production objects or `LIKE` copies are needed.
   Ordinary tables support the real persistent views; helper tables are temporary.
   Creation deliberately fails on existing tables rather than replacing them.
3. Install **only the complete `CREATE OR REPLACE VIEW ... ;` statements** listed
   below from the current source files, in this exact order. Select each block from
   `CREATE` through its own terminating semicolon, not through a semicolon in a
   quoted string. Do not run entire source files, their `USE` statements, table or
   batch DDL, inserts, inspections, or paid sections. Before EACH block use
   `USE SCHEMA OUTPUT_DB.AGENT_FEEDBACK_TEST;` and verify `CURRENT_DATABASE()` and
   `CURRENT_SCHEMA()`. The view blocks use unqualified local names; leave the
   literal `DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE` unchanged because fixtures match it.
4. Run `tests/saved_results.sql` once. It freezes real candidate IDs, saves synthetic
   `{value,error}` envelopes, and measures caps before/after saving. All eligible
   mocks are then saved deliberately, not treated as a paid capped batch. Suffixed
   recommendation IDs isolate validator cases from the real current queue.
5. Run `tests/assertions.sql` once. Read `test_name`, `passed`, `expected`, `actual`,
   then the failure summary. Require zero failures and `PASS`; stop otherwise.
6. Run `tests/mutations.sql` once. It accumulates further checks and restores each
   changed fixture before the next scenario. Require zero failures and `PASS` again.
   Failed statements can leave partial mutations: restart in a fresh schema/session,
   not by continuing halfway or rerunning fixture DDL over existing tables.
7. To check timezone independence, repeat the whole suite with another fresh test
   database/session using `ALTER SESSION SET TIMEZONE = 'America/Los_Angeles';`.
   Compare counts and verdicts, not literal hashes across separately seeded clocks.
   Close the session and manually remove ONLY the disposable test schema after
   reviewing results. This suite does not drop schemas or promise rollback.

## View Blocks

| Source | Views, In Order |
| --- | --- |
| `sql/03_prepare_feedback.sql` | `CONVERSATION_TURNS`, `ANSWER_FOLLOWUP_PAIRS` |
| `sql/04_diagnose.sql` | `CURRENT_AGENT_SETTINGS`, `ANSWER_REVIEW_SETTINGS_STATUS`, `REVIEW_CANDIDATES`, `REVIEW_FINDINGS` |
| `sql/05_retrieve_documentation.sql` | `DOCUMENTATION_PASSAGES`, `DOCUMENTATION_STATUS`, `DOCUMENTATION_LATEST` |
| `sql/06_recommendations.sql` | `CHANGE_AREAS_STATUS`, `RECOMMENDATION_OBSERVATIONS`, `RECOMMENDATION_GROUPS`, `RECOMMENDATION_CANDIDATES`, `RECOMMENDATION_INPUT_STATUS`, `RECOMMENDATION_RESULTS`, `REVIEW_QUEUE` |

## Scope

The baseline uses `min_occurrences = 1` to exercise every docs gate with one
observation; mutations test the real threshold of two separately. Both caps are one,
with 28 review candidates and four suggestion candidates before saving. Dates anchor
once to UTC midnight two days ago; event LTZ values come from numeric UTC epochs.
Finish within 24 hours so synthetic fresh documentation remains comfortably fresh.

Official-looking URLs and passages are invented test data, not documentation claims.
The suite checks view logic, identities, saved-error reuse, strict types, exact quotes,
same-surface replacements, investigation-only gaps and settings/docs gates. Mutation
UPDATE/DELETE statements belong ONLY to fixtures, never the append-only production path.
No copied view implementation or renderer is maintained here. Legacy source-contract
and renderer tests do not apply to this refactor; their removal belongs to step 11.
This suite has been authored and statically checked, **not compiled or executed**.
It does not prove live API contracts, privileges, capture MERGE behavior, frozen paid
batch execution, model/schema/template version edits, concurrency or exactly-once cost.