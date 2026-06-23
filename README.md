# Octoperator

**Autonomous GitHub project execution for Claude Code.**

Octoperator turns Claude Code work into a GitHub-native workflow. It converts natural-language requests
into epics, issues, sub-issues, milestones, branches, pull requests, reviews, and Projects v2 status
updates — so agentic coding stays traceable from **request → issue → branch → PR → review → project
status**, with GitHub as the source of truth.

Built for solo developers, small teams, and AI-assisted workflows that already use GitHub Issues,
Projects, Pull Requests, and Milestones, and want Claude Code to behave like a GitHub-native project
operator instead of a one-off coding assistant.

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
| Plan Epic | `/octoperator:plan-epic <request>` | Decompose a request into an epic + linked child issues, milestone, labels, board items |
| Create Issue | `/octoperator:issue <request>` | Create one well-formed issue (labels, acceptance criteria, milestone, board) |
| Start Work | `/octoperator:start <issue#>` | Create a conventionally named branch and move the issue to *In Progress* |
| Open PR | `/octoperator:pr [issue#]` | Push the branch, open a PR with `Closes #N`, request reviewers, move to *In Review* |
| Review PR | `/octoperator:review <pr#>` | Run a structured review and post the verdict + findings to the PR |
| Sync Status | `/octoperator:sync` | Standup-style status report; auto-reconciles board drift |
| GitHub Conventions | *(auto-loaded)* | Source-of-truth conventions, `gh` cookbook, settings schema shared by all actions |

### Agents

- **`issue-planner`** — decomposes a request into an epic + well-scoped child issues (used by `plan-epic`). Read-only; proposes structure.
- **`pr-reviewer`** — produces a structured, actionable PR review with a verdict (used by `review-pr`). Read-only; the skill posts the result.

### Helper scripts (`scripts/`)

- **`octo-doctor.sh`** — verify auth/repo/project access and print the board's Status options.
- **`octo-subissue.sh`** — link a child issue to its epic as a native sub-issue (falls back to a task list).
- **`octo-project-status.sh`** — add an issue/PR to the board and set its Status by name.

## Prerequisites

- **GitHub CLI** (`gh`) installed and authenticated: `gh auth login`.
- For Projects v2 board updates, a token with the **`project`** scope: `gh auth refresh -s project`.
- A GitHub repository (and optionally a Projects v2 board) you can write to.

## Installation

Local development / trial:

```bash
claude --plugin-dir /path/to/octoperator
```

Or install via a marketplace that lists Octoperator, then enable it in Claude Code.

## Configuration

Octoperator reads per-project settings from `.claude/octoperator.local.md` (git-ignored). Bootstrap it:

```bash
# 1. (optional) create or find a Projects v2 board
gh project list --owner <owner>

# 2. verify access and discover your board's Status options
bash scripts/octo-doctor.sh --repo <owner>/<repo> --project <number>

# 3. copy the template and fill it in
mkdir -p .claude
cp octoperator.local.md.example .claude/octoperator.local.md
```

> The `scripts/...` paths above are relative for running by hand from a clone. Inside Claude Code the
> skills invoke these scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/...`, which resolves wherever the
> plugin is installed.

Only `repo` (or a discoverable current repo) is required. Board operations additionally need
`project_owner` + `project_number`. No GraphQL field/option IDs are stored by hand — Octoperator
resolves them by name at call time. See the full schema in
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
- **Project commands fail with a permission error** — run `gh auth refresh -s project`.
- **`Status "X" not found`** — your board uses different option names; set them under `statuses:` in
  `.claude/octoperator.local.md` (run `octo-doctor.sh` to list the real options).
- **Sub-issues not linking** — the account/plan may lack the sub-issue API; Octoperator falls back to a
  `- [ ] #n` task list in the epic body automatically.

## License

MIT © zeikar
