---
name: issue
description: This skill should be used when the user asks to "create an issue", "open an issue for X", "file a bug", "log a task", "make a ticket", or invokes /octoperator:issue. Turns one natural-language request into a single well-formed GitHub issue with type/priority labels, acceptance criteria, milestone, and a project board item.
argument-hint: <request describing one issue> [--dry-run]
allowed-tools: Bash(gh:*), Bash(bash:*), Read
---

# Create Issue

Create one well-formed, traceable GitHub issue from a request. For a large multi-part request, use
`/octoperator:plan-epic` instead. Follow the shared conventions in the `github-conventions` skill
(`references/conventions.md`, `references/gh-cli-cookbook.md`). Octoperator is autonomous: create
immediately unless `--dry-run` is passed, then echo the issue URL.

## Steps

1. **Load settings.** Read `.claude/octoperator.local.md` for `repo`, `project_owner`,
   `project_number`, `milestone`, and `statuses.todo` (default `Todo`). Fall back to the current repo if the file is
   absent (and skip the board step). When a milestone is set (or the request names one), resolve
   its number once, as the REST API takes (cookbook → Resolve a milestone's number); no number
   printed → stop and report the milestone as not found.

2. **Draft the issue.** From the request, write:
   - a clear, imperative **title**;
   - a **body** with `## Context` (why) and `## Acceptance criteria` (a checklist of verifiable outcomes);
   - exactly one **type label** (`feature`/`bug`/`chore`/`docs`) and one **priority** (default `p2`),
     inferred from the request.

3. **Dry-run gate.** If `--dry-run` is present, print the drafted issue and the `gh api` create
   command that would run, then stop.

4. **Ensure labels.** Create any missing label used, leaving existing ones alone:
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-labels.sh --repo <repo> <type> <priority>`.

5. **Create the issue.** One REST call (cookbook → Create an issue; the title single-quoted and
   the body on stdin, by its REST rules), which prints `<number> <url>`:
   ```bash
   gh api repos/<repo>/issues -f title='<title>' \
     -f 'labels[]=<type>' -f 'labels[]=<priority>' [-F milestone=<number>] -F body=@- \
     --jq '"\(.number) \(.html_url)"' <<'OCTO_BODY_EOF'
   <body, verbatim>
   OCTO_BODY_EOF
   ```

6. **Add to the board.** If a project is configured, run
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <project_owner> --project <number> --url <url> --status "<statuses.todo>"`.
   A board failure, exit 3 included (`skipped: projects unavailable here`, where GraphQL is
   refused, as in a Claude Code cloud session), skips this step with one warning; the issue stands.

7. **Report.** Print the created issue number and URL.

## Notes

- Infer the type from intent: a defect → `bug`, new capability → `feature`, maintenance/refactor →
  `chore`, docs-only → `docs`.
- If the request clearly contains several independent deliverables, say so and recommend `plan-epic`.
- On `gh` failure, stop and report the error rather than retrying blindly.
