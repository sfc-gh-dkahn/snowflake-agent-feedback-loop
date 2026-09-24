# Walkthrough

Follow one conversation from captured events to a finding, then decide whether a
documentation-backed suggestion is worth generating. This guide uses a synthetic
sales assistant and an invented thread label, `example-thread`. Neither names a
real account or promises that your agent has the same data or behavior.

The SQL is source-only and statically reviewed. The isolated tests are authored,
not compiled or run in Snowflake. This guide describes intended behavior, not a
verified production installation.

## 1. Set the Scope

Complete the [README dependency checklist and literal edits](../README.md).
Use one existing agent per empty output schema, an approved role and an existing
warehouse. No script creates the database, schema, role, warehouse or agent.

In `sql/00_setup.sql`, edit the `REVIEW_SETTINGS` seed for a short UTC window that
contains a known conversation. Replace the synthetic thread label with a real one
only in your private copy. Start with `max_new_reviews = 1` and
`max_new_recommendations = 1`. Keep `min_occurrences = 2`: the first pass may give
you a finding without enough evidence for a suggestion. That is useful, not failure.

Run 00 statement by statement. It creates and seeds two reference tables:
`REVIEW_SETTINGS` and the eight-row `CHANGE_AREAS`. Read the stored values and
require a ready configuration status. The seed writes only into an empty table.
After setup, change the existing settings row with `UPDATE`, keyed on
`settings_id = 1`; do not edit the seed expecting it to reset saved settings.

The dates, thread filter, call caps, threshold, docs age and revision belong only
in that row. The four literal choices in the README remain at their call sites.
Keep the model literals aligned across 04/06 and the service literals across 05/06.

Window start is inclusive and end is exclusive. End must be at least 15 minutes
before current UTC time; the span must not exceed 90 elapsed days. These are project
guards, not a guarantee of event availability. `NULL` thread filter means all
threads; blank, whitespace-only and `0` are invalid. All call caps must be positive.

## 2. Check Before Capturing

Run the checks in `sql/01_preflight.sql` in order:

0. Run the **Prerequisites & Privileges probe** (test `AI_COMPLETE` and `SEARCH_PREVIEW` access).
1. Read `settings_status` and each named check. Fix failing settings before continuing.
2. Read `DESCRIBE AGENT`. Expect one row with the intended `agent_spec`; stop on a naming or access error.
3. Read the evidence counts. Compare `complete_traces` across all threads with `complete_traces_in_scope` for your selected thread.
4. Run the **Activity Profiling query** to inspect trace counts by day if you need help picking an active review window.

A thread is a conversation, a trace is one turn, and a span records part of that
turn. A complete turn needs a root, a usable question and a usable answer. Counts
also expose missing roots, missing text and unusable thread IDs. Missing or redacted
text does not prove the agent failed to answer.

Valid settings produce one count row even with zero traffic. No row means the
settings guard rejected the scope. Complete turns do not yet prove that any can
form adjacent pairs. Preflight does not check output-write privileges, model access
or documentation-service readiness.

## 3. Capture the Evidence

Run `sql/02_capture_context.sql` in order. Submit its entire
`DESCRIBE AGENT ->> INSERT ... ;` chain as **one statement**, not two selections.
The pipe passes the description directly into `AGENT_SETTINGS_HISTORY`.

Each capture appends a settings snapshot. The event `MERGE` adds distinct selected
spans to `AGENT_EVENTS`, leaving saved rows unchanged. An overlapping capture can
collect late arrivals without adding identical events again. Read the snapshot,
saved counts and event sample after the writes.

**Capture saves all threads in the selected window.** `thread_filter` controls
preflight's in-scope count and later reviews, not event collection. Tool spans may
have no thread ID; capture keeps them so their trace can supply the missing link.
Capture counts cover all saved history, not just new rows from this execution.

The source event timestamp is already UTC `TIMESTAMP_NTZ`. Capture saves the same
instant as `TIMESTAMP_LTZ` using epoch nanoseconds; 03 converts that saved column
back to UTC NTZ for comparisons. The settings dates use UTC by convention, since
NTZ itself has no zone. Capture time is separate from the time an event occurred.

An agent snapshot describes settings **when captured**, not when older answers
were produced. The latest saved snapshot is not a live read of the agent. Even an
invalid review window does not undo an already-saved snapshot. Events can arrive
late, be unavailable, or straddle a window edge. Choose a window wide enough for
context, and inspect the actual saved turns rather than assuming full coverage.

## 4. Rebuild the Conversation

Run `sql/03_prepare_feedback.sql`. It creates two views over all saved events,
not new copies of those events. `CONVERSATION_TURNS` picks one root per trace,
the earliest usable question, and ordered tool evidence. It numbers every
root-backed turn **before** testing completeness.

Here is a synthetic complete three-turn thread:

```text
Turn 1: User asks for September sales. Agent gives an annual total.
Turn 2: User says "September only, please." Agent gives September sales.
Turn 3: User says "That matches my September report." Agent acknowledges.

Turn 1 answer + turn 2 follow-up -> one reviewable pair
Turn 2 answer + turn 3 follow-up -> one reviewable pair
Turn 3 answer                  -> unjudged: no next turn
```

