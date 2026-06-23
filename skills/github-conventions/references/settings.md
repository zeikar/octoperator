# Octoperator settings

Per-project configuration lives in `.claude/octoperator.local.md`, relative to the repository root.
It is git-ignored (it is machine/project-specific) and read as YAML frontmatter followed by optional
notes. Octoperator reads it at the start of every action to resolve targets and defaults.

The easiest way to create it is `/octoperator:setup`, which detects the repo, auto-detects Projects v2
access, optionally links/creates a board, and writes this file. The Projects v2 board is **optional**:
when `project_owner`/`project_number` are absent, Octoperator skips all board steps and everything else
works unchanged.

## Schema

```markdown
---
# Target repository (owner/name). Defaults to the current repo if omitted.
repo: zeikar/octoperator

# Projects v2 board. owner may differ from the repo owner (user vs org projects).
project_owner: zeikar
project_number: 7
project_url: https://github.com/users/zeikar/projects/7

# Default milestone applied to new issues (optional).
milestone: v0.2

# Branch name pattern. Tokens: {number}, {slug}. Default: "{number}-{slug}".
branch_pattern: "{number}-{slug}"

# Default reviewers requested on new PRs (GitHub logins). Optional.
reviewers:
  - alice
  - bob

# Status field option names on the board, in flow order. Override only if the
# board uses different names. Resolved case-insensitively against real options.
statuses:
  todo: Todo
  in_progress: In Progress
  in_review: In Review
  blocked: Blocked
  done: Done

# Label taxonomy overrides (optional). Defaults match references/conventions.md.
labels:
  types: [epic, feature, bug, chore, docs]
  priorities: [p0, p1, p2, p3]
  default_priority: p2
---

# Notes
Free-form project notes for humans; Octoperator ignores this section.
```

## Reading settings

Read the file directly (it is short) and use the frontmatter values. When the file is absent:

- Resolve `repo` from `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
- Skip project/board operations and warn that no project is configured.
- Suggest creating the file (see bootstrap below).

Only `repo` (or a discoverable current repo) is strictly required. Project operations additionally need
`project_owner` + `project_number`. Everything else has sane defaults.

## Bootstrap

1. Find or create a Projects v2 board:
   ```bash
   gh project list --owner <owner>
   gh project create --owner <owner> --title "<name>"   # if needed
   ```
2. Verify access and discover the board's real Status options:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-doctor.sh --repo <owner>/<name> --project <number>
   ```
3. Create `.claude/octoperator.local.md` with the schema above, filling in `repo`,
   `project_owner`, `project_number`, and adjusting `statuses` only if the doctor output shows
   different option names.

No GraphQL field/option IDs need to be recorded by hand — Octoperator resolves them by name at call
time via `octo-project-status.sh`.

## Security

- The file may name internal repos, project numbers, and reviewers; it is git-ignored by the
  plugin's `.gitignore` (`.claude/*.local.md`). Never commit it.
- No tokens are stored here — authentication is delegated entirely to `gh auth`.
