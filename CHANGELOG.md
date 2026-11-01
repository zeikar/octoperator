# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- README → "Running continuously": copy-paste recipes for re-running `autopilot` with Claude
  Code's own scheduling on your machine — an in-session cron task in a background session (the
  default), `/loop`, `/goal`, and `claude -p` under launchd or crontab with `--cycles 1`,
  `--max-budget-usd`, `--permission-mode acceptEdits`, and `--permission-prompts none`. For each
  mode it covers where it runs, what stops it, how cost is bounded, and the permissions it
  needs; "Unattended runs" now also allows `Edit` and `Write`, which subagents use to change
  files. `/schedule` cloud routines are not supported, because cloud
  sessions block GitHub's GraphQL API (#79). Every `autopilot` run now ends with one status line —
  `autopilot: merged N`, `converged → observe`, `nothing to do`, or `stopped: <reason>` — that a
  `/goal` condition can match. On `nothing to do` or `converged → observe`, a run started by a
  self-paced `/loop` stops it (`ScheduleWakeup` with `stop: true`), and a run whose prompt exactly
  matches one recurring in-session cron task deletes that task (`CronList`, then `CronDelete`); it
  never deletes another task, and reports what it stopped. The ledger's `cost_usd` stays `null`; a
  `claude -p --output-format json` run reports its cost as `total_cost_usd`. `VISION.md`'s roadmap
  item 4 now names this local design in place of a scheduled cloud runner.
- Approval gates for deploy, spend, and delete work. `research --create` labels such proposals
  `needs-approval` (creating that label and `approved` if missing). `autopilot` never builds a
  `needs-approval` issue, in either mode, until a human adds `approved` — Octoperator never adds
  it — and lists each skipped issue as `gated: needs-approval`, including under `--dry-run`, with
  the reason when an `approved` label does not count (added by a bot, or not after
  `needs-approval`). A new `approval_paths` setting (glob patterns, default empty) makes `auto`
  hold any PR whose changed files match, with the reason `needs human approval: <path>`; it is the
  backstop for risky work nobody labeled. A pattern with no `/` matches at any depth, and a pattern
  also covers everything under a directory it matches. The new `scripts/octo-approval-match.sh`
  helper does the normalization and matching. `VISION.md`'s approval constraint now names this
  enforcement.
- `autopilot` keeps a run ledger on GitHub: one open issue labeled `octoperator-ledger`, created on
  the first run, gets one comment per run with a fenced JSON entry (time, mode, cycles used, merged,
  held, proposals filed, metric, cost, kind). After `convergence_runs` entries in a row (a new
  setting, default 3) without a merge, autopilot switches to observe mode: `research` proposes
  without filing, nothing is built or merged, and an `observe` entry is recorded. The new
  `--resume` flag writes a `reset` entry and builds again. `--dry-run` shows the convergence state.
  Discovery skips the ledger issue, and `research` can cite a ledger entry as `failure-log`
  evidence but never counts the ledger as user feedback.
- `research` files only evidenced proposals ("no evidence, no issue"). Each proposal carries an
  Evidence field — `benchmark`, `eval` (a failing latest CI run on the default branch), `failure-log`
  (a held PR or ledger entry), or `user-feedback` — which `--create` re-checks right before filing
  and writes into the issue's `## Evidence` section. Code-only leads (TODOs, doc/code drift) are
  still reported, as "Unevidenced (not filed)".
- `VISION.md`, a product constitution: goal, target users, quality bar, immutable constraints, and
  an evidence-revised roadmap. `research` reads a target repo's `VISION.md` when present — dropping
  (and listing) proposals that break an immutable constraint or fall outside the goal, and ranking the
  rest by roadmap fit — and `autopilot` never builds a change to its immutable constraints.
