---
name: plan-epic
description: This skill should be used when the user asks to "plan an epic", "break this down into issues", "decompose this into issues", "create an epic for X", "turn this request into a backlog", or invokes /octoperator:plan-epic. Decomposes a large natural-language request into a GitHub epic issue plus linked child issues, milestone, labels, and project board items.
argument-hint: <request describing the body of work> [--dry-run]
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash:*), Read, Task
version: 0.1.0
---

# Plan Epic

Turn a large request into a structured, traceable GitHub epic: one `epic`-labeled issue with child
issues attached as native sub-issues, all on the project board. Follow the shared conventions in the
`github-conventions` skill — read `${CLAUDE_PLUGIN_ROOT}/skills/github-conventions/references/conventions.md`
and `${CLAUDE_PLUGIN_ROOT}/skills/github-conventions/references/gh-cli-cookbook.md` for the rules and
exact commands. Octoperator is autonomous: execute the creation immediately unless
`--dry-run` is passed, then echo every artifact with its URL.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, `milestone`, `reviewers`, and label/status overrides. If absent, resolve the repo
   from `gh repo view --json nameWithOwner` and warn that no project board is configured (skip board
   steps in that case). See `github-conventions/references/settings.md`.

2. **Decompose.** Dispatch the `issue-planner` agent (Task tool) with the request and the repo context.
   It returns a structured plan: the epic (title, summary, the original request verbatim) and a list of
   child issues, each with title, body, type label, priority, acceptance criteria, and dependencies.
   Review the plan for obvious gaps before acting.

3. **Dry-run gate.** If the argument contains `--dry-run` (or the user said "dry run"), print the
   proposed epic and child issues and the `gh` commands that would create them, then stop. Do not write.

4. **Ensure labels.** Run the "ensure labels" recipe from the cookbook so every type/priority label
   used by the plan exists (idempotent `gh label create --force`).

5. **Create the epic issue.** `gh issue create` with the `epic` label + priority, the configured
   milestone, and a body containing: the original request, a short summary, acceptance criteria, and a
   `## Children` section (placeholder for the task-list fallback). Capture its number/URL.

6. **Create each child issue.** For each child: `gh issue create` with its type+priority labels and the
   milestone; the body opens with `Part of #<epic>` then context + acceptance criteria. Capture each
   number/URL.

7. **Link children to the epic.** For each child run
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-subissue.sh --repo <repo> --parent <epic#> --child <child#>`.
   If it exits non-zero, fall back: append `- [ ] #<child#>` to the epic body's `## Children` checklist
   via `gh issue edit`.

8. **Add to the board.** If a project is configured, add the epic and every child with
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <url> --status "Todo"`.

9. **Report.** Print the epic and the child tree with all URLs, note any sub-issue fallbacks used, and
   surface any link that could not be established.

## Notes

- Keep child issues small and independently shippable; prefer 3–8 children. If the request is actually
  a single unit of work, suggest `/octoperator:issue` instead.
- Never invent a milestone — use the configured one or one the request names explicitly.
- On any `gh` failure, stop and report which step failed and what was already created (for traceability).
