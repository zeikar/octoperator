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

## Running the benchmark

`scripts/octo-bench.sh` runs `/octoperator:auto` on the [benchmark tasks](bench/README.md), each in
a throwaway private repo, and lets the task's hidden `check.sh` judge the merged result rather
than Octoperator's own reviewer. Every result is one JSON line in `bench/results/<run-id>.jsonl`
(git-ignored).

> **Cost warning.** Every task is a full `auto` cycle (implement, up to 6 review and fix rounds,
> merge) on real repos, spending real API money and time. A full run is 10+ cycles. Cap it with
> `--max-cost-usd`, and check the plan with `--dry-run` first. With the cap set, `run` also stops
> after a solve that reports no cost (a timeout, say), since that spend is unknown. **Never run
> it in CI.** CI runs only the offline parts (`smoke.sh`'s stub tests and `bench/validate.sh`).
> Every network step exits 2 unless you pass `--live`.

Run it in a **Claude Code remote (cloud) session on Linux**, not on your machine. Prerequisites:

- `gh` signed in with a classic token that has the `repo` scope, plus `delete_repo` so `cleanup`
  can delete the repos (without it, `cleanup` lists them): `gh auth refresh -s repo,delete_repo`.
  The preflight fails without `repo` and only warns without `delete_repo`.
- `git` and `python3`, plus this checkout with the plugin loaded. `solve` passes
  `--plugin-dir <this checkout>` to the nested `claude` (override with `--plugin-dir`). For the
  agent-driven mode, start the session with the plugin loaded (`claude --plugin-dir <checkout>`).

There are two solve modes, because a nested `claude -p` may not work in every remote session:

1. **Nested `claude -p`** (what `run` does). `solve` clones the repo and runs
   `claude -p "/octoperator:auto <n>" --output-format json` in the clone, killed after
   `BENCH_SOLVE_TIMEOUT` seconds (default 3600). Its JSON gives the cost, turns, and model.
   ```bash
   bash scripts/octo-bench.sh run --tasks all --run-id r1 --max-cost-usd 20 --dry-run
   bash scripts/octo-bench.sh run --tasks all --run-id r1 --max-cost-usd 20 --live
   ```
   `run` stops starting new tasks once the total cost passes the cap.
2. **Agent-driven.** Skip `solve`, and let the session's own agent run `auto`:
   ```bash
   bash scripts/octo-bench.sh setup vsort-numeric --run-id r1 --live  # prints "<owner/repo> <n>"
   gh repo clone <owner/repo> bench/results/clones/<repo-name>  # git-ignored, in the workspace
   cd bench/results/clones/<repo-name>
   gh repo view --json nameWithOwner  # must print the bench repo, not octoperator
   # Then, in the session: /octoperator:auto <n>
   bash scripts/octo-bench.sh check vsort-numeric <owner/repo> --live  # from the checkout root
   ```
   The clone stays inside the checkout because the session's working directory resets when it
   leaves the workspace, and `auto` finds its repo from the working directory. `cost_usd`,
   `turns`, `duration_s`, and `model` are then null.

Each line records `task`, `repo`, `pr`, `merged`, `check_passed`, `success` (merged and passed),
`fix_rounds` (Octoperator's reviews minus one), `minor_only_rounds` (reviews with a `### Minor`
section but no `### Blockers` or `### Major`), `held_reason` (null once merged), `cost_usd`,
`turns`, `duration_s`, `octoperator_sha`, and `model`. When you are done, delete the repos with
`bash scripts/octo-bench.sh cleanup --run-id r1 --live`, or skip it to keep them for inspection.

## Pull requests

- Branch from the default branch using `<issue-number>-<slug>`.
- Reference the issue in the PR body with `Closes #<issue>`.
- Keep changes surgical and scoped to the issue.
