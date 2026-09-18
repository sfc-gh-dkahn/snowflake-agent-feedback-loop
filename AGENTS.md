# Repository Guide for Coding Agents

Maintain an analyst-readable SQL path for one existing Cortex Agent. It saves
evidence and drafts suggestions; it never changes an agent. Source is statically
reviewed only. Tests are authored, not compiled or run in Snowflake.

## Scope and Editing

Read README, both docs, all numbered SQL, optional email, and tests/README before
changing behavior. Read relevant fixture/assertion files too. Use `apply_patch` for
manual edits. Keep each change in its owning file and directly related docs/tests.

- Keep the public implementation SQL and Markdown only. Do not add Python, a renderer, runtime package, custom procedures/UDFs, session variables, dynamic SQL or deployment tooling.
- Use literal output/agent/model/service names with a clear customization header. Dates and operating limits belong in the single `REVIEW_SETTINGS` row, not duplicated literals.
- Preserve existing user edits. Do not modify sibling projects, private scratch or external diagrams/reports unless explicitly asked.
- Use synthetic names and evidence in tracked files. Keep account-specific copies and results in ignored `local/`, `results/` or `logs/`; never commit secrets or real conversation data.
- Do not execute SQL/tests, call AI/search, send email, schedule work, upload data, commit or push without explicit authorization. Reviewing source is not permission to execute it.

## File Ownership

All production objects below belong in the chosen output schema. Each table has
one defining file; later files consume it rather than redefining it.

| Owner | Durable tables | Views / other responsibility |
| --- | --- | --- |
| `sql/00_setup.sql` | `REVIEW_SETTINGS`, `CHANGE_AREAS` | Guarded initial seeds; settings/reference inspection. |
| `sql/01_preflight.sql` | None | Source description/events and readiness counts; no writes. |
| `sql/02_capture_context.sql` | `AGENT_SETTINGS_HISTORY`, `AGENT_EVENTS` | Whole DESCRIBE pipe statement; snapshots append, events insert-only MERGE. |
| `sql/03_prepare_feedback.sql` | None | `CONVERSATION_TURNS`, `ANSWER_FOLLOWUP_PAIRS`. |
| `sql/04_diagnose.sql` | `ANSWER_REVIEW_INPUTS`, `ANSWER_REVIEWS` | `CURRENT_AGENT_SETTINGS`, `ANSWER_REVIEW_SETTINGS_STATUS`, `REVIEW_CANDIDATES`, `REVIEW_FINDINGS`; temporary `ANSWER_REVIEW_BATCH`, `ANSWER_REVIEW_INFERENCE_BATCH`; paid review insert. |
| `sql/05_retrieve_documentation.sql` | `DOCUMENTATION_RETRIEVALS` | `DOCUMENTATION_PASSAGES`, `DOCUMENTATION_STATUS`, `DOCUMENTATION_LATEST`; eight literal paid search inserts. |
| `sql/06_recommendations.sql` | `RECOMMENDATION_INPUTS`, `RECOMMENDATIONS` | `CHANGE_AREAS_STATUS`, `RECOMMENDATION_OBSERVATIONS`, `RECOMMENDATION_GROUPS`, `RECOMMENDATION_CANDIDATES`, `RECOMMENDATION_INPUT_STATUS`, `RECOMMENDATION_RESULTS`, `REVIEW_QUEUE`; temporary `RECOMMENDATION_BATCH`, `RECOMMENDATION_INFERENCE_BATCH`; paid suggestion insert. |
| `sql/07_inspect_results.sql` | None | Read-only coverage, backlog, failures, current/history and duplicate checks. |
| `optional/email.sql` | None | Read-only preview and commented literal manual send; no delivery ledger. |

Use `CREATE TABLE IF NOT EXISTS` to preserve production history, not as a schema
migration. Setup does not repair a partial seed. Never replace populated evidence
or result tables to make new code work. Fixture mutations are a separate contract.

## Hash and Evidence Lineage

Preserve the actual source expressions and ordered inputs; this list locates them,
not a second implementation of their validation rules:

