# Contributing to Octoperator

Thanks for helping improve Octoperator. This guide covers local setup, configuration, conventions,
and how to check your changes.

## Local install

Octoperator is a Claude Code plugin. To run it from a clone:

```bash
claude --plugin-dir /path/to/octoperator
```

The skills then appear as `/octoperator:*` commands (e.g. `/octoperator:plan-epic`) and activate on
matching natural-language requests.

Working on Octoperator itself? Just open Claude Code in the clone: the committed
`.claude/settings.json` registers the checkout as the `zeikar-plugins` directory marketplace and
enables `octoperator@zeikar-plugins`, so you dogfood whatever branch is checked out (accept the
trust prompt on first launch).

## Prerequisites

- [GitHub CLI](https://cli.github.com) (`gh`) installed and authenticated: `gh auth login`.
- For Projects v2 board updates, a token with Projects access. Note that **fine-grained PATs do not
  support user-owned Projects v2** — use a classic PAT with the `repo` and `project` scopes, or an
  organization-owned project.

## Settings bootstrap

Per-project configuration lives in `.claude/octoperator.local.md` (git-ignored). Create it from the
template:

```bash
mkdir -p .claude
cp octoperator.local.md.example .claude/octoperator.local.md
```

Only `repo` (or a discoverable current repo) is required; board operations additionally need
`project_owner` + `project_number`. See
[skills/github-conventions/references/settings.md](skills/github-conventions/references/settings.md)
for the full schema.

## Conventions

Octoperator follows a documented set of conventions (labels, branch naming, PR linking, the
epic/sub-issue model, and the status flow). Read and follow them when adding or changing behavior:
[skills/github-conventions/references/conventions.md](skills/github-conventions/references/conventions.md).

## Checking your changes

Octoperator has no build step. Before opening a PR:

```bash
# 1. Smoke-test the helper scripts (syntax, --help, arg handling, and real octo-exclude /
#    octo-worktree runs in a temp repo). CI-safe: no network / gh / auth required. CI runs this
#    on ubuntu and macOS on every push and PR.
bash scripts/test/smoke.sh

# 2. Validate the benchmark tasks (offline; CI runs these too). See bench/README.md.
bash bench/validate.sh && bash bench/test/selftest.sh

# 3. Verify prerequisites and (optionally) board access
bash scripts/octo-doctor.sh --repo <owner>/<name> [--project <number>]

# 4. Confirm the plugin manifest is valid JSON
python3 -c "import json; json.load(open('.claude-plugin/plugin.json')); print('plugin.json OK')"
```

When editing skills or agents, keep `SKILL.md` bodies lean and push detail into `references/`
(progressive disclosure), and keep descriptions in third person with concrete trigger phrases.

## Pull requests

- Branch from the default branch using `<issue-number>-<slug>`.
- Reference the issue in the PR body with `Closes #<issue>`.
- Keep changes surgical and scoped to the issue.
