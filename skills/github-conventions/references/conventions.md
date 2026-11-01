# Octoperator Conventions (full reference)

The canonical definition of how Octoperator structures work on GitHub. Action skills follow these
rules so that every artifact is consistent and traceable.

## Label taxonomy

Octoperator expects these labels to exist in the repo. The `issue`/`plan-epic` flows create any
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

### Workflow labels (autopilot / research)

| Label | Meaning |
|-------|---------|
| `ready` | Blessed for automated build. `autopilot --mode semi` builds **only** `ready` issues. A human (or `autopilot --mode full`) decides what becomes `ready`. |
| `proposed` | Created by `research` as a candidate. In `semi` mode it awaits human triage — relabel it `ready` to build; `full` mode builds `proposed` issues directly. |
| `octoperator-ledger` | Marks the run ledger (below). Autopilot never builds it, and `research` never counts it as user feedback. |
| `needs-approval` | The change would deploy, spend money, or delete data. `research` adds it to such proposals; a human may add it to any issue. Autopilot never builds it, in either mode, until the issue also carries `approved`. |
| `approved` | A human's approval to build a `needs-approval` issue. **Only a human adds it** — Octoperator never does. In `semi` mode the issue still needs `ready` too. |

These are optional and only relevant when using `research` / `autopilot`; the skills create any of
these labels that are missing (`research` creates `needs-approval` and `approved` when it first files
a `needs-approval` proposal).

### Approval gates

Two independent gates keep deploy, spend, and delete changes in front of a human:
- **Issue gate (`autopilot`).** Discovery skips every `needs-approval` issue without `approved` and
  reports it as `gated: needs-approval`. It relies on the label, so an issue nobody labeled is not
  caught.
- **Path gate (`auto`).** Before merging, `auto` matches the PR's changed files against the
  `approval_paths` setting (see `settings.md`) with `scripts/octo-approval-match.sh`, and holds
  any PR that touches a match with the reason `needs human approval: <path>`. A human merges it by
  hand. This is the backstop for sensitive files, whatever the issue's labels.

### Run ledger

`autopilot` keeps its state between runs in GitHub, on one open issue labeled `octoperator-ledger`
(titled "Octoperator run ledger"; autopilot creates it on its first run). Each run appends one
comment holding a fenced JSON entry: time, mode, cycles used, merged, held, proposals filed, metric,
cost, and kind (`run`, `observe`, or `reset`). Autopilot reads the newest entries to detect
convergence: after `convergence_runs` entries in a row without a merge (see `settings.md`), it
switches to observe mode — `research` proposes, nothing is built — until a human runs
`autopilot --resume`. Only comments from an `OWNER`, `MEMBER`, or `COLLABORATOR` count as entries,
so autopilot must run under a `gh` login with one of those roles — a local run under your own login
has it, while a bot account without one (e.g. `github-actions[bot]`) gets its entries skipped, and
autopilot never converges.
`research` may cite an entry as `failure-log` evidence, but only for a proposal about the held
issues it names or about why runs stopped merging. The ledger is not work, so it carries no type or
priority label. Keep it open; the entry format is defined in
`skills/autopilot/SKILL.md` → Run ledger and convergence.

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
3. If that command exits non-zero (API unavailable, child already has a parent, permissions, …),
   note the printed error and **fall back**: append `- [ ] #<child#>` to the epic body's
   `## Children` checklist instead.

Either way, every child issue body opens with `Part of #<epic#>` for a textual back-link that works
regardless of the linking mechanism.

## Milestones

- Milestones represent releases or time-boxes (e.g. `v0.2`, `Sprint 14`), not epics.
- `plan-epic` and `issue` assign the configured default milestone when one is set in settings,
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
| `In Progress` | A branch is created for the issue (`implement` / `auto`) |
| `In Review`   | A PR is opened for the issue (`implement` / `auto`)     |
| `Blocked`     | Work cannot proceed (dependency, question, failure) |
| `Done`        | The PR merged / issue closed                         |

The names above are **logical** statuses. Before a board write or comparison, map each one through
the `statuses` setting (`todo`, `in_progress`, `in_review`, `blocked`, `done`); an unset key falls
back to the name shown. Pass the mapped name to `octo-project-status.sh --status`, so a board whose
options are named differently (e.g. "Backlog", "Shipped") works once `statuses` names them. Names are
then resolved against the board's actual single-select options case-insensitively, so slight
differences (e.g. "In progress") need no mapping. If a mapped name has no matching option, report it
rather than guessing.

## Merging pull requests

Merge with a **regular merge commit** (`gh pr merge <pr#> --merge --delete-branch`) — never `--squash`
or `--rebase`. A merge commit preserves the full per-commit history on the default branch (e.g. the
per-task commits behind a feature). Merge only when the latest Octoperator review's intended verdict is
not `request_changes` (any blocker/major/minor finding first goes through `auto`'s bounded fix →
re-review loop; leftover minors never block), that review covered the current head commit (pin it
with `--match-head-commit`), and the PR is `OPEN`, not draft, with `mergeStateStatus` **`CLEAN`**
(GitHub's "ready to merge" — no conflicts, all required checks green, not blocked by protection,
not behind). Any other state (`DIRTY` / `BLOCKED` / `BEHIND` / `UNSTABLE` / `UNKNOWN`) → do not
merge; report the reason. A PR that touches an `approval_paths` pattern is never merged by `auto`
either (Approval gates above). Never force-merge. The PR's `Closes #N` auto-closes the issue; move
its board item to the mapped `done` status afterward with
`octo-project-status.sh ... --status "<statuses.done>"`.

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
| autopilot run → ledger | one entry comment on the `octoperator-ledger` issue |

When any link cannot be established automatically, state which link is missing so the user can repair
it — never leave a silently broken chain.
