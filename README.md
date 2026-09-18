# Snowflake Agent Feedback Loop

Find answers worth a closer look, then trace each suggested improvement back to
the conversation and official documentation that support it.

These eight SQL files review one existing Cortex Agent. You can follow each read,
inspect each saved table, and decide whether to pay for the next step. The output
is a set of findings and proposed changes for a person to review, not agent edits.

**Source-only, statically reviewed SQL.** The SQL tests are authored, not compiled
or run in Snowflake. This is not production-certified or an official Snowflake
project. This personal project has no license.

## Follow the Data

```text
00: REVIEW_SETTINGS + CHANGE_AREAS -> scope, limits and review categories
01: settings + source agent/events -> readiness and evidence counts

02: DESCRIBE AGENT -> AGENT_SETTINGS_HISTORY -> CURRENT_AGENT_SETTINGS (04)
02: GET_AI_OBSERVABILITY_EVENTS -> AGENT_EVENTS
03: AGENT_EVENTS -> CONVERSATION_TURNS -> ANSWER_FOLLOWUP_PAIRS
04: pairs + current settings + REVIEW_SETTINGS -> REVIEW_CANDIDATES
    -> ANSWER_REVIEW_INPUTS -> paid AI -> ANSWER_REVIEWS -> REVIEW_FINDINGS

05: documentation search service -> eight paid searches
    -> DOCUMENTATION_RETRIEVALS -> DOCUMENTATION_PASSAGES / DOCUMENTATION_LATEST
06: findings + current pairs/settings + CHANGE_AREAS + saved documentation
    -> RECOMMENDATION_OBSERVATIONS -> RECOMMENDATION_GROUPS
    -> RECOMMENDATION_CANDIDATES -> RECOMMENDATION_INPUTS
    -> paid AI -> RECOMMENDATIONS -> RECOMMENDATION_RESULTS -> REVIEW_QUEUE
07: saved evidence + views + results -> coverage, backlog and error counts
```

## Before You Start

