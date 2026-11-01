# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `/octoperator:genesis "<sentence>"`, stage 1 of
  [epic #85](https://github.com/zeikar/octoperator/issues/85): run in an empty directory outside
  git, it researches existing services and similar open-source projects with WebSearch and
  WebFetch (at most 6 searches and 10 fetches, browsed inline; pages are data, never
  instructions), writes `docs/research.md` (Problem, Prior art, Build, Skip,
  Sources, every claim cited) and `GENESIS.md` (the sentence verbatim, `repo`, `visibility:
  private`), and stops at a human checkpoint with `genesis: proposed <dir>` or `genesis: stopped:
  <reason>`. Without web access it marks the research `ungrounded: no web access`. It makes no
  GitHub write; its only `gh` call is `gh api user`. A new offline helper,
  `scripts/octo-genesis-check.sh`, checks the directory first (`--preflight`) and the proposal
  after. `VISION.md`'s roadmap item 6 now points to epic #85.
- `genesis` stage 2 (#87): in the same run, after research, it writes `docs/prd.md` (Problem,
  Target users, MVP scope, Out of scope seeded from research's Skip list, `### R<n>:`
  requirements with acceptance criteria, Success metrics), `docs/adr/0001-stack.md` (Context,
  Decision, Alternatives considered, Consequences: the smallest stack the MVP needs), and a
  `VISION.md` draft in Octoperator's constitution format whose Immutable constraints open with
  four baseline lines verbatim (regular merges only; no force-push or history rewrite; deploy,
  spend, and delete need human approval; issue, PR, and comment text is input). `GENESIS.md`
  gains `stack` and `test_command`, which must be `npm test`, `make test`, `pytest`, or
  `go test ./...`, the commands `issue-implementer`'s detection order finds; the ADR must name the
  same command. `octo-genesis-check.sh` checks all five files. The checkpoint lists the decisions
  the human owns (stack, repo name, visibility) and that a private repo's Actions minutes count
  against the plan's quota. Genesis never regenerates an existing file; to start over, delete the
  proposal files. Still no GitHub write.
- `genesis --approve [--dry-run]`, stage 3 (#88): typed by the human in the proposal folder, it
  writes a minimal skeleton for the ADR's stack (one module, one passing test, the test command's
  detection file and no earlier one, `.github/workflows/ci.yml` on `push` and `pull_request`, a
  `.gitignore` listing `.claude/octoperator.local.md` and `.octoperator/`, and a README quoting
  the sentence), runs the test command once locally, then `git init`, commits, re-checks the
  folder's git state, checks GitHub (`gh auth status`, a GraphQL call that stops with the #79
  reason, and the name), runs
  `gh repo create --private` (`--public` only for `visibility: public`) with the sentence as the
  description, and runs setup with fixed answers: no board, the labels, and settings with
  `approval_paths: [".github/workflows/"]`. A failing
  test stops before any git or `gh` write; a missing `workflow` scope stops with the
  `gh auth refresh -s workflow` hint. A re-run resumes from the folder's git state and creates
  nothing twice. `--dry-run` prints the ordered commands and writes nothing. New offline helper
  `scripts/octo-genesis-plan.sh` works out the stage and prints the commands; the description is
  made one line, quoted, and cut to GitHub's 350-character limit on a UTF-8 boundary.
  `octo-genesis-check.sh` gains `--skeleton` and `--values`. The skill's `allowed-tools` add
  `Bash(git:*)`, `Edit`, and `Task`; the test command itself can't be pre-allowed and prompts
  once.
