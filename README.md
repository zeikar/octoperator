# Octoperator

**Autonomous GitHub-native execution for Claude Code.**

Octoperator turns Claude Code work into a GitHub-native workflow. It converts natural-language requests
into epics, issues, sub-issues, milestones, branches, pull requests, and reviews — so agentic coding
stays traceable from **request → issue → branch → PR → review**, with GitHub as the source of truth.
An optional Projects v2 board mirrors that status when one is available (auto-detected via
`/octoperator:setup`).

Built for solo developers, small teams, and AI-assisted workflows that already use GitHub Issues, Pull
Requests, and Milestones — and, optionally, Projects — and want Claude Code to behave like a
GitHub-native project operator instead of a one-off coding assistant.

## How it works

Octoperator drives the [`gh` CLI](https://cli.github.com) — it reuses your existing `gh auth`, stores
no tokens, and runs no extra server. The trickier GraphQL / Projects-v2 operations are wrapped in small
helper scripts for reliability.

**Operating posture: autonomous.** Skills execute immediately rather than asking for confirmation. To
preview what *would* happen without writing to GitHub, pass `--dry-run` (or say "dry run"). Every write
echoes the issue/PR numbers and URLs it created so the trail stays auditable.

## Components

### Skills (slash commands)

| Skill | Command | What it does |
|-------|---------|--------------|
| Setup | `/octoperator:setup` | One-time onboarding: detect repo, auto-detect Projects v2 access, optionally create/link a board, write `.claude/octoperator.local.md` |
| Plan Epic | `/octoperator:plan-epic <request>` | Decompose a request into an epic + linked child issues, milestone, labels, board items |
| Create Issue | `/octoperator:issue <request>` | Create one well-formed issue (labels, acceptance criteria, milestone, board) |
| Start Work | `/octoperator:start <issue#>` | Create a conventionally named branch and move the issue to *In Progress* |
| Implement | `/octoperator:implement <issue#...> [--max N] [--draft] [--dry-run]` | Implement one or more issues end-to-end: branch, code, test, and PR. Single issue runs in-tree; multiple issues run in parallel worktrees (up to `--max`, default 3) |
| Open PR | `/octoperator:pr [issue#]` | Push the branch, open a PR with `Closes #N`, request reviewers, move to *In Review* |
| Review PR | `/octoperator:review <pr#>` | Run a structured review and post the verdict + findings to the PR |
| Auto | `/octoperator:auto <issue#...> [--max N] [--dry-run]` | End-to-end lifecycle: implement → review → merge for one or more issues (regular merge, gated on CI + mergeable) |
| Research | `/octoperator:research [--create] [--count N] [--dry-run]` | Analyze the repo and produce a ranked list of proposed improvements; with `--create`, file the top ones as `proposed` issues |
| Autopilot | `/octoperator:autopilot [--mode semi\|full] [--cycles N] [--max M] [--dry-run]` | Bounded loop: discover work → `auto` (implement→review→merge) → when empty, `research` refills. `semi` builds only `ready` issues then proposes; `full` runs unattended to the cycle cap |
| Sync Status | `/octoperator:sync` | Standup-style status report; auto-reconciles board drift |
| GitHub Conventions | *(auto-loaded)* | Source-of-truth conventions, `gh` cookbook, settings schema shared by all actions |

### Agents

- **`issue-planner`** — decomposes a request into an epic + well-scoped child issues (used by `plan-epic`). Read-only; proposes structure.
- **`issue-implementer`** — implements a single issue inside a pre-created worktree, commits, pushes, and opens a PR (dispatched by `implement` for each parallel issue). Never writes to the project board.
- **`pr-reviewer`** — produces a structured, actionable PR review with a verdict (used by `review-pr`). Read-only; the skill posts the result.

### Helper scripts (`scripts/`)

- **`octo-setup.sh`** — read-only probe used by `/octoperator:setup`: detect repo + default branch and whether the token can access Projects v2 (lists existing boards).
- **`octo-worktree.sh`** — manage Git worktrees for parallel issue implementation (`add`, `remove`, `list`); used by `implement` to create and clean up per-issue worktrees.
- **`octo-doctor.sh`** — verify auth/repo/project access and print the board's Status options.
- **`octo-subissue.sh`** — link a child issue to its epic as a native sub-issue (falls back to a task list).
- **`octo-project-status.sh`** — add an issue/PR to the board and set its Status by name.

## Prerequisites

- **GitHub CLI** (`gh`) installed and authenticated: `gh auth login`.
- A GitHub repository you can write to. **This is all Octoperator needs** — issues, branches, PRs,
  reviews, and traceability work without a project board.
- *(Optional)* a Projects v2 board for status tracking. Note: **user-owned Projects v2 require a
  classic PAT** with the `repo` + `project` scopes — fine-grained PATs do not support user-owned
  projects (org-owned projects work via a fine-grained token's Projects permission). `/octoperator:setup`
  auto-detects this and enables board features only when available.

## Installation

Local development / trial:

```bash
claude --plugin-dir /path/to/octoperator
```

Or install via a marketplace that lists Octoperator, then enable it in Claude Code.

## Configuration

The easiest path is the **setup skill**, which detects your repo, auto-detects whether your token can
use Projects v2, optionally creates or links a board, and writes the config:

```text
/octoperator:setup
```

Projects v2 is **optional and auto-detected** — when no board is available or configured, Octoperator
simply skips board status updates and everything else works unchanged.

Prefer to configure by hand? Settings live in `.claude/octoperator.local.md` (git-ignored):

```bash
bash scripts/octo-doctor.sh --repo <owner>/<repo> [--project <number>]   # verify access
mkdir -p .claude
cp octoperator.local.md.example .claude/octoperator.local.md             # then edit
```

> The `scripts/...` paths are relative for running by hand from a clone. Inside Claude Code the skills
> invoke them via `${CLAUDE_PLUGIN_ROOT}/scripts/...`, which resolves wherever the plugin is installed.

Only `repo` (or a discoverable current repo) is required; board operations additionally need
`project_owner` + `project_number`. No GraphQL field/option IDs are stored by hand — Octoperator
resolves them by name at call time. Full schema:
[`skills/github-conventions/references/settings.md`](skills/github-conventions/references/settings.md).

## Usage example

```text
/octoperator:plan-epic Add passwordless email login with magic links
  → Epic #10 "Add passwordless email login" + child issues #11–#14, all on the board (Todo)

/octoperator:start 11
  → branch 11-send-magic-link-email, issue #11 → In Progress

/octoperator:pr
  → PR #20 "feat: send magic-link email" (Closes #11), reviewers requested, #11 → In Review

/octoperator:review 20
  → structured review posted to PR #20 with a verdict

/octoperator:sync
  → standup report; merged-PR issues auto-moved to Done
```

Append `--dry-run` to any command to preview without writing to GitHub.

## Conventions

Octoperator follows a consistent, documented set of conventions (label taxonomy, branch naming, PR
linking, the epic/sub-issue model, the `Todo → In Progress → In Review → Done` status flow, and the
traceability matrix). They live in
[`skills/github-conventions/references/conventions.md`](skills/github-conventions/references/conventions.md).

## Troubleshooting

- **`gh: command not found`** — install the GitHub CLI: <https://cli.github.com>.
- **Project commands fail with a permission error (`Resource not accessible`, `createProjectV2`)** —
  user-owned Projects v2 are **not supported by fine-grained PATs**. Use a **classic PAT** with the
  `repo` + `project` scopes (or an org-owned project with a fine-grained token's Projects permission).
  If `gh` authenticates via the `GITHUB_TOKEN` env var, swap in the new token there and restart the
  session. Octoperator works fine without a board — board steps are skipped automatically.
- **`Status "X" not found`** — your board uses different option names; set them under `statuses:` in
  `.claude/octoperator.local.md` (run `octo-doctor.sh` to list the real options).
- **Sub-issues not linking** — the account/plan may lack the sub-issue API; Octoperator falls back to a
  `- [ ] #n` task list in the epic body automatically.

## License

MIT © zeikar
