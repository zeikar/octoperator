# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
