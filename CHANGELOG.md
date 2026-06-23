# Changelog

All notable changes to Octoperator are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