The correction may support a poor assessment; the confirmation may support a good
one. Neither is a measured grade. A new topic or a simple thank-you may be unclear.
If turn 2 lacks a usable question or answer, neither pair qualifies. The SQL never
skips turn 2 to pair turns 1 and 3. Unknown, blank and `0` threads never pair.

`ANSWER_FOLLOWUP_PAIRS.evidence` holds the follow-up plus complete turns from the
six positions ending at the answer being reviewed. It is not six extra turns, and
it does not reach farther back to fill an incomplete position. For the second pair
above, prior context includes turns 1 and 2; turn 3 is the follow-up.

Inspect pairs and unpaired answers before paying. Three complete turns can yield
two pairs, not three judged answers. 04 selects pairs by **follow-up time** in the
settings window. Earlier saved context can fall outside that window.

## 5. Review Answers (Paid)

Run `sql/04_diagnose.sql` sequentially in one SQL session. Do not change settings,
capture more events, or start another writer while it runs.

1. Inspect `CURRENT_AGENT_SETTINGS` and `ANSWER_REVIEW_SETTINGS_STATUS`. Missing or nonobject specifications cannot feed a review.
2. Read `REVIEW_CANDIDATES`: eligible unsaved reviews, those within the cap and those deferred. Saved results, including errors, are excluded before ranking.
3. Freeze `ANSWER_REVIEW_BATCH` and save its exact prompts in `ANSWER_REVIEW_INPUTS`.
4. Freeze `ANSWER_REVIEW_INFERENCE_BATCH` from saved prompts. Read its preview immediately before the paid insert. Stop here if scope or cost is not approved.
5. Run the paid insert into `ANSWER_REVIEWS`, then create/read `REVIEW_FINDINGS` and the inspection results.

The paid insert uses `AI_COMPLETE` and saves its raw `value`/`error` envelope.
Validation then checks saved data without another model call. `valid` means the
required fields and exact evidence quote passed checks, not that the conclusion
is true. Read `observation` separately from `suspected_cause`. `invalid_output` and
`ai_error` remain visible and saved.

With a cap of one, the example may leave a second review deferred. Another
deliberate run of 04 can take the next unsaved identity if it remains eligible.
The displayed backlog is a current read, not a persisted execution record.

Row caps do not cap tokens or credits. Full selected conversation text remains in
prompts; oversized prompts can error. Character counts are size clues, not token
counts or cost estimates. Re-reading any view uses warehouse compute, not new AI.

## 6. Retrieve Documentation (Paid)

Run `sql/05_retrieve_documentation.sql` after 04. On first setup it creates
`DOCUMENTATION_RETRIEVALS` and three views, then runs **eight explicit paid search
inserts**, one per change area. All eight run on a full execution, whether findings
exist or saved passages are fresh. `REVIEW_SETTINGS` does not limit these calls.

The queries are generic feature questions, never conversation text. The service
must expose `SOURCE_URL`, `DOCUMENT_TITLE`, `CHUNK`. Accepted passages require the
official `https://docs.snowflake.com/` prefix and usable text. Rejected entries stay
in the raw response. Accepted text keeps its original whitespace for quote checks.

Inspect `DOCUMENTATION_STATUS`, query alignment, readiness and the saved passages.
Match the exact area, service and query. Changing `CHANGE_AREAS.documentation_query`
does not change a search call: each insert has both a saved query literal and a
literal API query that must agree with the reference row.

For a later refresh, manually run the one area's complete insert and inspections,
or deliberately run all eight. There is **no automatic cache or refresh**.
`docs_max_age_hours` gates recommendation readiness; it measures retrieval age,
not publication date or service-index freshness. Future capture times are invalid.

`DOCUMENTATION_LATEST` chooses the latest exact search before checking its status.
A newer empty, rejected, malformed or error response masks older ready passages;
it does not fall back. A mixed response can be ready with rejected entries, but
only its accepted passages can support a suggestion. Search may truncate large
responses, so saved passages are not proof of full-document coverage.

If a search statement fails, **stop**. It cannot save that failure as a row, even
though prior inserts remain. Do not continue with old docs after a failed refresh.
Resolve the cause and decide whether to pay for a retry; status views cannot expose
an unsaved statement failure.

## 7. Draft Suggestions (Paid)

Run `sql/06_recommendations.sql` in order in one session, with no concurrent
writers, settings changes, capture or documentation refresh. It reads saved reviews
that match current evidence, captured settings, window, model and prompt revision.
A newer saved failed review masks an older success under the same selection scope.

`RECOMMENDATION_GROUPS` groups observations by agent and change area. It counts all
distinct reviewed answers before applying `min_occurrences`. Poor agent behavior
qualifies on nondata areas; reported data gaps qualify on `data` even if assessed
good or unclear. There is no severe-finding or repeated-thread threshold bypass.
Grouping does not prove that the answers share a cause.

