# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `auto` now tidies up after each merge (#108). New helper `scripts/octo-after-merge.sh` takes
  the issue the PR closes as `--issue N`, rather than parsing the PR body, and acts only on a PR
  merged into the default branch. It waits about 10 seconds for GitHub to close the issue, and
  then closes it if still open, as completed, with the comment `Closed by #<pr> (merged)`. An
  issue once stayed open after its PR merged. Then it closes each epic of that issue, either the
  native sub-issue parent or an open `epic` issue whose `## Children` list has an item for it,
  once every child is closed, with a comment naming the PR. The children are the sub-issues, from
  any repo, and every list item there (`-`, `*`, `+`, or numbered, with or without a checkbox)
  together. An epic with an open child, with no children, or with an item that doesn't start
  with `#N` stays open; when such an item is all that holds it, the helper prints
  `warn: epic #E kept open: a ## Children item does not start with #N`. It never closes a pull
  request or any issue but `--issue`. It uses REST only (`gh api repos/...`), so it works in a
  Claude Code cloud session, which refuses GraphQL. It prints `closed issue #N`,
  `closed epic #E`, `warn: …`, or `nothing to close`, and exits 0 even when a call fails, since
  the merge already happened. Its lines fill a new Closed column in `auto`'s report, and
  `autopilot`'s per-cycle report and ledger summary name them (`merged #12 (closed epic #9)`).
  `auto` passes the issue it implemented, or with `--pr` the one issue the PR closes; a PR that
  closes no issue, such as a genesis milestone PR, gets no `--issue`, so nothing is closed for
  it. `plan-epic` now creates an epic's `## Children` section empty, and only ever adds
  `- [ ] #<child#>` lines to it. New offline tests in `scripts/test/after-merge.sh`, which CI
  runs, use a stub `gh` that serves REST and refuses GraphQL and porcelain with the cloud
  proxy's 403.
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
  `approval_paths: [".github/workflows/", ".claude/", "/GENESIS.md", "CLAUDE.md",
  "CLAUDE.local.md", "/.mcp.json"]` (all but the first since #102). A failing
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
  which CI runs; shellcheck now covers `skills/genesis/templates/**/*.sh`.
- `genesis` model-judged evals (#91): for a PRD with a `judge: model` scenario, `--approve` also
  writes `.github/workflows/evals-model.yml`, whose only trigger is `workflow_dispatch`, in two
  jobs with `timeout-minutes: 30` each, so the model key never shares a machine with the repo's
  code. The `evidence` job runs the stack's setup and `bash evals/run.sh --evidence <dir>`, which
  skips the script evals, runs each model eval's `check.sh` to build its evidence offline into
  `<dir>/<id>.txt`, and uploads it as an artifact; it gets no secret. The `judge` job
  (`needs: evidence`) runs no setup: a fresh checkout, the artifact, then
  `bash evals/run.sh --judge <dir>`, the only step with the key, which pins `EVALS_MAX_CALLS: 20`,
  `EVALS_MAX_PROMPT_BYTES: 200000`, and `EVALS_MODEL: claude-sonnet-5-5`. It takes the model
  evals, their scenario text, and the caps from its own checkout, reads the artifact only as
  data (a missing, empty, or symlinked file, or a prompt of scenario text and evidence over the
  byte cap or not valid UTF-8, fails that eval without a call; an extra file is ignored), and asks new template
  `evals/judge.sh` (one Anthropic Messages API call with curl, the key in a header file) for
  exactly `PASS` or `FAIL`; any other reply fails the eval.
  `run.sh --judge` refuses to start without the cap or the key, and once the cap is used fails
  each eval left without a call. The offline run still skips model evals without changing its
  exit code. Every eval, model-judged ones included, now needs a `check.sh`, in `--skeleton` and
  the guard. `octo-genesis-check.sh --skeleton` holds `evals-model.yml` to its template line for
  line (a `schedule:` or `push:` trigger, a removed or changed cap, byte cap, model, or timeout,
  or setup steps in the judge job fail), rejects a setup line, comment lines included, that
  holds `secrets` in any case, a backslash, or a non-ASCII byte (which could spell it) in any
  eval workflow, and a comment line anywhere in one that holds `${{`, and
  fails `evals-model.yml` when the PRD has no model scenario; `--values` prints
  `model_scenarios`, `model_call_cap`, and `model_timeout_minutes`, which the checkpoint, the
  plan, and the handoff show. Genesis never sets a secret or dispatches a workflow, and
  Octoperator's CI calls no model: the tests use a fake `curl`. `references/evals.md` documents
  the two jobs, the spend bound, that `approval_paths` holds only the merge (so the key belongs in
  a GitHub Environment restricted to `main`, a repo secret the fallback), what stays open (a
  self-hosted runner that reuses a machine, a dispatch from an unread branch), the
  deterministic/model split, and the caveat that a failing dispatch run stays the latest `eval`
  evidence until the next dispatch.
- `autopilot` records the eval pass rate as the ledger `metric` (#92). In a repo whose default
  branch has `.github/workflows/evals.yml` (detected by that path, not the workflow's name), the
  new `scripts/octo-evals-metric.sh` reads the latest completed default-branch run of that
  workflow, its jobs, and their check runs' annotations. It trusts exactly one annotation titled
  `evals-metric` whose message is exactly `passed=<P> total=<T>`, with P ≤ T and T ≥ 1, and the
  entry records `{"passed": P, "total": T}`. It reads only push and `workflow_dispatch` runs
  from this repo (never a fork's `pull_request` run), only `notice` annotations, and only when
  the run's conclusion agrees (`success` for P == T, `failure` for P < T), so a notice forged by
  setup code on a run where `run.sh` never printed can't claim every eval passes. Otherwise (no
  evals workflow, no completed run, no annotation, more than one, a malformed one, a conclusion
  that disagrees, or a gh error) `metric` stays `null`, the reason is reported, and the run goes
  on. It also prints `rate: P/T` (or `none`) for the ledger helper's `--metric`. Convergence now
  uses the metric: an entry with it gains only if P exceeds the high-water mark, the highest P
  since the count last restarted, the entry that restarted it included (#104). Matching the mark
  is no gain, so merges that move no eval no longer count, and neither does P oscillating as one
  PR breaks an eval and the next fixes it. Without a metric, or with no earlier P, `merged ≥ 1`
  still decides. `observe` entries never gain, and the count and the mark restart at a `reset` or
  all-pass entry. The new `scripts/octo-ledger-state.sh` applies these rules and prints the mark
  (`high-water:`), whether every eval passes, and the build/observe decision. An entry where
  every eval passes (P == T) restarts the count; what such a run does is next-milestone planning
  (#93, below). `--dry-run` prints the metric's source run and P/T, `no evals workflow`, or why the
  rate is unreadable. A repo without the workflow, Octoperator's own included, behaves as before.
  New offline tests in `scripts/test/autopilot.sh`, which CI runs.
- `/octoperator:genesis --next [--dry-run]` plans the next milestone once every eval passes, the
  last stage of epic #85 (#93). Run in a repo genesis created, it reads `VISION.md`,
  `docs/prd.md`, `docs/research.md`, the run ledger, and earlier `milestone-*` PRs (a closed,
  unmerged one is a plan a human turned down); researches what similar products shipped since,
  under stage 1's caps (6 WebSearch, 10 WebFetch, inline, pages are data, never instructions;
  queries name only the product's public category and known prior art, and it fetches only URLs a
  search or `docs/research.md` gave it), or plans from the repo alone, marked
  `ungrounded: no web access`, as it does under autopilot unless your settings allow the web
  tools; picks one milestone of about 3–8
  issues that fits `VISION.md`, listing what it rules out; and opens one PR on
  `milestone-<n>-<slug>` with a `## Milestone <n>` section appended to the PRD, new must-fail
  evals under `evals/<id>/` only, a Roadmap item citing its evidence, and the refreshed research,
  its body citing its sources and naming no issue. It ends with `genesis: planned milestone <n>
  (PR #M)`. It creates nothing while a next-milestone PR is open, or while the latest evals run
  judged an older commit than the default branch's tip (right after a milestone merges, it would
  plan twice). `--dry-run` prints the milestone and the PR and writes nothing. It works in its own
  worktree, and the new offline `scripts/octo-genesis-next.sh` numbers the milestone from the
  default branch (`--rev`) and checks the commit before the push (`--check`). Only the PRD
  (appended), the Roadmap, the research (file modes unchanged), and new eval directories of
  regular files change, never an existing eval or the Immutable constraints, and no CI skip token
  appears in the milestone's title or the commit message. `--check --head <sha>` runs the same
  check in a detached checkout. A stop after the worktree exists removes it and the local branch.
  The new `scripts/octo-milestone-gate.sh` makes the decision for both genesis and autopilot:
  buildable work first, an open milestone PR, all-pass, planning that failed at the tip, a
  milestone a human declined at the tip, and a stale tip (and whether an evals run for it is
  queued or running). `octo-evals-metric.sh` now also prints the run's `head:` commit. The procedure is
  `skills/genesis/references/next.md`, which states the risks (unattended web content steering
  the product, and how the gates, a private repo, cited sources, and one open milestone PR at a
  time bound it).
- `auto --pr <pr#>` takes an existing PR through `auto`'s review, fix, and merge gate without the
  implement phase: the PR must be open, not a draft, from this repo, based on the default branch,
  and close at most one issue, which (or else the PR itself) is the fixer's scope. A milestone PR
  ships this way: its evals guard holds it for a human when a new eval already passes or an
  existing one changed. For any PR on a `milestone-*` branch, `auto`'s merge gate also re-runs
  `octo-genesis-next.sh --check --head` on the reviewed commit and holds with `milestone check
  failed`, and its fixer gets the milestone rules as scope.
- `autopilot`, when every eval passes, first discovers work and builds any it finds. With nothing
  buildable, it asks the milestone gate. With no next-milestone PR open and the metric at the
  default branch's tip, it plans the next milestone with `genesis --next` and ships the PR with
  `auto --pr` in both modes: semi mode's one self-proposed merge, gated mechanically by the evals
  guard and the milestone check. The run ends with the new status line `autopilot: all evals pass
  → planning next milestone` (no longer a progress line). It observes instead, and a P == T run
  never ends a schedule, in four cases. While a milestone PR is open, it ends `stopped:
  next-milestone PR #<pr> open`. After a human closed the newest one unmerged at the same tip, it
  ends `stopped: next-milestone PR #<pr> declined`. After planning failed at the same tip in a
  way a retry would repeat (recorded in the entry's new optional `planning_failed` key; a network
  or `gh` failure isn't, so the next run retries), it ends `stopped: milestone planning failed at
  this tip`. While the metric is stale, it ends `stopped: evals metric stale`,
  first dispatching `evals.yml` once when no run for the tip is queued or running (never
  `evals-model.yml`). `--resume` or a new commit lifts the declined and failed cases. `autopilot`
  pre-allows no web tool: a skill's grant lasts the whole turn, which `research`, `implement`, and
  `auto` share. So it plans ungrounded unless your settings allow WebSearch and WebFetch, and
  `research` never uses them. The new `scripts/octo-web-allowed.sh` checks the settings: a bare
  allow entry for each tool, and no deny or ask rule naming either, bare or scoped. The all-pass
  procedure is in `skills/autopilot/references/milestone.md`. The ledger's entry, validity,
  convergence, and metric rules moved to `skills/autopilot/references/ledger.md`. New offline
  tests: the gate and the settings check in `scripts/test/autopilot.sh`, and
  `scripts/test/genesis-next.sh`, which CI runs.
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
- `implement` and `auto` push work early and resume a restarted issue (#109). A container restart
  in a Claude Code cloud session once lost an implementer's uncommitted work. The implementer (and
  `implement`'s in-tree path) now commits and pushes at checkpoints: once the first meaningful
  change exists, then after each passing test run. Each checkpoint is an ordinary conventional
  commit that references the issue (no `wip`, since regular merges keep every commit), pushed
  without force. When an issue's `<issue#>-<slug>` branch exists on the remote and a REST check
  (`gh api repos/<o>/<r>/pulls?head=<owner>:<b>&state=all`) finds no PR in any state for it,
  `implement` resumes on it instead of rejecting it: it starts from the branch's commits and its
  diff against the default branch. An issue with an open PR is still rejected, and so is a branch
  a closed or merged PR already used, since a human closed or shipped that work. A local branch
  left by a crashed run is reused when it matches the remote or is ahead of it; one that is behind
  or has diverged stops the issue for a human, and nothing is reset, deleted, or force-pushed. New
  `octo-worktree.sh attach --branch <b> --path <p>` fetches `origin/<b>` and creates a worktree
  on a local branch tracking it, refusing a branch checked out elsewhere; the parallel path uses
  it, and the in-tree path switches with plain `git` calls. `issue-implementer` gains a `resume`
  parameter, and its `Files changed` now counts every commit on the branch.

### Changed
- README reworked for discoverability (#120). The lede now calls Octoperator a Claude Code plugin
  and leads with the autonomous ship loop, followed by badges, a Quick start, and a short "Why
  Octoperator". The Components table has one line per command, and its full descriptions moved
  verbatim to `docs/commands.md`. "Running continuously" moved to `docs/running-continuously.md`,
  "Starting a new project" to `docs/genesis.md`, and the helper-script list to `CONTRIBUTING.md`;
  the skills' pointers and `genesis --approve`'s printed handoff link follow them. The plugin
  manifests take the new repo description and add the `claude-code`, `ai-agent`, `autonomous`,
  and `code-review` keywords. `docs/social-preview.html` is the source of the new 1280x640
  `docs/social-preview.png`.
- Issues, labels, and sub-issues now go over REST (`gh api repos/{o}/{r}/...`) in every skill and
  agent but `genesis`, so they work in a Claude Code cloud session, whose proxy refuses GraphQL
  (part of epic #79, #111). `issue`, `plan-epic`, `research`, `sync`, `implement`, `auto`,
  `autopilot`, `setup`, `issue-implementer`, `issue-planner`, the conventions' flaky-test
  procedure, and the cookbook no longer run `gh issue …` or `gh label …`. The cookbook's new
  "REST, not GraphQL" section sets the pattern: one plain `gh api` call where one call does the
  job, and a tested `scripts/octo-*.sh` helper where a step needs logic. Text goes in `-f`, and
  `-F` only for the numeric `milestone` and `sub_issue_id` and for a body. Every body (an issue,
  a comment, a `PATCH`) goes on stdin as `-F body=@-` with a quoted `<<'OCTO_BODY_EOF'` heredoc,
  so nothing in it is interpreted by the shell; only a short `-f title='…'` stays single-quoted,
  with `'` written `'\''`. Issue lists drop pull requests (`select(.pull_request == null)`) and
  page with `--paginate`, and a milestone is resolved to its number once. `octo-subissue.sh` links with `POST .../issues/<epic>/sub_issues` and the
  child's numeric `id`. It keeps its arguments, its success line, and its exit codes (1 on
  failure), and now also exits 2 on a malformed `--repo`, `--parent`, or `--child`. Labels are
  created only when missing, so an existing label's colour and description are no longer reset as
  `gh label create --force` did. Three new REST-only helpers do the steps that need logic.
  `octo-labels.sh` creates each missing label, with Octoperator's colour and description for its
  own labels (the cookbook's new label table, which `rest.sh` checks it against), and prints
  `created`, `exists`, or `failed` per label. `octo-issue-find.sh` finds
  open issues whose title or body contains a text, as a plain string, ignoring case. It stands in
  for `gh issue list --search`, since REST issue search isn't known to pass the cloud proxy.
  `octo-ledger-read.sh` is autopilot's ledger read command: the newest 20 entry-shaped comments
  from allowed authors and the skipped count, the same JSON as before. New offline tests in
  `scripts/test/rest.sh`, which CI runs, use a stub `gh` that serves REST, two items a page, and
  refuses GraphQL and porcelain with the cloud proxy's 403; they also run the cookbook's body
  recipes through bash and check the body arrives byte for byte. `smoke.sh` now fails if a skill
  or agent file outside `genesis` names `gh issue` or `gh label` (after any global flags), outside
  a one-line allowlist, or sends a body as a `-f` argument.
- The conventions gain a rule for a flaky test found mid-run, unrelated to the current issue.
  Re-run it at most twice more on the PR head and run it on the base (`origin/<default>`); one
  that passes on the base but fails on the head is a regression, fixed in the PR. A real flake
  gets a comment on an open issue that covers it, or a new issue labeled `bug`, one priority
  (`p2`, or `p1` when it fails CI on the default branch or blocks merges), and `flaky` where that
  label exists, with the test, the error, and every run. The PR's test status reports every run
  (`Result: fail (1 of 3), flaky per #<n>`); in a fix round, `auto` posts it as a PR comment. The
  test is never weakened, skipped, or retry-looped in the unrelated PR, and the merge gate still
  holds a PR until its checks are green. `implement`, `auto`, and `issue-implementer` point to
  it. Branch slugs, including `milestone-<n>-<slug>`, now drop trailing stop words (`a`, `and`,
  `as`, `each`, …) after the 50-character truncation, keeping at least one segment, so
  `add-seeded-hashing-as-a` becomes `add-seeded-hashing`. No script computes slugs, so only the
  docs change (#110).

### Fixed
- `setup` no longer stops at `gh auth status`, which checks every stored host and token and so
  can fail where the token in use works (seen in a Claude Code cloud session). `octo-setup.sh`
  probes with the repo lookups it needs instead, and an `error` now carries gh's own message as
  `detail` (printable ASCII only, in any locale). `octo-doctor.sh`, which setup runs to confirm a
  board, drops the same gate (`gh api user` is its probe), and the conventions no longer list
  `gh auth status` as a prerequisite. `setup` also writes
  `approval_paths: [".github/workflows/", ".claude/"]` in a new settings file, so adding or
  changing a workflow (a deploy included) or the committed Claude Code settings waits for a
  human, while an ordinary merge still deploys as before; a re-run keeps the existing value, and
  a settings file with no `approval_paths` still has no gate (#106).
- `auto`'s merge gate now holds, for a human, any PR that changes `VISION.md` outside its
  Roadmap body, or adds a Roadmap line that isn't plain text, not only `milestone-*` PRs (#102).
  New offline helper `scripts/octo-vision-guard.sh` compares the root `VISION.md` at the merge
  base with the reviewed commit, from git's objects, so no checkout is needed and the user's diff
  settings don't apply. It parses no Markdown; it allows instead of blocking. Everything before
  the Roadmap body (its `## Roadmap` line included) and from the next column-0 `#` or `##`
  heading on must keep the merge base's bytes, so Goal, Target users, Quality bar, and Immutable
  constraints change only through a human merge. Each Roadmap body line must not open with `<`,
  `#`, `>`, or a fence, be only `=` or `-` marks, or hold HTML (`<!--`, `-->`, `?>`, `]]>`, a
  tag) or a link definition, and the merge base must have one `## Roadmap` line and a body that
  passes the same rule, so where the body ends can be trusted. The file may hold no NUL, bare
  CR, other control byte, or Unicode line break, and must not be deleted, new, made a symlink,
  given another mode, or joined by a new or changed root name such as `vision.md`, which would
  replace it on a case-insensitive checkout. A repo with no `VISION.md`, one the PR leaves
  alone, and a plain Roadmap item pass. The hold reason is
  `VISION.md changed outside its Roadmap: a human merges this`. It applies to Octoperator's own
  repo too. `octo-genesis-next.sh --check` now runs its VISION.md rules through the same helper
  (`--milestone <n>`, which also needs a Roadmap item for the milestone). The genesis proposal
  check runs the guard's rule on the proposed `VISION.md` too (`--plain-roadmap <file>`), so a
  template `<placeholder>` or a `Result<T>` code span left in the Roadmap, or a NUL, bare CR,
  control byte, or Unicode line break anywhere in the file, fails at the human checkpoint
  rather than holding every later change; `genesis --next` stops with `milestone invalid` at
  once on a merge-base Roadmap it can't fix. Genesis's
  `approval_paths` adds `.claude/`, whose committed settings decide whether `genesis --next` may
  use the web under autopilot, `/GENESIS.md`, whose `test_command` drives the skeleton check, and
  `CLAUDE.md` and `CLAUDE.local.md` (at any depth) and `/.mcp.json`, which shape what an
  unattended Claude Code run does. `--approve` adds the missing ones to an existing settings file
  too. `docs/adr/` stays out: an issue may rightly add an ADR. A milestone PR touches none of
  these paths, so it still merges unattended. `octo-approval-match.sh` now ignores case
  (Unicode case folding, as macOS's file system does), so `.Claude/settings.local.json` matches
  `.claude/`.
  New offline tests in `scripts/test/vision.sh`, which CI runs.
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
