# dbt Adaptation

**Design only.** This repository is a public, manual SQL workflow, not a drop-in
dbt package. It includes no dbt project, macros or tested dbt integration. No
existing user project, including the separate MLB pipeline, is changed by this guide.

The useful boundary is simple: capture evidence and explicitly save paid results,
then use dbt to transform saved data. Deterministic views may be adapted separately.
Do not put paid functions in dbt read views or make a routine build, full refresh,
test, preview or dashboard read invoke a model or documentation search.

## Candidate Boundaries

These are possible responsibilities, not supplied materializations:

| Existing objects | Possible dbt use |
| --- | --- |
| `REVIEW_SETTINGS`, `CHANGE_AREAS` | Governed reference inputs; preserve the single settings row and exact eight categories. |
| `AGENT_EVENTS`, `AGENT_SETTINGS_HISTORY` | Restricted persisted sources from separately approved capture. |
| `CONVERSATION_TURNS`, `ANSWER_FOLLOWUP_PAIRS`, `CURRENT_AGENT_SETTINGS` | Deterministic models over saved evidence, preserving ordering and hashes. |
| `ANSWER_REVIEW_INPUTS`, `ANSWER_REVIEWS` | Immutable sources written by a separate, bounded paid step. |
| `DOCUMENTATION_RETRIEVALS` | Persisted search responses from explicit paid retrieval. |
| `DOCUMENTATION_PASSAGES`, `DOCUMENTATION_STATUS`, `DOCUMENTATION_LATEST` | Models for accepted text, saved failures and latest exact-query readiness. |
| `REVIEW_FINDINGS`, `RECOMMENDATION_OBSERVATIONS`, `RECOMMENDATION_GROUPS`, `RECOMMENDATION_CANDIDATES` | Read models for validation, current evidence, full group counts and eligible work. |
| `RECOMMENDATION_INPUTS`, `RECOMMENDATIONS` | Immutable sources written by a separate, bounded recommendation step. |
| `RECOMMENDATION_RESULTS`, `REVIEW_QUEUE` | Read models for saved history and the current human-review queue. |

Preserve one agent per output schema. Do not copy the agent's business data,
repoint a populated installation, or change an agent as part of an adaptation.
This mapping does not reproduce the former procedure/task implementation.

## Preserve the Contracts

- Number all root-backed turns before filtering completeness; pair only adjacent complete turns in the same usable thread. Final and otherwise unpairable answers stay unjudged.
- Capture all threads in the UTC window; narrow reviews with the settings thread filter and follow-up time. Keep source UTC NTZ and saved LTZ handling distinct.
- Treat the latest saved specification as capture-time context, not a historical agent version. Follow-ups and diagnoses remain hypotheses, not truth.
- Keep ordered event/turn/pair hashes, canonical config hashes, model/revision/policy identities, and exact saved prompt bytes. Do not use unordered object serialization for identity.
- Include full and sampled review membership, raw review hashes, good counterevidence and docs service/query/content in suggestion identity. Random capture IDs/times and budgets are not identity inputs.
- Count all eligible work before capping new calls. Apply the strict occurrence threshold; sample at most three examples and two good counterexamples without losing full membership.
- Freeze bounded candidate IDs, save exact inputs, then freeze saved prompts for inference. Exclude every saved result, including invalid output and AI errors, before spending again.
- Save raw model envelopes before validating through views. Never overwrite failures; a deliberate prompt revision creates new paid work. Run reviews for that revision before suggestions.
- Require latest exact area/service/query docs to be ready, fresh and nonfuture. Rank latest before status: a newer bad retrieval must mask older ready text. Recheck readiness for saved prompts before inference.
- Keep exact evidence quotes, URL/quote matches within the same passage, same-surface replacement checks, and investigation-only handling outside response/orchestration instructions.

The public SQL uses eight explicit searches on a full documentation run, not an
automatic cache. Freshness measures retrieval age, not publication freshness. Any
separate retrieval design must state its cost and failure behavior, not quietly add
searches to reads. A failed search statement may leave no saved error row.

## Execution Is Separate

A dbt `unique_key` or merge strategy is not a cross-session lock or an exactly-once
guarantee. Failed builds, full refreshes, cancellation and concurrent writers can
repeat paid calls. Keep paid work outside ordinary model builds, require explicit
approval, serialize writers, and inspect durable inputs/results after failures.

`deferred` is computed from current candidates, not a stored placeholder. There is
no run-to-result mapping, run ledger or automatic COMPLETE status to port. The queue
matches current candidate IDs; historical proposals must not appear current merely
because they are the latest for a surface. Invalid settings, missing/bad/stale docs,
unjudged turns, saved errors and inputs without results must remain distinguishable.

Do not add email post-hooks or execute suggested changes during builds. Delivery is
a separate, literal, human-approved action; the optional file supplies no ledger.
Read models can expose sensitive text even when raw columns are hidden.

## Validation Boundary

[The SQL tests](../tests/README.md) use isolated synthetic tables and selected
production view definitions. They are authored and statically checked, **not run
or compiled in Snowflake**. They do not test a dbt adaptation.

Before adopting separate dbt models, check their output against that view-only
contract in an approved disposable environment: adjacency, UTC edges, hash reuse,
changed material inputs, full counts versus samples/caps, saved-error exclusion,
latest-bad-doc masking, citations and current-versus-historical queue membership.
Test build/full-refresh behavior separately. None of this establishes live API
access, paid-batch safety or production readiness without further evidence.