- `scripts/octo-bench.sh`, an opt-in benchmark harness. `setup` creates a throwaway private repo
  from a task's seed and files its issue, `solve` runs `claude -p "/octoperator:auto <n>"` in a
  clone (time-bounded; optional, since the session's own agent can run `auto` instead), `check`
  runs the hidden `check.sh` on the merged default branch and appends one JSON line of metrics
  (merged, check passed, fix rounds, minor-only rounds, hold reason, cost, turns, duration,
  Octoperator SHA, model) to `bench/results/<run-id>.jsonl`, `cleanup` deletes the run's repos, and
  `run` loops over tasks under a `--max-cost-usd` cap. Every network step needs `--live`;
  `--dry-run` prints the plan. `smoke.sh` tests the gate, the dry run, preflight, `check`'s
  metrics, and the cost cap offline against stub `gh` and `claude`. CONTRIBUTING.md → "Running the
  benchmark" covers remote-session use.
- Benchmark task format and three starter tasks (feature, bug fix, docs) under `bench/tasks/`, each
  with an issue to file (`task.md`), a seed repo, a hidden `check.sh` oracle, and a reference
  `solution.patch`; the format is documented in `bench/README.md`. `bench/validate.sh` checks every
  task offline (the check must fail on the seed and pass with the patch), `bench/test/selftest.sh`
  proves it catches broken tasks, and CI runs both on ubuntu and macOS and shellchecks
  `bench/**/*.sh`.
- Seven more benchmark tasks, 10 in all: `todo-priority` (feature), `linecount-last-line`,
  `snap-spaces`, `semver-caret-zero` (bug fixes), `csvcut-docs` (docs), `mdtable-rename-flag`, and
  `envparse-extract` (chores, the second a refactor). Three target failure modes from
  Octoperator's own PRs: docs that claim more than the code does, a change that invites only
  wording nits, and an obvious fix that breaks an existing test. `selftest.sh` now also checks
  that each new oracle rejects plausible wrong fixes and accepts other correct ones.
- README workflow diagram (light/dark PNGs via `<picture>`), rendered from `docs/workflow.html`.
- `octo-merge-state.sh` helper: prints a PR's `mergeStateStatus`, re-querying while GitHub reports
  `UNKNOWN` (up to 3 tries, 10 s apart). `auto`'s merge gate uses it.
- `octo-worktree.sh detach --name <prefix> --ref <commit>`: creates a throwaway detached worktree at a
  unique `.octoperator/worktrees/<prefix>-<pid>` path and prints only that path. `review` and `auto`'s
  fix loop use it.

### Fixed
- Lifecycle steps no longer stop unattended runs on permission prompts: every command `implement`,
  `auto`, `review`, `autopilot`, and `research` tell the agent to run is one plain `gh` / `git` /
  `bash` call. Shell `if [ … ]` board guards, `VAR=… gh` prefixes, `|| true`, and `echo`/`sleep`
  chains became agent decisions or helper scripts, and `auto`'s `UNKNOWN` re-query has its pause back.
  `implement` states this as a command rule, which also fixes values that were kept in shell
  variables although Bash calls don't share shell state. The README's "Unattended runs" section now
  documents what still needs a settings-file allow rule (the test command, and subagents).

## [0.2.0] - 2026-10-30

### Added
- `implement` skill (`/octoperator:implement`): take one or more issues from issue to PR — a single
  issue inline in the current tree, or many in parallel git worktrees (capped by `--max`, default 3).
- `issue-implementer` agent: write-capable subagent that implements one issue inside a pre-created
  worktree and opens its own `Closes #N` PR (never writes the board).
- `octo-worktree.sh` helper: explicit per-issue worktree lifecycle (`add` / `remove` / `list`).
- `auto` skill (`/octoperator:auto`): full lifecycle end-to-end — implement → review → merge — for one
  or more issues. Any blocker/major/minor review finding starts a fix → re-review loop — up to 6
  rounds, fixes applied by `issue-implementer` in fix mode on the PR branch. A blocking review
  (`request_changes`, the intended verdict before the self-approval COMMENT downgrade) blocks the
  merge, and a PR still blocking after the last round is held with its outstanding findings; minors
  are fixed before merging; leftover minors (fixer `no-changes` or the round cap) never hold a PR and
  are reported, but a failed fix attempt still does. Nits are not fixed. Merges use a regular merge
  commit (history preserved), are pinned to the reviewed commit (`--match-head-commit`), and are
  gated on the PR being mergeable with passing required checks.
- `research` skill (`/octoperator:research`): analyze the repo and produce a ranked list of proposed
  work balanced across categories — new features, refactoring, tech debt, test coverage, docs, and DX
  (not just features) — with a `--focus` flag to bias a run; with `--create`, file the top ones as
  `proposed` issues for triage.
- `autopilot` skill (`/octoperator:autopilot`): bounded orchestration loop over `auto` + `research`.
  `semi` mode (default) builds only `ready`-labeled issues then proposes more for human triage; `full`
  mode runs unattended to the `--cycles` cap. Adds the `ready` / `proposed` issue labels.
- `scripts/test/smoke.sh`: CI-safe smoke test for the `octo-*.sh` helpers (syntax check, `--help`
  exits 0, unknown-arg exits 2 — no network/auth), plus a `CI` GitHub Actions workflow that runs it
  on every push and pull request.
- `shellcheck` static analysis in CI over the helper scripts (`scripts/*.sh`, `scripts/test/smoke.sh`),
  catching quoting/word-splitting/unset-variable bugs that `bash -n` cannot.
- Smoke coverage for `octo-worktree.sh` `add` / `list` / `remove`, run for real in a throwaway temp
  repo (offline), plus checks that every helper's `--help` prints only its usage block and that a
  value flag given without a value exits 2. CI now runs the smoke tests on macOS as well as ubuntu.
- Project `.claude/settings.json` that loads the checked-out plugin (`octoperator@zeikar-plugins`
  from a `directory` marketplace) when Claude Code opens in the repo, for dogfooding.

### Changed
- Plugin version bumped to 0.2.0 in `plugin.json` and `marketplace.json`. The non-standard per-skill
  `version:` frontmatter is dropped, leaving `plugin.json` as the single source of the version.
- README: the skills table is now grouped by purpose (onboarding, plan & intake, autonomous lifecycle,
  review & status, what's next, knowledge layer) so the entry points are easier to scan.

### Removed
- `start` and `pr` skills (`/octoperator:start`, `/octoperator:pr`): redundant manual single-step
  primitives. `implement` / `auto` cover branch → code → PR end-to-end and set both `In Progress` and
  `In Review` board transitions; branch-naming and PR-linking conventions live in `github-conventions`,
  so nothing was orphaned. Consolidates Octoperator on its autonomous-first lifecycle.
- `labels` setting (`types`, `priorities`, `default_priority`): `setup` wrote it but nothing read it.
  The label taxonomy is fixed by `github-conventions`; the key is gone from the schema, `setup`, and
  the example file.

### Fixed
- Single-issue `implement` / `auto` no longer refuse every run after `setup`: the settings file and
  `.octoperator/worktrees/` were untracked in the target repo (only Octoperator's own `.gitignore`
  covered them) and tripped the clean-tree guard. New `octo-exclude.sh` adds both to the repo-local
  `.git/info/exclude`; `setup` and `implement` run it.
- `octo-setup.sh` looped forever when `--repo` / `--owner` was passed without a value; it now exits 2
  with a JSON error.
- `auto` now waits (bounded) for running CI checks before reading the merge gate, instead of holding
  nearly every PR as `UNSTABLE`/`BLOCKED` because review finished before CI did.
- `review` (and `auto`'s review phase) now has `pr-reviewer` read and test the PR's head commit in a
  throwaway detached worktree, removed afterward, instead of whatever the current checkout held —
  often the default branch, since parallel `implement` removes its worktrees before review.
- `auto` now runs `implement`'s steps 1–2 in full, so `branch_pattern` is honored and the
  settings-repo vs local-clone mismatch guard applies under `auto` too. After a `gh pr merge` error it
  re-reads the PR and treats `MERGED` as success (reporting the cleanup error separately) instead of
  reporting a failure and skipping the `Done` board write.
- `autopilot` discovery now skips issues an open PR already holds — it closes them, or its head
  branch is theirs, matching `implement`'s rejection rules — and lists them in the cycle report,
  instead of re-picking held `ready` issues every run only for `implement` to reject them while they
  used up `--max` slots. The repo match is case-insensitive, and only issues that pass the
  label/mode filters are listed.
- The `statuses` setting is now honored: every board write maps the logical status (`todo`,
  `in_progress`, `in_review`, `blocked`, `done`) through it, so boards with differently named Status
  options work as the README troubleshooting entry says. Previously every call passed literal names.
- `octo-subissue.sh` now prints GitHub's actual `addSubIssue` error (already has a parent,
  permissions, limits) instead of reporting every failure as "API unavailable", and passes
  owner/name/node ids with `-f` so values like `true` or `2048` are not type-coerced (the gh
  cookbook recipe too).
- `octo-project-status.sh` no longer scans the whole board (`item-list --limit 2000`, which missed
  items past 2000) on every call — `item-add` already returns the existing item — and passes the
  status name to jq through the environment instead of splicing it into the program.
- `octo-doctor.sh` now prints the "no Status field" message when the field is missing; before, an
  empty result looked like success and the message only showed on a failed read.
- Every flag-taking helper exits 2 with a message when a flag has no value (the `set -e` ones exited
  1 silently), and `--help` prints only the usage block instead of every comment in the script.
- `octo-worktree.sh add` prints only the worktree path on stdout; git's `HEAD is now at …` went there
  first.
- `gh project list` / `field-list` calls pass an explicit `--limit 100`, so owners with more than 30
  boards, or boards with more than 30 fields, are no longer cut off.
- Fewer permission prompts on unattended runs: `implement`, `auto`, and `autopilot` pre-allow
  Grep/Glob, and `auto`'s `UNKNOWN` mergeability re-query is plain `gh` calls instead of a
  `for … sleep` loop, with no pause between attempts for now (a persistent `UNKNOWN` is held). The
  README documents allowing the repo's test command (plus `gh`/`git` for subagents). Steps written
  as compound shell commands can still prompt; #60 removes them and restores the re-query pause.
- Stale names left over from renames/removals: `review-pr` → `review`, `create-issue` → `issue`,
  `sync-status` → `sync`, and `issue-implementer`'s reference to the removed `pr` skill. README now
  has a marketplace install line and no longer claims `setup` takes `--dry-run`.

## [0.1.0] - 2026-06-23

### Added
- Initial release: autonomous GitHub-native execution for Claude Code.
- Skills: `setup`, `plan-epic`, `issue`, `start`, `pr`, `review`, `sync`, and the auto-loaded
  `github-conventions` knowledge layer (conventions, gh cookbook, settings schema).
- Agents: `issue-planner` and `pr-reviewer` (read-only; the skills perform the writes).
- Helper scripts: `octo-setup.sh`, `octo-doctor.sh`, `octo-subissue.sh`, `octo-project-status.sh`.
- Native sub-issue linking for epics (task-list fallback), `Closes #N` PR linking, self-approval-safe
  reviews, and optional, auto-detected Projects v2 board status.
- `CONTRIBUTING.md` with setup, conventions, and testing guidance.

[Unreleased]: https://github.com/zeikar/octoperator/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/zeikar/octoperator/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/zeikar/octoperator/releases/tag/v0.1.0
