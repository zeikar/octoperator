---
name: sync
description: This skill should be used when the user asks to "sync status", "show project status", "give me a standup", "what's the status of the project", "reconcile the board", or invokes /octoperator:sync. Produces a standup-style status report from issues, PRs, milestones, and the Projects v2 board, and auto-reconciles detected drift.
argument-hint: "[--dry-run]"
allowed-tools: Bash(gh:*), Bash(bash:*), Read
version: 0.1.0
---

# Sync Status

Report the current state of the project and automatically correct board drift. Follow the
`github-conventions` skill for the status flow and reconcile patterns (`references/gh-cli-cookbook.md`,
section "Sync queries" and "Reconcile drift"). Octoperator is autonomous: apply reconciliation
immediately. With `--dry-run`, produce the report and list the drift that *would* be fixed, but make no
changes.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`. If no project is configured, report from issues/PRs/milestones only.

2. **Gather state (read-only).**
   - Open issues: `gh issue list --repo <repo> --state open --json number,title,labels,milestone,assignees`.
   - Open PRs: `gh pr list --repo <repo> --state open --json number,title,headRefName,isDraft,reviewDecision,mergeable`.
   - Recently merged PRs: `gh pr list --repo <repo> --state merged --limit 20 --json number,title,closingIssuesReferences,mergedAt`.
   - Board items (if configured): `gh project item-list <number> --owner <project_owner> --format json`.
   - Milestones: `gh api repos/<repo>/milestones`.

3. **Build the report.** Group work by board status (`Todo`, `In Progress`, `In Review`, `Blocked`,
   `Done`), list open PRs with their review decision and draft state, show milestone progress
   (open/closed counts, due date), and call out anything `Blocked` or stale.

4. **Detect drift.** Compare reality to the board:
   - merged PR whose closing issue is not `Done` → should be `Done`;
   - open non-draft PR whose issue is not `In Review` → should be `In Review`;
   - issue with an open branch/PR still in `Todo` → should be `In Progress`.

5. **Reconcile.** Unless `--dry-run`, fix each drift with
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <url> --status "<status>"`,
   and echo each change. With `--dry-run`, list the changes without applying them.

6. **Report.** Print the status report followed by a "Reconciled" (or "Would reconcile") section listing
   every change.

## Notes

- The report is the primary output; keep it scannable (grouped, with `#number` + short title + links).
- Only reconcile status that follows unambiguously from PR/issue state; never guess `Blocked`.
- If board access fails (missing `project` scope), still print the issue/PR/milestone report and note
  that the board could not be read.
