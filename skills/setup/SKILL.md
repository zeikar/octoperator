---
name: setup
description: This skill should be used when the user asks to "set up octoperator", "configure octoperator", "octoperator setup", "bootstrap octoperator settings", "initialize the project board", "create the octoperator config", or invokes /octoperator:setup. Detects the repo, probes whether the token can access Projects v2, optionally selects or creates a board, and writes .claude/octoperator.local.md. Projects is treated as optional and auto-detected.
argument-hint: "[--repo OWNER/NAME]"
allowed-tools: Bash(gh:*), Bash(bash:*), Read, Write
version: 0.1.0
---

# Setup

One-time onboarding for Octoperator: detect the environment, decide whether the optional Projects v2
board can be enabled, and write `.claude/octoperator.local.md`. Projects is an **optional
enhancement** — Octoperator works fully (issues, branches, PRs, reviews, traceability) without a board.
Follow the `github-conventions` skill for the settings schema
(`${CLAUDE_PLUGIN_ROOT}/skills/github-conventions/references/settings.md`).

## Steps

1. **Probe the environment (read-only).** Run
   `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-setup.sh [--repo OWNER/NAME]` and parse the JSON:
   `repo`, `default_branch`, `project_owner`, `projects_capable`, `boards[]`, `note`. If it returns an
   `error` (no gh / not authenticated / no repo), report it and stop with the fix.

2. **Check for existing settings.** If `.claude/octoperator.local.md` already exists, read it and
   preserve the user's values; confirm before overwriting. Otherwise create it fresh.

3. **Resolve the board (optional).** Note: `projects_capable` reflects **read** access only — a token
   can list projects but still lack write (board creation / item edits). Write is proven only by trying.
   - **`projects_capable: true`** — present `boards[]` and ask which to use, or offer to create one:
     - create with `gh project create --owner <project_owner> --title "<repo-name>" --format json` and
       capture its `number`/`url`. **If create fails with a permission error, do not crash** — fall back
       to the board-less path below and surface the classic-PAT guidance.
     - confirm the chosen/created board with
       `bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-doctor.sh --repo <repo> --project <number>` and read the
       printed Status options; set the `statuses` mapping to the board's real option names.
   - **`projects_capable: false` (or write failed above)** — skip the board. Record no `project_*` keys,
     and tell the user board features are off and how to enable them: user-owned Projects v2 require a
     **classic PAT** with the `repo` + `project` scopes (fine-grained PATs do not support user-owned
     projects); org-owned projects work with a fine-grained token's Organization → Projects permission.

4. **Write settings.** Write `.claude/octoperator.local.md` (Write tool) using the schema from
   `references/settings.md`: always include `repo`, `branch_pattern`, `statuses`, and `labels`; include
   `project_owner`/`project_number`/`project_url` only when a board was resolved. Keep it minimal and
   commented.

5. **Offer label bootstrap.** Ask whether to ensure the Octoperator labels now; if yes, run the
   "ensure labels" recipe from the cookbook (idempotent `gh label create --force`).

6. **Report.** Print the resolved repo, whether board mode is ON (with the board URL) or OFF (with the
   one-line enable hint), and the path of the settings file written.

## Notes

- This skill writes one local file and (only on request) creates a board / ensures labels — it makes no
  other changes. The settings file is git-ignored (`.claude/*.local.md`).
- Never probe Projects **write** access by attempting to create a throwaway board; rely on the
  read probe in `octo-setup.sh` and create a board only when the user opts in.
- Re-running setup is safe: it updates the existing settings file in place after confirmation.
