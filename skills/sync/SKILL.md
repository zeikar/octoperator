---
name: sync
description: This skill should be used when the user asks to "sync status", "show project status", "give me a standup", "what's the status of the project", "reconcile the board", or invokes /octoperator:sync. Produces a standup-style status report from issues, PRs, milestones, and the Projects v2 board, and auto-reconciles detected drift.
argument-hint: "[--dry-run]"
allowed-tools: Bash(gh:*), Bash(bash:*), Read
---

# Sync Status

Report the current state of the project and automatically correct board drift. Follow the
`github-conventions` skill for the status flow and reconcile patterns (`references/gh-cli-cookbook.md`,
section "Sync queries" and "Reconcile drift"). Octoperator is autonomous: apply reconciliation
immediately. With `--dry-run`, produce the report and list the drift that *would* be fixed, but make no
changes.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, and `statuses` (the board's names for the logical statuses — see
   `github-conventions` → Projects v2 status flow). If no project is configured, report from
   issues/PRs/milestones only.

2. **Gather state (read-only).**
   - Open issues, over REST (the issues API lists PRs too, so they are dropped):
     ```bash
     gh api "repos/<repo>/issues?state=open&per_page=100" --paginate --jq '.[] | select(.pull_request == null)
       | {number, title, url: .html_url, labels: [.labels[].name], milestone: .milestone.title,
          assignees: [.assignees[].login]}'
     ```
   - Open PRs, then the 20 most recently updated closed ones (the `merged` rows are the recently
     merged PRs), each as a tab-separated `<pr#> <state> <draft> <head branch> <closes> <title>`
     line. REST has no `closingIssuesReferences`, so the helper reads the closing keywords in each
     PR's body; `closes` lists this repo's issues as bare numbers, `-` for none:
     ```bash
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-pr-closes.sh --repo <repo> --state open
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-pr-closes.sh --repo <repo> --state closed --limit 20
     ```
   - Each open PR's review decision: REST has no `reviewDecision`, so read its reviews, oldest
     first. Take each reviewer's latest `APPROVED`, `CHANGES_REQUESTED`, or `DISMISSED` review:
     any `CHANGES_REQUESTED` → changes requested; else any `APPROVED` → approved; else none:
     ```bash
     gh api "repos/<repo>/pulls/<pr#>/reviews?per_page=100" --paginate \
       --jq '.[] | "\(.user.login) \(.state) \(.submitted_at)"'
     ```
   - Board items (if configured): `gh project item-list <number> --owner <project_owner> --format json`.
   - Milestones: `gh api repos/<repo>/milestones`.

3. **Build the report.** Group work by board status (`Todo`, `In Progress`, `In Review`, `Blocked`,
   `Done` — matched through `statuses`, as are the comparisons in step 4), list open PRs with their review decision and draft state, show milestone progress
   (open/closed counts, due date), and call out anything `Blocked` or stale.

4. **Detect drift.** Compare reality to the board:
   - merged PR whose closed issue (its `closes`) is not `Done` → should be `Done`;
   - open non-draft PR whose issue is not `In Review` → should be `In Review`;
   - issue with an open branch/PR still in `Todo` → should be `In Progress`.

5. **Reconcile.** Unless `--dry-run`, fix each drift with
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <url> --status "<mapped status>"`,
   and echo each change. With `--dry-run`, list the changes without applying them.

6. **Report.** Print the status report followed by a "Reconciled" (or "Would reconcile") section listing
   every change.

## Notes

- The report is the primary output; keep it scannable (grouped, with `#number` + short title + links).
- Only reconcile status that follows unambiguously from PR/issue state; never guess `Blocked`.
- If board access fails (missing `project` scope), still print the issue/PR/milestone report and note
  that the board could not be read.
