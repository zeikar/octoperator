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

## Helper scripts (`scripts/`)

The skills call these through `${CLAUDE_PLUGIN_ROOT}/scripts/...`; each one is a plain bash script
you can also run by hand from a clone.

- **`octo-setup.sh`** — read-only probe used by `/octoperator:setup`: detect repo + default branch (REST) and whether the token can access Projects v2 (lists existing boards; `gh project`, which has no REST API).
- **`octo-worktree.sh`** — manage Git worktrees (`add`, `attach`, `detach`, `remove`, `list`); used by `implement` for per-issue worktrees (`attach` resumes on a branch already on the remote, reusing a local branch only when it matches or is ahead) and by `review` / `auto` for throwaway detached checkouts of a PR head.
- **`octo-exclude.sh`** — idempotently add the settings file and `.octoperator/` (worktrees) to the repo-local `.git/info/exclude` so they never dirty `git status`; used by `setup` and `implement`.
- **`octo-doctor.sh`** — verify auth/repo/project access and print the board's Status options; the repo checks are REST, the board's `gh project`.
- **`octo-subissue.sh`** — link a child issue to its epic as a native sub-issue, over REST by the child's numeric id (exits 1 on failure, so the caller falls back to a task list).
- **`octo-labels.sh`** — make sure labels exist: create each missing one, with Octoperator's colour and description for its own labels, and leave existing ones alone; REST only (`created`, `exists`, or `failed` per label); used by `issue`, `plan-epic`, `setup`, `autopilot`, and the flaky-test procedure.
- **`octo-issue-find.sh`** — find the open issues whose title or body contains a text, matched as a plain string ignoring case, over REST (the REST stand-in for `--search`); used by the flaky-test procedure to find an issue for a test.
- **`octo-ledger-read.sh`** — print the newest entry-shaped comments on autopilot's run ledger from allowed authors, and a count of the skipped ones, as JSON; read-only, REST only; the ledger read command for a human or `research`.
- **`octo-pr-closes.sh`** — list pull requests (one, or every one in a state, or the most recently updated) with the issues each one's body closes, the REST stand-in for `closingIssuesReferences`: GitHub's closing keywords in any case (`#N`, `GH-N`, `OWNER/NAME#N`, or an issue URL), negated ones too, skipping fenced code, inline code, and HTML comments, and only on a PR into the default branch; read-only, REST only; used by `implement`, `auto --pr`, `autopilot`, and `sync`.
- **`octo-project-status.sh`** — add an issue/PR to the board and set its Status by name.
- **`octo-merge-state.sh`** — print a PR's merge state, REST's `mergeable_state` uppercased (`CLEAN`, `DIRTY`, `BLOCKED`, `BEHIND`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, …), re-reading while GitHub hasn't computed it (null or `unknown`); REST only; used by `auto`'s merge gate, where only `CLEAN` merges.
- **`octo-ci-wait.sh`** — wait, bounded (9 minutes by default), for a commit's check runs (the newest of each name within its check suite, so same-named runs in a workflow's `push` and `pull_request` suites both count), check suites with runs, and commit statuses to finish, and print `green`, `none` (nothing found on two reads), `failed <names>` (as soon as one fails), or `pending <names>`, bucketing each check run and status by its conclusion or state as `gh pr checks` does; read-only, REST only; used by `auto`'s merge gate on the reviewed commit.
- **`octo-merge.sh`** — merge a PR with a regular merge commit (`merge_method=merge`), pinned to the reviewed head (`sha`, so a moved head gets GitHub's 409), confirm it from the merge call's or the read-back PR's `merged`, then delete the head branch best effort (never a fork's or the default branch; a refused delete only warns); REST only; used by `auto`'s merge gate.
- **`octo-after-merge.sh`** — after a merge, close the issue the PR closes (`--issue N`) if GitHub left it open, with a comment naming the PR, then each epic of that issue (native parent or `## Children` list) once every child is closed; never one with an open child or no children. REST only; prints what it closed, `warn: …`, or `nothing to close`, and always exits 0; used by `auto` after each merge.
- **`octo-evals-guard.sh`** — in a repo with genesis's evals guard, check that both guard jobs of the PR's own guard run passed on its reviewed commit, against the base branch's current tip when the PR changes `evals/` (`pass`, `none`, or why to hold: a `[skip ci]` head has no checks); read-only, REST only; used by `auto`'s merge gate.
- **`octo-evals-metric.sh`** — in a repo with genesis's `evals.yml`, read the pass rate from the `evals-metric` notice of its latest completed default-branch push or dispatch run in this repo, as the ledger's `metric` (`{"passed":P,"total":T}` and `rate: P/T`, or `null` with the reason: no evals workflow, no completed run, a missing, malformed, or ambiguous annotation, or one the run's conclusion disagrees with), and the run's head commit; read-only, REST only; used by `autopilot` and `genesis --next`.
- **`octo-milestone-gate.sh`** — decide whether to plan the next milestone now. It says `build` when autopilot's discovery found buildable work, `open <pr>` while a next-milestone PR (an open `milestone-*` branch from this repo) is open, and `not all-pass`. It says `failed` when the last run's planning failed at the default branch's tip, and `declined <pr>` when the newest milestone PR was closed unmerged and nothing has landed since it was planned, or since it was closed. It says `stale dispatch` or `stale wait <run>` when the metric's run judged an older commit than the tip (whether an `evals.yml` run for the tip is queued or running), else `plan`. Read-only, REST only; used by `autopilot` and `genesis --next`.
- **`octo-genesis-next.sh`** — `genesis --next`'s offline half: number the next milestone from the default branch's `docs/prd.md` (`--rev`), and check the committed milestone before it is pushed, and in `auto`'s merge gate on the reviewed commit (`--check`, `--head <sha>` in a detached checkout). Only `docs/prd.md` (appended), `VISION.md` (its Roadmap), `docs/research.md` (file modes unchanged), and new `evals/<id>/` directories of regular files (no symlink, submodule, or `.gitattributes`) change. Each new eval has its scenario, no CI skip token appears in the title or the commit message, and an ungrounded milestone cites no URL. Offline.
- **`octo-web-allowed.sh`** — whether your own Claude Code settings (the repo's `.claude/settings.json` and `.claude/settings.local.json`, and `~/.claude/settings.json`) allow WebSearch and WebFetch: a bare `permissions.allow` entry for each, and no `deny` or `ask` rule naming either, bare or scoped; offline; used by `autopilot` before `genesis --next` may ground.
- **`octo-ledger-state.sh`** — apply autopilot's convergence rules to its run ledger and this run's metric, and print the walk, the no-gain streak, the high-water mark, whether every eval passes, and the decision (`build` or `observe`); read-only, REST only (the ledger's comments, every page); used by `autopilot`.
- **`octo-approval-match.sh`** — normalize the `approval_paths` patterns and match a PR's changed files (renamed files' old paths too) against them, ignoring case, cross-checking the listed files against the PR's `changed_files` so a cut-short list holds; REST only; used by `auto`'s approval-path gate.
- **`octo-vision-guard.sh`** — check that a PR changes the root `VISION.md` only in its Roadmap body, in plain text: everything outside that body keeps the merge base's bytes, no Roadmap line opens with `<`, `#`, `>`, or a fence, is only `=` or `-` marks, or holds HTML or a link definition, the merge base has one `## Roadmap` line and a body that passes the same rule (the body ends only at a column-0 heading), the file holds no NUL, bare CR, other control byte, or Unicode line break, and it isn't deleted, new, made a symlink, given another mode, or joined by a new or changed root twin such as `vision.md`; with `--milestone <n>`, also that the Roadmap names the milestone; `--plain-roadmap <file>` checks one file outside git by the head's byte rule and the merge base's Roadmap rules, for the genesis proposal check. Parses no Markdown and reads git's objects only, so the user's diff settings don't apply; offline; used by `auto`'s merge gate on every PR and by `octo-genesis-next.sh --check`.
- **`octo-genesis-check.sh`** — check that a directory is empty and outside git for `genesis` (`--preflight`), and that the proposal it wrote is complete: `GENESIS.md` front matter (including a `test_command` that `issue-implementer` detects), the `docs/research.md`, `docs/prd.md`, and `docs/adr/0001-stack.md` sections, and a `VISION.md` with the baseline immutable constraints verbatim and a Roadmap body that passes the vision guard's plain-text rule (no template `<placeholder>` left) and no NUL, bare CR, other control byte, or Unicode line break anywhere in it; with `--skeleton`, that the skeleton `--approve` wrote is detectable and wired up (the test command's detection file and no earlier one, CI on `push` and `pull_request`, the `.gitignore` entries, the sentence in the README), and that its scenario evals are in place (the eval runner and guard copied verbatim, the evals workflows on their triggers, one `evals/<id>/` per PRD scenario); offline.
- **`octo-genesis-plan.sh`** — work out where `genesis --approve` resumes from the folder's git state (`scaffold`, `commit`, `create`, `push`, or `setup`) and print its ordered commands, the `gh repo create` description made safe, through the MVP epic and the handoff; read-only and offline.
- **`octo-genesis-epic.sh`** — find the open `epic` issue whose body quotes `GENESIS.md`'s sentence, so a re-run of `genesis --approve` plans no second MVP epic; read-only, REST only (the open `epic` issues, every page).
- **`octo-bench.sh`** — opt-in benchmark harness for contributors: runs `auto` on the `bench/` tasks in throwaway repos and records each outcome and its metrics (see [Running the benchmark](#running-the-benchmark)); REST only, with git over https on gh's credentials for the clone and the seed push.

## Checking your changes

Octoperator has no build step. Before opening a PR:

```bash
# 1. Smoke-test the helper scripts (syntax, --help, arg handling, and real octo-exclude /
#    octo-worktree runs in a temp repo), and check that no script, skill, or agent outside
#    genesis uses GraphQL (`gh api graphql` or GraphQL-backed porcelain such as `gh pr` and
#    `gh repo`), outside a short allowlist. CI-safe: no network / gh / auth required. CI runs
#    this on ubuntu and macOS on every push and PR.
bash scripts/test/smoke.sh

# 1b. Test the scenario-eval templates genesis copies into a new repo (offline; CI runs this).
bash scripts/test/evals.sh

# 1c. Test autopilot's evals metric read, convergence decision, next-milestone gate, and web
#     settings check, against a stub gh that serves REST and refuses GraphQL and porcelain
#     (offline; CI runs this).
bash scripts/test/autopilot.sh

# 1d. Test genesis --next's milestone numbering and milestone diff check (offline; CI runs this).
bash scripts/test/genesis-next.sh

# 1e. Test auto's VISION.md check (offline; CI runs this).
bash scripts/test/vision.sh

# 1f. Test auto's after-merge closing of issues and epics, against a REST-only stub gh
#     (offline; CI runs this).
bash scripts/test/after-merge.sh

# 1g. Test the REST issue, label, sub-issue, and pull request helpers, and the cookbook's REST
#     recipes, against a REST-only stub gh (offline; CI runs this).
bash scripts/test/rest.sh

# 1h. Test auto's merge gate helpers (merge state, checks wait, merge and branch delete) against
#     a REST-only stub gh (offline; CI runs this).
bash scripts/test/merge-gate.sh

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
> it in CI.** CI runs only the offline parts (`smoke.sh`'s stub tests, `evals.sh`, `autopilot.sh`,
> `genesis-next.sh`, `vision.sh`, `after-merge.sh`, `rest.sh`, `merge-gate.sh`, and
> `bench/validate.sh`).
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
   # git-ignored, in the workspace; gh's credentials, as `octo-bench.sh` clones (no GraphQL):
   git -c credential.https://github.com.helper= \
     -c 'credential.https://github.com.helper=!gh auth git-credential' \
     clone https://github.com/<owner/repo>.git bench/results/clones/<repo-name>
   cd bench/results/clones/<repo-name>
   gh api 'repos/{owner}/{repo}' --jq .full_name  # must print the bench repo, not octoperator
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