- 02 `event_hash`: agent identity, numeric epoch nanoseconds and selected span fields. Never session-formatted timestamps or capture time.
- 03 `turn_hash`: agent/thread/trace, chosen root/question and ordered event hashes. `pair_hash` adds both adjacent turns and ordered prior context hashes.
- 04 `config_hash`: ordered path/type/scalar tuples with root/container markers, not unordered object JSON. `{}` is valid; nonobject roots remain visible but ineligible.
- 04 `review_id`: pair/config hashes, model, prompt/schema revisions, instruction-template hash and generation policy. `prompt_hash` audits exact saved bytes, not semantic identity.
- 05 `passage_id`: exact URL/title/chunk. `content_hash`: sorted accepted passage IDs with duplicates retained; exclude retrieval UUID/time and ranking.
- 06 `group_id`: agent plus surface. `recommendation_id`: group/config, full and selected evidence/good-member identities and counts, docs service/query/content, model/revisions and template/generation/sample policies. Exclude random IDs/times, budget and exact prompt serialization.

Trace a suggestion through `RECOMMENDATION_INPUTS.evidence_members`/`good_members`
to review IDs, `ANSWER_REVIEW_INPUTS`, pair hashes, traces and saved spans. Keep full
membership even when prompts sample three examples and two good counterexamples.
Unchanged captures or equivalent fresh docs must not invent new paid identities.
Changed material input must not silently reuse a stale result.

## Behavior Contract

- Number every root-backed turn before completeness filtering. Pair only adjacent complete turns in the same usable thread; never bridge an incomplete turn. Keep final/unpairable answers unjudged.
- Capture all threads within the settings window. Filter reviews by thread and follow-up UTC time. Context uses six positions ending at the response, complete turns only.
- Source timestamps are UTC NTZ; saved events are LTZ and need explicit UTC normalization. Settings dates are UTC by convention, start inclusive/end exclusive.
- Settings snapshots are current at capture, not historical proof. Follow-ups are proxies, observations are not causes, and reported data gaps require investigation.
- Count all settings rows before filtering. Reject invalid singleton/settings/reference data before selecting paid model inputs; retain a visible status even with zero work. 05 searches are explicit and not settings-gated.
- Count full eligible groups before call caps. Require the strict occurrence threshold; no severe or recurrence bypass. Deferred work is a live view, not persisted placeholders.
- Freeze capped IDs once, save exact prompts, freeze inference inputs from saved rows, and exclude all saved results. Persist raw envelopes, including errors/invalid output, without overwriting.
- Keep all statements in 04 in one session, likewise 06. Stop on error; no concurrent writers, capture, settings edits or docs refresh during batches. No rollback, lock or exactly-once promise.
- Select latest exact area/service/query docs before testing status/freshness. A newer bad result masks old success. Preserve exact accepted text and recheck readiness for saved recommendation inputs.
- Keep evidence quotes and same-passage citation checks, same-surface replacements, and human review. Only response/orchestration instructions allow append/replace proposals; other surfaces investigate only. Text checks are not proof of truth or safety.
- Match current suggestion identities, not latest-by-surface history. Keep errors, invalid output, suppressed advice, missing docs, unjudged answers and no findings distinct. There is no completion ledger.
- Never put AI or search in a view. View reads can cost warehouse compute but cannot buy inference. No automatic agent changes, email, retries or documentation refresh.

## Readability and Tests

Keep named CTEs close to the question they answer. Headers must name source,
destination, customization points and paid boundaries. Comments should explain
decisions, not narrate assignments; follow the user's comment-edit constraints.
Keep an inspection after writes. Update README's ASCII lineage and the walkthrough
when a contract changes; do not export diagrams to external services.

If a model changes, align its literals in 04/06 identity, filters and calls. If an
output schema or generation/sample policy changes, update its identity version
and guards. Align edited documentation queries in the reference row and both
saved/API literals; align service names in all of 05/06.

The test contract lives in [tests/README.md](tests/README.md): a fresh disposable
`OUTPUT_DB.AGENT_FEEDBACK_TEST`, synthetic tables, and **only the listed complete
view definitions** from production files. Never run whole paid files to install
test views. Fixtures, saved results, assertions and mutations share one session.
Changes to table shape/view ownership must update fixtures and that view list.

Static review is not compilation or a passing test run. Record exactly which checks
were authorized and completed. Future SQL test PASS covers saved-data view behavior,
not live API/grant access, capture MERGE, paid batches, concurrency or production
certification. Keep this distinction in any handoff.