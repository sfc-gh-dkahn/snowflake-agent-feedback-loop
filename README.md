# Snowflake Agent Feedback Loop

This project reviews conversations from one existing Cortex Agent. It stores evidence and drafts suggestions for human review. It does not change the agent.

The install creates tables, views, procedures, and a suspended task graph in an existing empty schema. It does not create an agent, database, role, warehouse, or schedule.

This is a personal project, not an official Snowflake project. It has no license.

## Cortex Code Path

Use Cortex Code to keep the first run small and reviewable:

1. Clone the repository and open it in Cortex Code.
2. Discover the agent, role, warehouse, model, empty output schema, and Snowflake Documentation service you will use.
3. Render configured SQL with `tools/render_install.py`.
4. Review `local/render/PLAN.txt` and the rendered files.
5. Install the ordered SQL files with the commands in the plan.
6. Run `AF_PREFLIGHT` and require `ok = true`.
7. Run one short window for one conversation thread.
8. Review `AF_RUNS`, `AF_FINDINGS`, and `AF_REVIEW_QUEUE` before widening the scope.

## How It Works

```text
AF_START -> AF_CAPTURE -> AF_PREPARE -> AF_DIAGNOSE -> AF_RECOMMEND -> AF_FINISH
AF_FINALIZE marks unfinished graph runs as failed.
```

The pipeline:

1. Captures a bounded set of agent observability events and the current agent specification.
2. Pairs each complete answer with the next complete user turn in the same thread.
3. Uses AI to classify the follow-up as good, poor, or unclear evidence.
4. Groups poor findings and retrieves official Snowflake documentation.
5. Drafts a change or investigation for a person to review.

A follow-up is a clue about the prior answer, not a rating. The current agent specification may differ from the version that produced an older answer. Findings and suggestions can be wrong.

## Requirements

Choose:

- One existing Cortex Agent.
- An approved role and warehouse.
- An existing database with an empty output schema.
- A permitted model that supports structured output.
- An accessible Cortex Search service from the [Snowflake Documentation CKE](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4).

The role must be able to read the agent specification and observability events, use the warehouse, run AI inference, search the documentation service, and own the installed objects and tasks. Tasks run as their owner role.

Raw events may contain prompts, responses, SQL, chart specifications, and sensitive data. Restrict the output schema and set a retention policy. This project does not delete old data.

Version 1 accepts simple uppercase, unquoted object names. Agent and documentation service names must use three parts. Keep configured files and query results under ignored `local/`, `results/`, or `logs/`.

## Render Private SQL

Run the renderer from the repository root:

```bash
python3 -B tools/render_install.py render \
  --output-database OUTPUT_DB \
  --output-schema AGENT_FEEDBACK \
  --agent AGENT_DB.AGENT_SCHEMA.AGENT_NAME \
  --warehouse AGENT_WH \
  --role AGENT_REVIEWER \
  --judge-model your-model \
  --docs-service DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE
```

Add `--connection NAME` if you do not want the Snow CLI default connection. Output goes to `local/render` unless you set `--out` to another ignored path.

The renderer validates names, replaces every placeholder, and writes `PLAN.txt` with exact `snow sql` commands. It also writes:

- `local/render/sql/06_tasks.cli.sql`: task DDL wrapped for the Snow CLI statement splitter.
- `local/render/tests/fixture_pair.cli.sql`: fixtures and assertions in one CLI session.

Use these generated files with `snow sql`. Use the plain rendered `sql/06_tasks.sql` in Snowsight.

The renderer runs no SQL.

## Install

Create the empty schema yourself, or render the DDL for review:

```bash
python3 -B tools/render_install.py create-schema --approve-ddl \
  --output-database OUTPUT_DB \
  --output-schema AGENT_FEEDBACK \
  --agent AGENT_DB.AGENT_SCHEMA.AGENT_NAME \
  --warehouse AGENT_WH \
  --role AGENT_REVIEWER \
  --judge-model your-model \
  --docs-service DOCS_DB.DOCS_SCHEMA.DOCS_SERVICE
```

Then follow `local/render/PLAN.txt`. The CLI path runs the first six install files and then `06_tasks.cli.sql`. All seven tasks start suspended. The root has no schedule and no automatic retries.

Run preflight before inference:

```sql
CALL OUTPUT_DB.AGENT_FEEDBACK.AF_PREFLIGHT();
```

Require `ok = true`. Preflight checks configuration, the agent specification, and readable recent events. It does not call AI or test every task-owner grant.

`sql/00_setup.sql` seeds `REVIEW_SETTINGS` with an explicit UTC review window, no thread filter, 20 new reviews, 5 new recommendation calls, 2 poor answers per change area, a 168-hour documentation age limit, and prompt revision `2`. Edit the window before the first run. It also seeds `CHANGE_AREAS` with the eight parts of an agent a suggestion may address. Reruns leave both tables alone rather than resetting your edits.

## Run and Review

Start with one thread and a short time window. Review the evidence scope and likely AI cost first. Row limits do not cap tokens or total credits.

The [walkthrough](docs/walkthrough.md) shows task and manual runs. Keep task runs and manual runs serialized.

Review these views and tables:

| Object | Use |
| --- | --- |
| `AF_FINDINGS` | Diagnoses and validation state |
| `AF_REVIEW_QUEUE` | Suggested changes, citations, and errors |
| `AF_RUNS` | Stage, status, coverage counts, and failures |

`COMPLETE` means the selected work finished. It does not mean every conversation was reviewed or the agent is accurate. `PARTIAL` means work was delayed, sampled, missing docs, or had invalid or failed AI output.

The project never applies suggestions. Views can repeat sensitive source text even when they omit raw columns. Review content before sharing it.

## Limits

- Only adjacent complete turns in a nonempty thread can form a feedback pair.
- An answer with no later complete turn remains unjudged.
- New work can outpace the configured limits and age out of the lookback window.
- Recommendation prompts sample evidence even when the full group count is larger.
- Documentation cache age measures retrieval time, not publication time.
- AI calls and email do not have exactly-once delivery guarantees.
- A changed `prompt_revision`, model, configuration, evidence set, or docs set can create new AI work and cost.

Install `optional/email.sql` only if you need email. It uses an existing notification integration and does not create a schedule.

## Tests

Run the offline tests:

```bash
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

These tests check source contracts and rendering. They do not compile SQL in Snowflake. The rendered `fixture_pair.cli.sql` tests deterministic SQL behavior in one approved disposable installation.

See [docs/dbt-adaptation.md](docs/dbt-adaptation.md) for a design-only dbt mapping.