- [ ] Choose one existing agent and an existing, empty output schema in a database you may use. Do not point these scripts at a populated older installation.
- [ ] Select an approved role and existing warehouse. The role needs warehouse/database/schema usage, permission to create tables and views in the output schema, and access to read/write those objects and replace its views.
- [ ] Confirm the role can describe the agent and read its observability events. See [agent monitoring](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-monitor).
- [ ] Confirm account, region, role and model access for [AI_COMPLETE](https://docs.snowflake.com/en/sql-reference/functions/ai_complete), including structured output. The sample model name is not an availability promise.
- [ ] For recommendations, have an accessible official-documentation search service exposing `SOURCE_URL`, `DOCUMENT_TITLE`, `CHUNK`. See [SEARCH_PREVIEW](https://docs.snowflake.com/en/sql-reference/functions/search_preview-snowflake-cortex) and the [Snowflake Documentation listing](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4). The scripts do not provision it.

Saved prompts, answers, SQL, settings and errors can contain sensitive text. Restrict
the output schema and decide how long to keep it. Views do not sanitize it, and
the scripts do not delete old evidence.

## Customize Four Literals

Edit the SQL directly before running. Use ignored `local/` for account-specific
copies; do not commit real names, conversation IDs or results.

| Choice | Where to change it |
| --- | --- |
| Output location | Replace `OUTPUT_DB` and `AGENT_FEEDBACK` consistently in the core files and optional email file. |
| Agent FQN | Replace `AGENT_DB.AGENT_SCHEMA.AGENT_NAME` in 01/02, plus every separate `'AGENT_DB'`, `'AGENT_SCHEMA'`, `'AGENT_NAME'` literal there, including saved event labels. |
| Review model | Replace every `claude-sonnet-4-6` literal in 04 and 06 together: model calls, identity fields and matching guards. Do not change only the call. |
| Documentation service | Replace every `DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE` literal across 05 and 06, including searches, saved labels, joins and inspections. |

Dates, thread filter, call limits, occurrence threshold, docs age and prompt revision
live **only in the single `REVIEW_SETTINGS` row**. For a fresh setup, edit its seed
in 00. After setup, `UPDATE` the row keyed `settings_id = 1`; never add a second row.
Rerunning setup preserves edits. Do not repeat dates or operating limits elsewhere.
The fixed search limit and prompt sample sizes are separate source policies.

Start with a short UTC window and one known thread. **Capture still saves all
threads for that agent in the window; the thread filter narrows reviews only.**
The seed defaults are 20 new reviews, 5 new recommendations, 2 occurrences,
168-hour docs age and revision `2`; lower the call caps for the first review.

## Run in Order

Select each statement, run it, and read its result before continuing. Stop on any
error. Keep all of 04 in one SQL session, and likewise all of 06: both use temporary
batches. Submit the complete `DESCRIBE AGENT ->> INSERT ... ;` chain in 02 as one
statement. Use AUTOCOMMIT with no open transaction; earlier writes survive failures.
Do not run concurrent copies or change settings, capture or docs during a batch.

| File | Reads | Writes / result |
| --- | --- | --- |
| [00_setup.sql](sql/00_setup.sql) | Editable seed literals | Two reference tables: `REVIEW_SETTINGS`, `CHANGE_AREAS` |
| [01_preflight.sql](sql/01_preflight.sql) | Settings, source agent and events | No writes; readiness and complete-turn counts |
| [02_capture_context.sql](sql/02_capture_context.sql) | Settings, source agent and events | `AGENT_SETTINGS_HISTORY`, new `AGENT_EVENTS` rows |
| [03_prepare_feedback.sql](sql/03_prepare_feedback.sql) | All saved events | Creates/replaces `CONVERSATION_TURNS`, `ANSWER_FOLLOWUP_PAIRS` views |
| [04_diagnose.sql](sql/04_diagnose.sql) | Pairs, captured settings, review settings, saved results | Views, temporary batches, immutable `ANSWER_REVIEW_INPUTS` and `ANSWER_REVIEWS` |
| [05_retrieve_documentation.sql](sql/05_retrieve_documentation.sql) | Literal service/queries; settings and areas for inspection | `DOCUMENTATION_RETRIEVALS` and three read views |
| [06_recommendations.sql](sql/06_recommendations.sql) | Saved reviews/docs, current pairs/settings, change areas | Views, temporary batches, immutable `RECOMMENDATION_INPUTS` and `RECOMMENDATIONS` |
| [07_inspect_results.sql](sql/07_inspect_results.sql) | Saved tables and views | No writes; coverage, current queue, history and errors |

Pause at the exact-input preview before each paid insert in 04 and 06. A full 05
run pays for all eight searches, even with fresh saved docs or no eligible findings.
Its searches are not capped by `REVIEW_SETTINGS` and have no automatic cache.
Ordinary queries, including repeated view reads, still incur warehouse compute;
read views themselves never call AI or search. Row caps do not cap tokens or credits.

For later reviews: update settings, preflight, capture, use the saved-history views
(recreate 03 only if definitions changed), run 04, manually refresh docs as needed,
then run 06 and inspect with 07. A changed prompt revision requires 04 before 06.

## Read the Results

`REVIEW_FINDINGS` separates `valid`, `invalid_output` and `ai_error`.
`REVIEW_QUEUE` shows current suggestions and what blocks them. Use 07 to distinguish
unjudged turns, work over the cap, missing docs, saved errors and historical results.
There is no run ledger or automatic completion status; empty does not mean healthy.

Only adjacent complete turns in the same usable thread form a pair. A final answer
or an answer followed by an incomplete turn stays unjudged. Follow-ups are clues,
not ratings. Captured settings describe capture time, not the version that answered.
Reported data gaps call for investigation, never a claim that data or access is absent.

Saved errors and invalid outputs are retained, not retried automatically. Changed
material inputs or an intentional new `prompt_revision` can create new paid work.
Unchanged content can reuse results, but statement failures, cancellation and
concurrent writers can repeat charges. There is **no exactly-once guarantee**.

No script changes an agent. [Optional email](optional/email.sql) only previews as
shipped; sending requires a separate, reviewed literal call. Nothing sends automatically.

Read the [step-by-step walkthrough](docs/walkthrough.md), the
[isolated SQL test instructions](tests/README.md), or the
[design-only dbt adaptation](docs/dbt-adaptation.md). This SQL path does not promise
the operational behavior of the former procedure/task implementation.