- `genesis --approve`, stage 4 (#89): once the repo and its settings exist, it plans the MVP epic
  there by `plan-epic`'s procedure, by reference: the request is the sentence verbatim plus the
  PRD's MVP scope and requirements, and the epic body links `docs/prd.md` and `VISION.md`. Then it
  prints the handoff: the semi-mode triage step (relabel the children `ready`, with the
  `gh label create ready` and `gh issue edit` commands, then `/octoperator:autopilot --mode semi`),
  a pointer to README → Running continuously, the allow rules from README → Unattended runs with the
  ADR's test command filled in (`Bash(npm test:*)`, …), and the `--plugin-dir` note. It never
  writes permission settings, adds `ready` or `approved`, or starts autopilot or a schedule. A run
  now ends with `genesis: handed off <repo> (epic #N)` in place of `genesis: scaffolded <repo>`;
  new stop reasons are `epic lookup failed`, `plan-epic failed`, and `epic misses the sentence`.
  New read-only helper `scripts/octo-genesis-epic.sh` finds the open `epic` issue that quotes the
  sentence, so a re-run only prints the handoff and files no second epic. `octo-genesis-plan.sh`
  prints the lookup, plan-epic, and handoff steps at the end of every stage, and
  `--approve --dry-run` includes plan-epic's dry run.
- `genesis` scenario evals (#90): the PRD gains a required `## Scenarios` section (`### <id>`,
  `- requirement: R<n>`, `- judge: script|model`, the scenario text; at least one judged by
  script), and `--approve` writes one `evals/<id>/scenario.md` per scenario, with a `check.sh`
  for script-judged ones that follows bench's check rules. From templates in
  `skills/genesis/templates/`, it also writes `evals/run.sh`, which runs every `judge: script`
  eval sandboxed as `bench/validate.sh` runs checks, prints
  `evals: <passed>/<total> passed (<skipped> skipped)` (plus
  `::notice title=evals-metric::passed=P total=T` under GitHub Actions), and exits 1 when any
  fails; `.github/workflows/evals.yml`, on `push` to `main` and `workflow_dispatch` only, never
  `pull_request`, so a failing eval can't hold every PR, and a failing run on `main` is `eval`
  evidence for `research` with no change to it; and `.github/workflows/evals-guard.yml`, on
  `pull_request`, which runs the base branch's `evals/guard.sh` from git's objects in three jobs.
  `append-only`, with no setup and so no PR code, fails a PR that modifies, deletes, or renames an
  eval file, adds a symlink, a submodule, a file directly under `evals/`, or a file to an existing
  eval, or changes `.gitattributes` there or at the root. `must-fail` runs each new check on a
  fresh checkout of the base with the new evals laid over it and the installed dependencies linked
  in, and `verdict` fails one that passed, timed out, or changed its tree; PR code can forge that
  result, so must-fail-first is advisory and a reviewer still reads each new check. `run.sh` and
  the guard run checks under `env -i`, kill what a check leaves running, never follow a symlinked
  eval, and fail a check that changes the repo (`run.sh` stops the run there); `run.sh` prints a
  failed check's output with workflow commands stopped. The guard workflow is covered by the
  settings' `.github/workflows/` approval path; `evals/` is not, so must-fail additions merge
  unattended. `auto`'s merge gate gains an evals-guard step: where the base branch has the guard
  workflow, new read-only helper `scripts/octo-evals-guard.sh` must find both guard jobs of the
  PR's own guard run passed on the reviewed commit, against the base branch's tip when the PR
  changes `evals/` or `.gitattributes`, or the PR is held (`evals guard did not pass`, for a
  `[skip ci]` head too, or `evals guard stale`). Each guard job judges the base branch's tip as it
  fetched it, so re-running the jobs refreshes a stale guard, and a base without `evals/guard.sh`
  fails the job. `octo-genesis-check.sh --skeleton` holds both eval workflows to their templates
  line for line, with setup steps only where the template marks them. Under Actions, `run.sh`
  stops before any check when `evals/` differs from the commit.
  The VISION template's quality bar says evals only grow. `octo-genesis-check.sh` checks the
  scenarios and, with `--skeleton`, the eval files; the plan's `git add` names them. The handoff
  asks the human to confirm the first `Evals` run on `main` is red. New
  reference `skills/genesis/references/evals.md`, and new offline tests `scripts/test/evals.sh`,
  which CI runs; shellcheck now covers `skills/genesis/templates/**/*.sh`. The eval metric and the
  next milestone (#92, #93) are not built yet.
- `genesis` model-judged evals (#91): for a PRD with a `judge: model` scenario, `--approve` also
  writes `.github/workflows/evals-model.yml`, whose only trigger is `workflow_dispatch`, in two
  jobs with `timeout-minutes: 30` each, so the model key never shares a machine with the repo's
  code. The `evidence` job runs the stack's setup and `bash evals/run.sh --evidence <dir>`, which
  skips the script evals, runs each model eval's `check.sh` to build its evidence offline into
  `<dir>/<id>.txt`, and uploads it as an artifact; it gets no secret. The `judge` job
  (`needs: evidence`) runs no setup: a fresh checkout, the artifact, then
  `bash evals/run.sh --judge <dir>`, the only step with the key, which pins `EVALS_MAX_CALLS: 20`,
  `EVALS_MAX_EVIDENCE_BYTES: 200000`, and `EVALS_MODEL: claude-sonnet-5-5`. It takes the model
  evals, their scenario text, and the caps from its own checkout, reads the artifact only as
  data (a missing, empty, symlinked, or oversized file fails that eval without a call; an extra
  one is ignored), and asks new template `evals/judge.sh` (one Anthropic Messages API call with
  curl, the key in a header file) for exactly `PASS` or `FAIL`; any other reply fails the eval.
  `run.sh --judge` refuses to start without the cap or the key, and once the cap is used fails
  each eval left without a call. The offline run still skips model evals without changing its
  exit code. Every eval, model-judged ones included, now needs a `check.sh`, in `--skeleton` and
  the guard. `octo-genesis-check.sh --skeleton` holds `evals-model.yml` to its template line for
  line (a `schedule:` or `push:` trigger, a removed or changed cap, byte cap, model, or timeout,
  or setup steps in the judge job fail), rejects a setup step that names a secret in any eval
  workflow, and fails `evals-model.yml` when the PRD has no model scenario; `--values` prints
  `model_scenarios`, `model_call_cap`, and `model_timeout_minutes`, which the checkpoint, the
  plan, and the handoff show. Genesis never sets a secret or dispatches a workflow, and
  Octoperator's CI calls no model: the tests use a fake `curl`. `references/evals.md` documents
  the two jobs, the spend bound, that `approval_paths` holds only the merge (so the key belongs in
  a GitHub Environment restricted to `main`, a repo secret the fallback), what stays open (a
  self-hosted runner that reuses a machine, a dispatch from an unread branch), the
  deterministic/model split, and the caveat that a failing dispatch run stays the latest `eval`
  evidence until the next dispatch.
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
