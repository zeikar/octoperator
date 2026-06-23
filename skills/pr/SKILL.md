---
name: pr
description: This skill should be used when the user asks to "open a PR", "create a pull request", "raise a PR", "ship this", "make a PR for this issue", or invokes /octoperator:pr. Pushes the current branch, opens a pull request linked to its issue with Closes #N, requests reviewers, and moves the work to In Review on the board.
argument-hint: "[issue-number] [--draft] [--dry-run]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read
version: 0.1.0
---

# Open PR

Open a pull request that closes its issue and moves the work to `In Review`. Follow the
`github-conventions` skill for PR linking and the status flow. Octoperator is autonomous: act
immediately unless `--dry-run` is passed.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, and default `reviewers`.

2. **Identify branch + issue.** Use the current branch (`git branch --show-current`). Derive the issue
   number from the branch prefix (`42-...` → 42) unless an explicit issue number argument overrides it.
   Fetch the issue title for the PR title: `gh issue view <n> --json title`.

3. **Determine base + draft.** Base = repo default branch. Open as `--draft` when the branch has no
   commits beyond base (`git rev-list --count origin/<default>..HEAD` is 0) or when `--draft` is passed.

4. **Dry-run gate.** If `--dry-run` is present, print the push + `gh pr create` commands and the PR
   body, then stop.

5. **Push + create.** Push the branch (`git push -u origin <branch>`), then `gh pr create` with:
   - `--base <default> --head <branch>`;
   - title mirroring the issue (optionally `feat:`/`fix:` prefix by issue type);
   - a body whose first line is `Closes #<issue>`, followed by a `## Summary` of the changes;
   - `--reviewer` for each configured reviewer (skip self).
   Capture the PR number/URL.

6. **Move to In Review.** If a project is configured, set both the PR and its issue to `In Review`:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <pr-url> --status "In Review"
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <issue-url> --status "In Review"
   ```

7. **Report.** Print the PR number, URL, draft state, requested reviewers, and the linked issue.

## Notes

- If `Closes #<issue>` cannot be determined (branch has no issue prefix and none was given), create the
  PR without the link but warn that issue↔PR traceability is missing.
- Never force-push or rewrite history here.
