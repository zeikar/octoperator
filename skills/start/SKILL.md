---
name: start
description: This skill should be used when the user asks to "start work on #N", "start the issue", "begin issue 42", "pick up issue N", "create a branch for this issue", or invokes /octoperator:start. Creates a conventionally named branch for a GitHub issue and moves its board status to In Progress.
argument-hint: <issue-number> [--dry-run]
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read
version: 0.1.0
---

# Start Work

Begin work on an issue: create a conventionally named branch from the default branch and move the
issue to `In Progress` on the board. Follow the `github-conventions` skill for branch naming and the
status flow. Octoperator is autonomous: act immediately unless `--dry-run` is passed.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, and `branch_pattern` (default `{number}-{slug}`).

2. **Resolve the issue.** Take the issue number from the argument. Fetch its title:
   `gh issue view <n> --repo <repo> --json title,number,url`. If no number was given, list open issues
   assigned to the user and ask which to start.

3. **Compute the branch name.** Slugify the title (lowercase, hyphenated, ASCII, ~50 chars) and apply
   `branch_pattern` → e.g. `42-add-oauth-login`. See `references/conventions.md`.

4. **Dry-run gate.** If `--dry-run` is present, print the branch name and commands, then stop.

5. **Create the branch.** Confirm the working directory is the target repo (`gh repo view --json
   nameWithOwner`); if not, warn. Then:
   ```bash
   DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
   git fetch origin "$DEFAULT"
   git switch -c <branch> "origin/$DEFAULT"
   ```
   If the branch already exists, switch to it instead of failing.

6. **Assign + status.** Assign the issue to the current user
   (`gh issue edit <n> --add-assignee @me`). If a project is configured, run
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <issue-url> --status "In Progress"`.

7. **Report.** Print the new branch, the issue link, and the new board status.

## Notes

- This skill operates on the local clone; it assumes the user is working in the target repo. If the
  configured `repo` differs from the local repo, prefer the local repo for the branch and say so.
- Do not create commits or start coding here — only set up the branch and status.
