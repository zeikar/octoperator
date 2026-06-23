---
name: review
description: This skill should be used when the user asks to "review PR #N", "review this pull request", "do a code review on the PR", "leave a review on N", or invokes /octoperator:review. Runs a structured review of a GitHub pull request and posts the verdict and findings back to the PR.
argument-hint: "<pr-number> [--approve|--request-changes|--comment] [--dry-run]"
allowed-tools: Bash(gh:*), Bash(git:*), Read, Task
version: 0.1.0
---

# Review PR

Produce a structured review of a pull request and post it to GitHub, preserving the review as a
durable artifact. Follow the `github-conventions` skill for the review recipe and the self-approval
constraint. Octoperator is autonomous: post immediately unless `--dry-run` is passed.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`. Take the PR number from the
   argument.

2. **Gather context.** Fetch PR metadata and diff:
   `gh pr view <pr#> --repo <repo> --json title,author,body,headRefName,baseRefName,files,additions,deletions`
   and `gh pr diff <pr#> --repo <repo>`.

3. **Run the reviewer.** Dispatch the `pr-reviewer` agent (Task tool) with the PR metadata and diff. It
   returns structured findings (each with severity, `path:line`, explanation, suggested fix) and an
   overall verdict (`approve` / `request_changes` / `comment`).

4. **Resolve the review action.** An explicit `--approve`/`--request-changes`/`--comment` flag wins;
   otherwise use the agent's verdict. **Self-approval guard:** if the PR author equals the
   authenticated user (`gh api user --jq '.login'`), GitHub forbids `APPROVE` and `REQUEST_CHANGES` —
   downgrade to `--comment` and state the intended verdict in the body.

5. **Dry-run gate.** If `--dry-run` is present, print the assembled review body and the chosen action,
   then stop without posting.

6. **Post the review.** Format the body as Markdown: a one-line verdict, then findings grouped by
   severity with `path:line` references and suggested fixes. Post with the resolved action:
   ```bash
   gh pr review <pr#> --repo <repo> --comment         --body "<body>"   # or
   gh pr review <pr#> --repo <repo> --approve         --body "<body>"   # or
   gh pr review <pr#> --repo <repo> --request-changes --body "<body>"
   ```

7. **Report.** Print the verdict, the count of findings by severity, and the PR URL.

## Notes

- Default to a single summary review whose body cites `path:line`; this is reliable across all repos.
  Inline line comments are optional and require the REST review API (see the cookbook).
- Keep findings actionable and specific; avoid style nits unless they affect correctness or clarity.
- If the diff is empty or the PR is closed/merged, report that and do not post.
