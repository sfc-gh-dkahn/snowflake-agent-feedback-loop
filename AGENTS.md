# Repository Guide for Coding Agents

This project reviews one existing Cortex Agent. It drafts suggestions but never changes the agent.

## Read First

Read `README.md`, both files under `docs/`, all numbered SQL files, and `optional/email.sql` before changing behavior.

Use `apply_patch` for edits. Keep changes small. Run the offline tests after code or SQL changes.

## Public Repository Rules

- Use synthetic names and data in tracked files.
- Do not add customer names, account names, local paths, credentials, thread IDs, traces, or query results.
- Keep configured SQL and results under ignored `local/`, `results/`, or `logs/`.
- Do not commit, push, upload, run SQL, call AI, send email, or enable a schedule unless the user asks.

## Behavior to Preserve

- Use one existing agent per empty output schema.
- Do not create, clone, alter, or drop an agent.
- Install all seven numbered SQL files in order. Tasks start suspended.
- Pair only adjacent complete turns in the same nonempty thread.
- Treat follow-up text as a feedback proxy, not a rating.
- Treat the captured agent specification as current at capture time, not historical proof.
- Keep observations apart from suspected causes.
- Treat a reported data gap as a claim to check, not proof that data or access is missing.
- Keep valid, invalid, and failed AI results immutable. A deliberate retry needs a new `prompt_revision`.
- Retrieve `SOURCE_URL`, `DOCUMENT_TITLE`, and `CHUNK` from the configured Snowflake Documentation service.
- Show findings when docs are missing, but do not produce an actionable technical change without usable official docs.
- Validate response shape, exact evidence quotes, citation URLs and quotes, and same-surface replacement text.
- Require human review before any agent change.
- Serialize manual runs, task runs, and email calls.

`max_diagnoses` limits unseen pairs. Cached diagnoses stay mapped without using that limit. Recommendation calls have a separate cap. Explain delayed work through `PARTIAL` and the counts in `AF_RUNS.diagnostics`.

Dashboard sources are `AF_FINDINGS`, `AF_REVIEW_QUEUE`, and `AF_RUNS`. These views are not sanitized. Email remains optional and separate from the task graph.

## Validation

Run:

```bash
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

Run rendered SQL tests only in an approved disposable installation. Use the generated `tests/fixture_pair.cli.sql` with Snow CLI so fixtures and assertions share one session.