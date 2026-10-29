---
name: review
description: This skill should be used when the user asks to "review PR #N", "review this pull request", "do a code review on the PR", "leave a review on N", or invokes /octoperator:review. Runs a structured review of a GitHub pull request and posts the verdict and findings back to the PR.
argument-hint: "<pr-number> [--approve|--request-changes|--comment] [--dry-run]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read, Task
---

# Review PR

Produce a structured review of a pull request and post it to GitHub, preserving the review as a
durable artifact. Follow the `github-conventions` skill for the review recipe and the self-approval
constraint. Octoperator is autonomous: post immediately unless `--dry-run` is passed.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`. Take the PR number from the
   argument.

2. **Gather context.** Fetch PR metadata and diff:
   `gh pr view <pr#> --repo <repo> --json title,author,body,state,headRefName,headRefOid,baseRefName,files,additions,deletions`
   and `gh pr diff <pr#> --repo <repo>`. If the PR is closed/merged or the diff is empty, report that
   and stop (see Notes). `gh pr diff` fetches by PR number, so a push in between can pair the metadata
   of one commit with the diff of another: re-read `headRefOid` after the diff and, if it changed,
   gather both again once; if it changes again, report that the PR is being pushed to and stop.

3. **Check out the PR head.** The reviewer must read and test the PR's code, not whatever the current
   checkout holds (the default branch, another feature branch, or a worktree `implement` already
   removed). Create a throwaway detached worktree at the exact `headRefOid` the diff came from; this
   leaves the user's checkout, index, and branches untouched:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/octo-exclude.sh"   # keep .octoperator/ out of git status
   # Unique per run ($$), so concurrent reviews of the same PR never share or delete each other's tree.
   REVIEW_WT="$(git rev-parse --show-toplevel)/.octoperator/worktrees/review-<pr#>-$$"
   git fetch --no-tags origin "refs/pull/<pr#>/head" \
     || echo "fetch of PR head failed; trying the local object store"
   # git prints "HEAD is now at …" on stdout; drop it so only the path is printed (errors stay on stderr).
   git worktree add --detach "$REVIEW_WT" "<headRefOid>" >/dev/null && echo "$REVIEW_WT"
   ```
   Record the printed absolute path — later steps run in separate shells and need it verbatim. Adding
   by `headRefOid` (not `FETCH_HEAD`) both pins the reviewed code to the gathered diff and verifies
   it: if `origin` is not `<repo>` or the commit is otherwise unavailable, the add fails (as it does
   on an existing non-empty path — never remove a tree this run did not create). In that case continue
   **without** a worktree and tell the reviewer so (step 4).

4. **Run the reviewer.** Dispatch the `pr-reviewer` agent (Task tool) with the PR metadata, the diff
   from step 2, and `worktree` = the recorded absolute path (or "none" when step 3 failed). It returns
   structured findings (each with severity, `path:line`, explanation, suggested fix) and an overall
   verdict (`approve` / `request_changes` / `comment`).

   Then remove the review worktree this run created — always, whatever the reviewer returned.
   `--force` because test runs may leave build artifacts; the tree holds no commits or branch of its
   own:
   ```bash
   git worktree remove --force "<recorded REVIEW_WT path>"
   ```

5. **Resolve the review action.** An explicit `--approve`/`--request-changes`/`--comment` flag wins;
   otherwise use the agent's verdict. **Self-approval guard:** if the PR author equals the
   authenticated user (`gh api user --jq '.login'`), GitHub forbids `APPROVE` and `REQUEST_CHANGES` —
   downgrade to `--comment` and state the intended verdict in the body.

6. **Dry-run gate.** If `--dry-run` is present, print the assembled review body and the chosen action,
   then stop without posting.

7. **Post the review.** Format the body as Markdown: a one-line verdict, then findings grouped by
   severity under the reviewer's own `### Blockers` / `### Major` / `### Minor` / `### Nits`
   headings (minors and nits stay separate, so `auto` and the human see the same grouping), with
   `path:line` references and suggested fixes. Post with the resolved action:
   ```bash
   gh pr review <pr#> --repo <repo> --comment         --body "<body>"   # or
   gh pr review <pr#> --repo <repo> --approve         --body "<body>"   # or
   gh pr review <pr#> --repo <repo> --request-changes --body "<body>"
   ```

8. **Report.** Print the **intended** verdict (step 5's resolution *before* the self-approval
   downgrade) alongside the posted action, the reviewed `headRefOid`, the count of findings by
   severity, and the PR URL. `auto` gates its merge on the intended verdict and the reviewed commit,
   and hands the blocker/major/minor findings to its fixer.

## Notes

- Default to a single summary review whose body cites `path:line`; this is reliable across all repos.
  Inline line comments are optional and require the REST review API (see the cookbook).
- Keep findings actionable and specific; avoid style nits unless they affect correctness or clarity.
- If the diff is empty or the PR is closed/merged, report that and do not post.
