# Octoperator Conventions (full reference)

The canonical definition of how Octoperator structures work on GitHub. Action skills follow these
rules so that every artifact is consistent and traceable.

## Label taxonomy

Octoperator expects these labels to exist in the repo. The `start-work`/`plan-epic` flows create any
that are missing (see the cookbook's "ensure labels" recipe).

### Type labels (exactly one per issue)

| Label     | Meaning                                   | Color (suggested) |
|-----------|-------------------------------------------|-------------------|
| `epic`    | A large body of work decomposed into children | `#6f42c1`     |
| `feature` | New user-facing capability                | `#0e8a16`         |
| `bug`     | Defect in existing behavior               | `#d73a4a`         |
| `chore`   | Maintenance, tooling, refactor, deps      | `#fbca04`         |
| `docs`    | Documentation only                        | `#0075ca`         |

### Priority labels (exactly one per issue; default `p2`)

| Label | Meaning   |
|-------|-----------|
| `p0`  | Critical / drop-everything |
| `p1`  | High      |
| `p2`  | Normal (default) |
| `p3`  | Low / someday |

### Status labels (optional, mirror the board)

The Projects v2 board is the primary status surface. Status labels (`status:blocked`) are only added
when an issue must signal state without a project (e.g. repos without a project configured).

## Branch naming

`<issue-number>-<kebab-slug>` derived from the issue title, branched from the repository's default
branch.

- Lowercase, hyphen-separated, ASCII only; strip punctuation.
- Truncate the slug to ≤50 characters at a hyphen boundary (drop whole `-` segments; never cut mid-word).
- Examples: issue #42 "Add OAuth login" → `42-add-oauth-login`; issue #7 "Fix flaky upload test" →
  `7-fix-flaky-upload-test`.
- The pattern is configurable via `branch_pattern` in settings using the tokens `{number}` and
  `{slug}` (default `{number}-{slug}`).

## Pull request linking

- The PR body MUST contain `Closes #<issue>` (or `Fixes #<issue>`) referencing the primary issue, so
  merging the PR auto-closes the issue and keeps issue↔PR traceability.
- PR title mirrors the issue title (optionally prefixed with the type, e.g. `feat:`/`fix:`).
- Open PRs as **draft** when the branch has no commits beyond the base, otherwise ready-for-review.
- Add the PR to the project board and set status to `In Review`.

## Epic model: native sub-issues

An epic is a normal issue carrying the `epic` label. Children are attached using GitHub's native
**sub-issue** relationship (parent/child tree + progress bar in the GitHub UI).

Linking procedure (per child):

1. Create the child issue normally (type/priority labels, milestone, project).
2. Link it to the epic with `octo-subissue.sh --repo <owner>/<name> --parent <epic#> --child <child#>`.
3. If that command exits non-zero (sub-issue API unavailable on the plan/account), **fall back**:
   append `- [ ] #<child#>` to the epic body's `## Children` checklist instead.

Either way, every child issue body opens with `Part of #<epic#>` for a textual back-link that works
regardless of the linking mechanism.

## Milestones

- Milestones represent releases or time-boxes (e.g. `v0.2`, `Sprint 14`), not epics.
- `plan-epic` and `create-issue` assign the configured default milestone when one is set in settings,
  unless the request names a different milestone.
- Do not conflate a milestone with an epic; an epic groups *related* work, a milestone groups work
  *shipping together*.

## Projects v2 status flow

The board is an **optional enhancement**. When no project is configured (or the token cannot access
Projects v2), skip every board step — the rest of the chain (issues, sub-issues, branches, PRs,
reviews) is unaffected. When a board *is* configured, mirror status through this flow:

```
Todo → In Progress → In Review → Done
                ↘ Blocked ↗
```

| Status        | Set when                                            |
|---------------|-----------------------------------------------------|
| `Todo`        | Issue created and added to the board                |
| `In Progress` | A branch is created for the issue (`start-work`)    |
| `In Review`   | A PR is opened for the issue (`open-pr`)            |
| `Blocked`     | Work cannot proceed (dependency, question, failure) |
| `Done`        | The PR merged / issue closed                         |

Status names are resolved against the board's actual single-select options by name (case-insensitive),
so boards using slightly different labels (e.g. "In progress") still work. If a configured status name
has no matching option, report it rather than guessing.

## Merging pull requests

Merge with a **regular merge commit** (`gh pr merge <pr#> --merge --delete-branch`) — never `--squash`
or `--rebase`. A merge commit preserves the full per-commit history on the default branch (e.g. the
per-task commits behind a feature). Gate the merge on a single authoritative signal: merge only when
the PR is `OPEN`, not draft, and its `mergeStateStatus` is **`CLEAN`** (GitHub's "ready to merge" — no
conflicts, all required checks green, not blocked by protection, not behind). Any other state
(`DIRTY` / `BLOCKED` / `BEHIND` / `UNSTABLE` / `UNKNOWN`) → do not merge; report the reason. Never
force-merge. The PR's `Closes #N` auto-closes the issue; move its board item to `Done` afterward with
`octo-project-status.sh ... --status "Done"`.

## Traceability matrix

| From → To              | Mechanism                                   |
|------------------------|---------------------------------------------|
| request → epic         | epic issue body records the original request|
| epic → child issue     | native sub-issue link + `Part of #<epic>`   |
| issue → branch         | branch name `<issue#>-<slug>`               |
| branch → PR            | PR opened from the branch                    |
| issue → PR             | PR body `Closes #<issue>`                    |
| PR → review            | review posted to the PR on GitHub           |
| issue/PR → board       | project item with mirrored Status field     |

When any link cannot be established automatically, state which link is missing so the user can repair
it — never leave a silently broken chain.
