# Workflow — how we ship on this project

## No worktrees

One checkout, one working tree: `~/workspace/app-center`. No `git worktree`
for this project — not by hand, not by subagents. Parallelism comes from
stacked branches, not stacked directories.

## Stacked PRs via `gh`

Every change is a branch; every branch is a PR; PRs stack:

```
main (upstream) … feat/unified-store → feat/store-contracts → feat/backend-flatpak
```

- New work: `git checkout -b feat/<scope> <parent-branch>`
- PR: `gh pr create --base <parent-branch> --head feat/<scope>`
- The repo is private; PRs target the parent branch, never `main` directly.
- Merge bottom-up when the stack is green.
- Subagents follow the same rule: branches + stacked PRs, no worktrees.

## Validation is local-first

`gh` is for PRs, not for CI. Until decided otherwise:

- `python3 scripts/dep_trace.py --report <file>` — coupling map
- `python3 scripts/feature_map_check.py` — feature map drift (exit 1 = fix the map)
- `melos analyze`, `melos test` — lint + tests

GitHub CI is the last step, not the first. The gates are the same either way.
