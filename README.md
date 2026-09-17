# Snowflake Agent Feedback Loop

**Experimental. Clean-install validation is pending.** The SQL and examples have not been established as a working clean installation. Do not treat this project as a production monitor.

A public personal project by **Dylan Kahn**, provided **as-is**. This is not an official Snowflake project and is not supported or endorsed by Snowflake. No license has been chosen; public availability does not grant a license to reuse the code.

Review conversations from one **existing Cortex Agent**, preserve evidence, and draft documentation-backed suggestions for a human. The project never creates, clones, or changes the agent. It installs tables, views, procedures, and a suspended task graph in an approved, existing, empty output schema.

## What It Does

```text
AF_START -> AF_CAPTURE -> AF_PREPARE -> AF_DIAGNOSE -> AF_RECOMMEND -> AF_FINISH
AF_FINALIZE records unfinished graph runs as failed.
```

Capture archives selected observability fields and the agent's configuration at capture time. Preparation pairs an answer with the next user message in the same thread, retaining up to six prior complete turns. AI produces review hypotheses, not factual grades. Recommendations compare poor observations with successful behavior and retrieve official documentation before proposing a change. Nothing applies those proposals.

**Biggest limit: this is bounded processing, not full monitoring.** Preparation computes identities for all candidate pairs in the window, maps all persisted diagnoses, then selects up to `max_diagnoses` newest unseen pairs (default 20). Cached evidence is reused where available; full context is assembled only for selected pairs without saved evidence. Repeated serialized runs can advance through unchanged unseen inputs, but new arrivals can still delay older work. Inspect `candidate_pairs`, `cached_pairs`, `new_pairs`, `prepared_pairs`, and `pairs_over_limit`; delayed pairs make the run `PARTIAL`. Window-wide hashing and cached mappings are not bounded by the inference cap. Recommendation evidence remains sampled at ten poor and ten good examples, with sampling flagged as `PARTIAL`. Coverage and runtime behavior still need validation.

## Before Installation

1. Choose one existing agent and an approved, existing database with an empty output schema. Do not create or clone a database, schema, or agent as part of these instructions. Keep one agent per output schema; do not repoint a populated installation to another agent.
2. Use simple uppercase, unquoted object identifiers in v1. Agent identifier components follow `[A-Z_][A-Z0-9_$]{0,254}` and must not contain `__`. A documentation service uses three such components. Model names follow their own model-name syntax, not uppercase object naming.
3. Confirm the actual account, role, warehouse, output database/schema, existing agent, and permitted judge model. The role needs approved access to the output objects, warehouse, agent specification, readable agent observability, and AI inference. Tasks run as their owner role, which also needs the required task execution privileges. A working interactive call does not prove that task-owner access works.
4. Review data handling and cost before inference. Raw traces can contain prompts, responses, SQL, chart specifications, and sensitive content. The captured configuration and AI outputs can contain sensitive content too. Restrict access and set a retention policy appropriate to your environment; this project installs no automatic retention cleanup.

Replace every `__OUTPUT_DATABASE__`, `__OUTPUT_SCHEMA__`, `__AGENT_DATABASE__`, `__AGENT_SCHEMA__`, `__AGENT_NAME__`, `__JUDGE_MODEL__`, and `__WAREHOUSE__` placeholder in the SQL before installation. Use an actual approved role explicitly in the session; `__ROLE__` below is a documentation placeholder, not an extra configuration field. Keep configured copies and results private, not in a public commit.

```sql
USE ROLE __ROLE__;
USE WAREHOUSE __WAREHOUSE__;
USE DATABASE __OUTPUT_DATABASE__;
USE SCHEMA __OUTPUT_SCHEMA__;
SHOW CORTEX BASE MODELS;
```

Inspect the model listing and confirm that the chosen model supports the required structured response and is permitted by the account's model controls, region settings, and role grants. `AF_PREFLIGHT` does not check model availability or call AI. These are instructions for later approved checks, not claims of live testing.

### Rendering the Substitutions

Editing seven files by hand invites a missed placeholder. `tools/render_install.py` does the substitution for you and refuses bad input. It reads repository text and writes rendered copies; it runs no SQL, calls no AI, sends no email, creates no task or schedule, starts no subprocess, and needs no packages beyond the standard library. Hand editing remains a supported, auditable fallback.

