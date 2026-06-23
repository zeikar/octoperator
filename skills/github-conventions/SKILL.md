---
name: github-conventions
description: This skill provides the source-of-truth GitHub conventions, the gh CLI cookbook, and the settings schema that every Octoperator action consults. It should be loaded whenever Octoperator turns a request into GitHub artifacts — when the user asks to "plan an epic", "create an issue", "start work on an issue", "open a PR", "review a PR", or "sync project status", or otherwise works with GitHub epics, issues, sub-issues, milestones, branches, pull requests, reviews, or Projects v2 board updates. It is the shared knowledge layer, not a substitute for the action skills that perform the writes.
version: 0.1.0
---

# GitHub Conventions (Octoperator)

Octoperator makes GitHub the source of truth for AI-assisted engineering work. It converts
natural-language requests into durable, traceable GitHub artifacts. This skill defines the shared
conventions, command recipes, and configuration that every Octoperator action skill depends on.
Load and follow it before creating or modifying any GitHub artifact.

## The traceability chain

Every unit of work flows through the same chain, and each artifact references the previous one:

```
request → epic (issue) → child issues (sub-issues) → branch → pull request → review → project status
```

- An **epic** is a GitHub issue labeled `epic`; child issues are linked as native **sub-issues**.
- A **branch** encodes its issue number, so the issue is recoverable from the branch.
- A **pull request** body contains `Closes #<issue>` so merging auto-closes the issue.
- A **review** is posted to the PR (not kept in chat), preserving the artifact history.
- A **project item** mirrors the work's status on the Projects v2 board.

## Operating posture: autonomous

Octoperator executes immediately — it does not ask for confirmation before creating or modifying
GitHub artifacts. To preview without writing, the user passes `--dry-run` (or says "dry run"); in
that mode, print the exact `gh` commands and artifact contents that *would* run, and stop.

After any write, always echo what changed (issue/PR numbers and URLs) so the trail stays traceable.
Surface errors plainly — never silently swallow a failed `gh` call.

## Prerequisites (check once, fail fast)

Octoperator drives the `gh` CLI. Before the first write in a session, verify:

- `gh auth status` succeeds (the user is authenticated).
- Projects v2 board operations are **optional**. They need a **classic PAT** with the `project` scope
  (user-owned Projects v2 are not supported by fine-grained PATs; org-owned projects work via a
  fine-grained token's Projects permission). When a `gh project ...` call fails with a permission
  error, **skip the board step and continue** — report it and suggest `/octoperator:setup`.

Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-doctor.sh --repo <owner>/<name> --project <number>` to
verify auth, repo access, project access, and to print the board's Status options.

## Settings

Per-project configuration lives in `.claude/octoperator.local.md` (git-ignored), parsed as YAML
frontmatter. Read it at the start of every action to resolve the target repo, project, labels,
milestone, branch pattern, and reviewers. If it is missing, fall back to the current repo
(`gh repo view --json nameWithOwner`) and tell the user how to create it.

The full schema, an example file, and bootstrap steps are in **`references/settings.md`**.

## Conventions summary

- **Type labels** (one per issue): `epic`, `feature`, `bug`, `chore`, `docs`.
- **Priority labels**: `p0` (critical), `p1` (high), `p2` (normal, default), `p3` (low).
- **Branch naming**: `<issue-number>-<kebab-slug>` from the repo default branch (e.g. `42-add-oauth-login`).
- **PR linking**: PR body includes `Closes #<issue>`; one PR closes its primary issue.
- **Projects v2 status flow**: `Todo → In Progress → In Review → Done` (plus `Blocked` when stuck).
- **Epics**: an `epic`-labeled issue whose children are attached as native sub-issues; if the
  sub-issue API is unavailable, fall back to a `- [ ] #<n>` task list in the epic body.

The complete taxonomy, naming rules, epic model, and the full traceability matrix are in
**`references/conventions.md`**. Do not duplicate that content elsewhere — read it when details are needed.

## Command recipes

All concrete `gh` commands for each operation (create issue, link sub-issue, create branch, open PR,
post review, add to project, set status, query board) live in **`references/gh-cli-cookbook.md`**.
Consult it rather than improvising `gh` syntax. The error-prone GraphQL/Projects-v2 operations are
wrapped in helper scripts under `${CLAUDE_PLUGIN_ROOT}/scripts/` — prefer those:

- **`octo-doctor.sh`** — verify auth/repo/project access; print board Status options.
- **`octo-subissue.sh`** — link a child issue to its parent epic as a native sub-issue (exits non-zero
  on failure so the caller can fall back to a task-list entry).
- **`octo-project-status.sh`** — add an issue/PR to the project if absent and set its Status field by
  human-readable name (resolves the field/option IDs automatically).

## Additional resources

- **`references/conventions.md`** — full label taxonomy, branch/PR/epic rules, traceability matrix.
- **`references/gh-cli-cookbook.md`** — exact `gh` commands for every Octoperator operation.
- **`references/settings.md`** — settings schema, example `.claude/octoperator.local.md`, bootstrap.
