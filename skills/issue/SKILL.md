---
name: issue
description: This skill should be used when the user asks to "create an issue", "open an issue for X", "file a bug", "log a task", "make a ticket", or invokes /octoperator:issue. Turns one natural-language request into a single well-formed GitHub issue with type/priority labels, acceptance criteria, milestone, and a project board item.
argument-hint: <request describing one issue> [--dry-run]
allowed-tools: Bash(gh:*), Bash(bash:*), Read
version: 0.1.0
---

# Create Issue

Create one well-formed, traceable GitHub issue from a request. For a large multi-part request, use
`/octoperator:plan-epic` instead. Follow the shared conventions in the `github-conventions` skill
(`references/conventions.md`, `references/gh-cli-cookbook.md`). Octoperator is autonomous: create
immediately unless `--dry-run` is passed, then echo the issue URL.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, `milestone`, and label defaults. Fall back to the current repo if the file is
   absent (and skip the board step).

2. **Draft the issue.** From the request, write:
   - a clear, imperative **title**;
   - a **body** with `## Context` (why) and `## Acceptance criteria` (a checklist of verifiable outcomes);
   - exactly one **type label** (`feature`/`bug`/`chore`/`docs`) and one **priority** (default `p2`),
     inferred from the request.

3. **Dry-run gate.** If `--dry-run` is present, print the drafted issue and the `gh issue create`
   command that would run, then stop.

4. **Ensure labels.** Create any missing labels used (idempotent `gh label create --force` — see the
   cookbook).

5. **Create the issue.** Run `gh issue create` with the title, body, labels, and configured milestone.
   Capture the number/URL.

6. **Add to the board.** If a project is configured, run
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <url> --status "Todo"`.

7. **Report.** Print the created issue number and URL.

## Notes

- Infer the type from intent: a defect → `bug`, new capability → `feature`, maintenance/refactor →
  `chore`, docs-only → `docs`.
- If the request clearly contains several independent deliverables, say so and recommend `plan-epic`.
- On `gh` failure, stop and report the error rather than retrying blindly.