```bash
python3 -B tools/render_install.py render \
  --output-database __OUTPUT_DATABASE__ --output-schema __OUTPUT_SCHEMA__ \
  --agent __AGENT_DATABASE__.__AGENT_SCHEMA__.__AGENT_NAME__ \
  --warehouse __WAREHOUSE__ --role __ROLE__ \
  --judge-model your-judge-model \
  --docs-service DOCS_DATABASE.DOCS_SCHEMA.DOCS_SERVICE
```

It validates identifiers against the same rules `AF_PREFLIGHT` enforces, checks model-name syntax, writes the seven install files followed by the two test files in required order, and fails if any placeholder survives. Substitute your own approved values above; the harness rejects the bracketed placeholder text itself, because a value containing `__` would read as an unresolved placeholder. Output goes to `local/render` by default; the harness refuses any directory `.gitignore` does not already exclude, so a configured copy cannot reach a public commit. It prints the exact rendered paths and the next commands, including the separate `AF_CONFIG.docs_service` update, and reports what it has not done.

Creating the output schema is a separate action that needs `--approve-ddl`, and it writes the one `CREATE SCHEMA` statement for you to review and run yourself:

```bash
python3 -B tools/render_install.py create-schema --approve-ddl [same arguments]
```

Passing validation is not proof of anything live. It does not prove the SQL compiles, that your role holds the required grants, that the model is permitted or returns structured output, or that the documentation service is reachable. `optional/email.sql` is never rendered; email stays a separate approval and a manual install.

## Install, Then Preflight

Run **all seven** numbered SQL files in order, `00` through `06`, only after reviewing the substitutions and approving DDL. Installation defines objects and inserts configuration/reference rows; it does **not** invoke the runtime procedures, execute tasks, call AI, send email, or enable a schedule. It is not a rerunnable migration: several objects use plain `CREATE`.

All tasks start suspended. The root `AF_START` has `CONFIG = '{}'`, no schedule, `NO_OVERLAP`, and zero automatic retries. Do not resume the root during setup.

```sql
CALL __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_PREFLIGHT();
```

Preflight reads the current agent specification and bounded telemetry, returning counts and `inference_performed = false`, not raw content. Require `ok = true` and inspect the counts before a runtime proof. Missing readable evidence does not establish its cause, and success does not prove that adjacent feedback pairs, documentation retrieval, or inference will work. Warehouse work can still cost credits without AI.

Defaults in `AF_CONFIG`: 14-day lookback, 20 new diagnoses, 5 new recommendation AI calls, 2 distinct poor responses per surface unless one is severe, 168-hour documentation cache, and prompt revision `'1'`. Supported limits are 1-90 days, 1-100 new diagnoses, 1-20 new recommendation AI calls, 1-1000 occurrences, and 1-720 cache hours. Recommendations check all eligible groups across the eight supported surfaces for docs and cached results before applying the AI-call cap. Keep exactly one configuration row with `config_id = 1`.

## Documentation Grounding

