# ADR-012: Post-PR fresh-context trim review gate

Status: Accepted (2026-09-27)

## Context

Slice work on LibreStore runs as deep autonomous agent sessions: HLD/LLD with interface contracts first, implement, tests green, PR raised. The building agent carries the full session context — dead ends explored, scaffolding used mid-build, defensive extras added "just in case", helpers that turned out unnecessary. The author is blind to their own cruft, so PRs accumulate cuttable weight:

- unused helpers and speculative abstractions,
- defensive code guarding cases the contract already excludes,
- comments/docs restating what the code says,
- scope beyond the slice's acceptance criteria.

## Decision

After raising a PR and **before requesting human review**, run a trim review gate:

1. Spawn a **dedicated review subagent with a fresh context**. Give it only:
   - the PR diff (`gh pr diff <n>`),
   - the slice's HLD/LLD docs,
   - the slice's acceptance criteria.
   
   Not the build session's full history — a clear head, no baggage.
2. Brief: *"Break down what can be cut down, what can be removed from this PR — file by file. Be brutal: every line must justify itself against the acceptance criteria. Flag dead code, over-abstraction, defensive extras, and scope creep."*
3. Apply accepted trims as follow-up commits on the PR branch; re-run the contribution checklist (`melos test`, `melos analyze --fatal-infos`, `melos format:exclude`) or `.hooks/verify.sh`; push.
4. The gate completes when the review agent signs off ("nothing further worth cutting") **and** the branch is green.

## Consequences

- Smaller, more reviewable diffs; less long-term maintenance surface.
- Cost: one extra review-agent run per PR (typically 10–20 min).
- Trims must never weaken test coverage or the contract surface promised in HLD/LLD — cutting coverage is not trimming, it is regression.