A group with five qualifying answers reports five occurrences, but the prompt
contains at most **three examples**. It also contains at most **two good
counterexamples** from the same agent's current review scope, across any area.
Full and sampled member identities remain saved. Severity affects sample order,
not threshold eligibility. The three-turn example alone need not qualify a group.

Read the group gates, then `RECOMMENDATION_CANDIDATES` for reused results, new work
within the separate cap, and deferred groups. Settings, eight valid areas, enough
evidence and fresh ready exact-query docs must all pass. Save the frozen batch into
`RECOMMENDATION_INPUTS`. Preview `RECOMMENDATION_INFERENCE_BATCH` immediately before
the paid insert into `RECOMMENDATIONS`. Freshness is checked again before inference.

`RECOMMENDATION_RESULTS` validates the saved output. Warranted advice needs exact
quotes at the supplied URLs in the same saved passages. Replacements must quote
existing text from the same instruction surface. Only response/orchestration
instructions permit append or replace proposals; other areas permit investigation.
Matching text does not prove the citation supports the advice.

A warranted reported data gap needs two distinct actions: how a person checks the
reported scope, and how the agent responds when data is unknown. It cannot establish
that a table, row or permission is missing, or invent a contact. Text checks can
reject harmless wording and miss unsafe advice. Every proposal needs human review.

## 8. Inspect, Then Decide

Run `sql/07_inspect_results.sql`. It reads existing objects only. Read settings
first, then full-history coverage, selected-window backlog, raw results and errors,
saved inputs without results, the current queue, history and duplicate IDs.

| Queue state | What to check |
| --- | --- |
| `invalid_settings` | Settings and change-area status; a sentinel row is not an evidence group. |
| `insufficient_evidence` | Distinct answer count against the threshold. |
| `missing_docs`, `bad_docs`, `stale_docs` | Exact service/query match, latest response and retrieval age. |
| `deferred`, `awaiting_inference` | Current cap and whether selected inputs have a saved result. |
| `ai_error`, `invalid_output` | Saved error or validation reason; not an automatic retry request. |
| `suppressed` | No warranted recommendation or risk of regressing good behavior. |
| `needs_human_review` | Read evidence, counterexamples, citations and scope before deciding. |

Full-history counts are not selected-window counts. Invalid settings give NULL
selected-window counts rather than a false zero-work result. Unpaired complete
turns remain unjudged; incomplete turns are separate. A saved input without a result
may no longer be eligible. Zero suggestions can mean no qualifying evidence, no
usable pairs, blocked settings/docs, deferred work or failed processing.

`REVIEW_QUEUE` joins the current candidate identity, not the latest result for a
surface. Old results stay in history after evidence/config/docs changes or docs
expiry. There is no run ledger, automatic COMPLETE status or automatic agent change.

## Repeat or Recover

Run statements sequentially with AUTOCOMMIT and no open transaction. Stop on any
error; earlier successful writes remain. The scripts do not provide a multi-step
rollback or an execution lock. Inspect saved inputs/results before restarting the
affected file in order, and rebuild temporary batches rather than jumping into a
paid insert from another session.

Saved errors and invalid results are final for their identity. To retry unchanged
evidence deliberately, update `prompt_revision` and run 04 before 06. This can
re-review the selected scope, not just one failed row, and incurs new charges.
Do not delete or overwrite saved results to force a retry.

Changed evidence, configuration content, model or prompt/schema policies can create
new review identities. Recommendation identities also include full/sample review
membership and docs service/query/content. Unchanged recaptures and fresh retrievals
of identical docs content can reuse results. Capture IDs/times and budget-only
changes do not themselves create new identities; thresholds and docs age affect
eligibility. Moving the window can change group membership and thus suggestion IDs.

No exactly-once guarantee exists. A statement can spend money then fail to persist;
cancellation, retry or concurrent execution can repeat charges. Documentation
refreshes always cost again when explicitly run.

For the next window, update the one settings row, preflight, capture, read the
existing 03 views (recreate only after definition changes), run 04, refresh needed
docs manually, run 06, then inspect 07. Current reads cannot reconstruct a run log.

## Optional Email

After 00-07, [optional/email.sql](../optional/email.sql) previews queue counts and
at most 20 headlines. Running it as shipped sends nothing and writes nothing.
Headlines can still disclose sensitive information; formatting is not redaction.

For an approved send, review the actual subject/body and recipient. Use the
commented literal `SYSTEM$SEND_EMAIL` example in a separate worksheet with an
existing email integration and validated recipient. Keep the shipped call commented
out. Follow its literal escaping rules; never paste model output as executable SQL.
See [official email prerequisites](https://docs.snowflake.com/en/user-guide/notifications/email-stored-procedures).

There is no delivery ledger, deduplication or automatic resend. A successful call
does not prove inbox delivery; reconcile uncertainty before sending again.

## Test Separately

Follow [tests/README.md](../tests/README.md) only in an approved, empty disposable
test schema. It installs selected **view statements only**, not whole paid scripts,
and supplies synthetic saved results. Those tests have not been run. Even a future
PASS would not prove live access, APIs, capture, paid batches or concurrency safety.