Use the published [Snowflake Documentation CKE listing](https://app.snowflake.com/marketplace/listing/GZSTZ67BY9OQ4). The listing is free and refreshed weekly; runtime search, inference, warehouse work, and storage can still incur credits or charges. Listing access is not a runtime budget.

After approved listing setup, discover the actual accessible Cortex Search service and set `AF_CONFIG.docs_service` to its uppercase, three-part name. Do not guess a service name from the listing title. The live search contract requests **`SOURCE_URL`, `DOCUMENT_TITLE`, and `CHUNK`**. Only usable passages with URLs beginning `https://docs.snowflake.com/` can ground proposals. The service defaults to `NULL`.

The cache TTL measures time since retrieval, not a document's publication date or proof that it is current. With missing, inaccessible, or unusable docs, diagnoses still produce findings, but the recommendation stage cannot produce an actionable documentation-backed fix. Eligible groups remain visible as `needs_review` with a docs status; inspect `AF_RUNS` as well.

Groups delayed by the recommendation AI cap are mapped as `needs_review`, with `docs_status = 'inference_limit'` and error `Inference limit reached`. Their identity uses the retrieved documentation hash, not the cap status, so an unchanged later run can fill the no-inference placeholder. Documentation failures also remain retryable; changed docs can create a new identity. Persisted AI results, including `ai_error` and `invalid_output`, are immutable and reused, not overwritten or silently retried.

## Run and Review

Follow the [walkthrough](docs/walkthrough.md) for a bounded, one-existing-thread proof using root-task `CONFIG`, optional manual calls, and synthetic stage examples. Approve token use before either execution path. The row limits are not hard token or credit caps; evidence and configuration sizes vary.

Use `AF_FINDINGS`, `AF_REVIEW_QUEUE`, and `AF_RUNS` as sources for your own dashboard. No app ships here. Views omit some raw fields but **do not guarantee sanitized output**; AI text can repeat source content. Keep them restricted until a human reviews their contents and audience. `COMPLETE` means processing completed within these contracts, not that the agent is good or all interactions were assessed.

No thread means no pairing. The first answer can be judged from the next message, but an answer without a subsequent complete turn remains unknown. Current captured configuration is not historical invocation configuration. Reported data gaps are not verified missing data. Exact evidence and citation matches do not prove the model's reasoning.

Retries are manual and must be serialized across task and procedure runs. The active-run check is not an atomic lock; table keys are not enforced uniqueness constraints, and neither AI calls nor email have exactly-once guarantees. The [walkthrough](docs/walkthrough.md) explains recovery and the separately approved optional email path. Add a weekly `AF_START` schedule only after a successful proof and coverage review.

To deliberately retry persisted inference with otherwise unchanged inputs, change `prompt_revision` between approved runs. This creates new identities and can incur new AI charges; it leaves historical inference records intact. Configuration changes, including limits and cache settings, intentionally affect the capture hash and can rejudge the same conversations. Prompt changes also require a diagnosis revision bump; no migration or automatic retry is implied by installing changed SQL.

## File Purpose

| File | Why it exists | Status |
| --- | --- | --- |
| `README.md` | Scope, limits, setup gates, and entry point | Documentation |
| `AGENTS.md` | Safe repository onboarding for coding assistants | Documentation |
| `docs/walkthrough.md` | Bounded execution, stage contracts, and review | Documentation |
| `docs/dbt-adaptation.md` | Design for persisted AI results in a dbt workflow | Design only |
| `sql/00_setup.sql` | Core storage, configuration, supported surfaces, output validators | Required install 1 |
| `sql/01_preflight.sql` | Configuration checks, readable-text helper, no-AI preflight | Required install 2 |
| `sql/02_capture_context.sql` | Archive events and capture current agent specification | Required install 3 |
| `sql/03_prepare_feedback.sql` | Reconstruct turns, pair follow-ups, bound evidence | Required install 4 |
| `sql/04_diagnose.sql` | Persist AI diagnoses and expose findings | Required install 5 |
| `sql/05_recommend.sql` | Retrieve docs, validate proposals, map results to runs | Required install 6 |
| `sql/06_tasks.sql` | Run guards, manual runner, review queue, task graph and finish accounting | Required install 7 |
| `optional/email.sql` | Separately installed summary delivery and delivery ledger | Optional; no integration creation |
| `tools/render_install.py` | Render placeholders privately; write schema DDL for review; runs no SQL | Offline helper |
| `tests/test_contracts.py` | Static contract checks without Snowflake or AI | 27 offline tests passed |
| `tests/test_harness.py` | Validation, rendering, private-output and no-execution checks for the harness | 24 offline tests passed |
| `tests/fixtures.sql` | Isolated synthetic inputs, never runtime agent seeds | Included; Snowflake execution pending |
| `tests/assertions.sql` | Fixture/output assertions in an approved disposable test schema | Included; Snowflake execution pending |
| `.gitignore` | Exclude common local configuration, environments, logs, and results | Not a secret scanner |

Static checks cannot prove Snowflake compilation, privileges, event shape, structured AI responses, search retrieval, or task execution. Clean-install and runtime validation remain pending. The [dbt adaptation guide](docs/dbt-adaptation.md) is a design, not a supplied dbt project.

Run the offline checks from the repository root:

```bash
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

## CoCo Starter

```text
Read AGENTS.md, README.md, both docs, and every SQL file before proposing work.
Treat this as an experimental personal project, not a supported Snowflake product.
Check the current contracts and report gaps without claiming live validation.
Confirm my actual account, approved role and warehouse, existing agent, empty
output schema, allowed model, and accessible documentation service. Never create
or clone an agent or database. Keep one existing agent per output schema.
Show substitutions and request approval before DDL. Run no AI until I approve
the evidence scope and token cost. Start with one existing thread and a bounded
window. Keep AF_START suspended. Ask separately before email or scheduling.
Do not publish customer configuration, traces, query results, or credentials.
Do not commit, push, upload, or broaden permissions without explicit approval.
```