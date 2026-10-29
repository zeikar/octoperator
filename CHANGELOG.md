# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `implement` skill (`/octoperator:implement`): take one or more issues from issue to PR — a single
  issue inline in the current tree, or many in parallel git worktrees (capped by `--max`, default 3).
- `issue-implementer` agent: write-capable subagent that implements one issue inside a pre-created
  worktree and opens its own `Closes #N` PR (never writes the board).
- `octo-worktree.sh` helper: explicit per-issue worktree lifecycle (`add` / `remove` / `list`).
- `auto` skill (`/octoperator:auto`): full lifecycle end-to-end — implement → review → merge — for one
  or more issues. Merges use a regular merge commit (history preserved) and are gated on the PR being
  mergeable with passing required checks.
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
- Project `.claude/settings.json` that loads the checked-out plugin (`octoperator@zeikar-plugins`
  from a `directory` marketplace) when Claude Code opens in the repo, for dogfooding.

### Changed
- README: the skills table is now grouped by purpose (onboarding, plan & intake, autonomous lifecycle,
  review & status, what's next, knowledge layer) so the entry points are easier to scan.

### Removed
- `start` and `pr` skills (`/octoperator:start`, `/octoperator:pr`): redundant manual single-step
  primitives. `implement` / `auto` cover branch → code → PR end-to-end and set both `In Progress` and
  `In Review` board transitions; branch-naming and PR-linking conventions live in `github-conventions`,
  so nothing was orphaned. Consolidates Octoperator on its autonomous-first lifecycle.

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

[Unreleased]: https://github.com/zeikar/octoperator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/zeikar/octoperator/releases/tag/v0.1.0
