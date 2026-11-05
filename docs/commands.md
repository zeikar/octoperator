# Command reference

What each skill does, in full. The [README](../README.md#commands) has the one-line summary.

## genesis

**`/octoperator:genesis "<sentence>"`**

Start a new project from one sentence, in an empty directory outside git: research existing services
and similar open-source projects (at most 6 web searches and 10 page fetches), write a local
proposal (`GENESIS.md`, `docs/research.md`, a PRD, a stack ADR, and a `VISION.md` draft), and stop
at a human checkpoint with `genesis: proposed <dir>`. Makes no GitHub write.

**`/octoperator:genesis --approve [--dry-run]`**

Re-run in the proposal folder once you've reviewed it: write a minimal skeleton (one module, one
passing test, CI, `.gitignore`, README) and offline scenario evals (one per PRD scenario, run on
pushes to `main`, with an append-only guard on PRs), run its test once, commit, create the
**private** repo with `gh repo create`, write the Octoperator settings and labels, plan the MVP epic
there with `plan-epic`'s procedure, and print the autopilot handoff (semi-mode triage, the
scheduling recipes, the allow rules); ends with `genesis: handed off <repo> (epic #N)`. It never
starts autopilot or adds `ready`. `--dry-run` prints every command and plan-epic's dry run, and
writes nothing (see [Starting a new project](genesis.md)).

**`/octoperator:genesis --next [--dry-run]`**

In a repo genesis created, once every eval passes on `main`'s tip and no next-milestone PR is open:
research the web (the same caps; `ungrounded` without web access, and under autopilot unless your
settings allow the web tools), pick one milestone that fits `VISION.md`, and open one PR on
`milestone-<n>-<slug>` with a `## Milestone <n>` PRD section, new must-fail evals only, and a cited
Roadmap item; ends with `genesis: planned milestone <n> (PR #M)`. It never merges (`auto --pr` does)
and never touches an existing eval or the Immutable constraints. `--dry-run` prints the milestone
and the PR, and writes nothing.

## setup

**`/octoperator:setup [--repo OWNER/NAME]`**

One-time onboarding: detect repo, auto-detect Projects v2 access, optionally create/link a board,
write `.claude/octoperator.local.md`.

## plan-epic

**`/octoperator:plan-epic <request> [--dry-run]`**

Decompose a request into an epic + linked child issues, milestone, labels, board items.

## issue

**`/octoperator:issue <request> [--dry-run]`**

Create one well-formed issue (labels, acceptance criteria, milestone, board).

## implement

**`/octoperator:implement <issue#...> [--max N] [--draft] [--dry-run]`**

Implement one or more issues end-to-end: branch, code, test, and PR. Single issue runs in-tree;
multiple issues run in parallel worktrees (up to `--max`, default 3).

## auto

**`/octoperator:auto <issue#...> [--max N] [--dry-run]`** · **`/octoperator:auto --pr <pr#> [--dry-run]`**

End-to-end lifecycle: implement → review → merge for one or more issues. Blocker/major/minor review
findings trigger up to 6 fix → re-review rounds; merges (regular merge) only on a non-blocking
review of the current head + CI green + mergeable. A PR that touches an `approval_paths` glob is
held for a human (`needs human approval: <path>`), and so is one that changes `VISION.md`'s
Immutable constraints. After a merge it closes the issue if GitHub left it open, and the epic once
its last child is closed. `--pr <pr#>` skips implement and takes an existing PR, such as a
next-milestone PR, through the same review, fix, and merge gate.

## autopilot

**`/octoperator:autopilot [--mode semi|full] [--cycles N] [--max M] [--resume] [--dry-run]`**

Bounded loop: discover work → `auto` (implement→review→merge) → when empty, `research` refills.
`semi` builds only `ready` issues then proposes; `full` runs unattended to the cycle cap. In both
modes a `needs-approval` issue is skipped (reported as gated) until a human adds `approved`. Each
run appends an entry to an `octoperator-ledger` issue; after `convergence_runs` runs (default 3)
without a gain it switches to observe mode (propose only, no builds) until `--resume`. A gain is
more evals passing than at any point since the count last restarted (the high-water mark) in a repo
with genesis's evals, which the entry records as its `metric`, and otherwise a merge; when every
eval passes and nothing is buildable, it plans the next milestone with `genesis --next`, ungrounded
unless your settings allow the web tools, and ships the PR with `auto --pr` in either mode. Then it
ends `autopilot: all evals pass → planning next milestone`. It observes instead while a
next-milestone PR is open, after you declined one at the same tip, after planning failed at the same
tip, or while the evals run hasn't judged `main`'s tip yet. In that last case it dispatches
`evals.yml` once when no run for the tip is queued or running. Every run ends with an `autopilot: …`
status line, and a run started by an in-session cron task or `/loop` ends that schedule once there
is nothing left to do (see [Running continuously](running-continuously.md)).

## review

**`/octoperator:review <pr#> [--approve|--request-changes|--comment] [--dry-run]`**

Run a structured review and post the verdict + findings to the PR.

## sync

**`/octoperator:sync [--dry-run]`**

Standup-style status report; auto-reconciles board drift.

## research

**`/octoperator:research [--create] [--count N] [--focus <feature|refactor|debt|tests|docs|dx|all>] [--dry-run]`**

Analyze the repo and produce a ranked list of proposals balanced across features, refactoring, tech
debt, tests, docs, and DX; with `--create`, file the top ones as `proposed` issues — only proposals
backed by verifiable evidence (a benchmark result, failing CI, a held PR or autopilot ledger entry,
or user feedback). Proposals that would deploy, spend money, or delete data also get
`needs-approval`.

## github-conventions

**`github-conventions` *(auto-loaded)***

Source-of-truth conventions, `gh` cookbook, settings schema shared by all actions.
