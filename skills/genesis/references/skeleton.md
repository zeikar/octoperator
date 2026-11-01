# Genesis skeleton

What `/octoperator:genesis --approve` writes into the project directory before the first commit,
and the settings file it writes once the repo exists.
`${CLAUDE_PLUGIN_ROOT}/scripts/octo-genesis-check.sh --skeleton <dir>` checks the skeleton; the
rules it enforces are marked **checked**.

Write each file only when it is missing. A file that exists is the human's, or a file an earlier
`--approve` run wrote and the human may have fixed after a failed test: keep it as it is.

The skeleton is the smallest project the ADR's stack needs, so its test command passes locally and
in CI. It has no product code beyond one module, and it installs nothing on your machine: the
module and test use only the language's standard library and the test runner. The MVP is built
later, through the MVP epic's issues, which `--approve` files by plan-epic's procedure once the
repo exists. The scenario evals are written in the same step: `evals/`, `evals.yml`, and
`evals-guard.yml`, from `references/evals.md`, which says what `--skeleton` checks in them.

## Files

- **`README.md`** — `# <directory name>`, the sentence from `GENESIS.md` as a `> ` quote, how to
  run the tests (`<test_command>`), and links to `VISION.md`, `docs/prd.md`, and
  `docs/adr/0001-stack.md`. **Checked:** it holds every line of the sentence.
- **`.gitignore`** — the stack's build and test output (`node_modules/`, `__pycache__/`,
  `.pytest_cache/`, `target/`, …), then Octoperator's local files. **Checked:** the lines
  `.claude/octoperator.local.md` and `.octoperator/`, a leading `/` allowed.
- **`.github/workflows/ci.yml`** — installs and tests on `push` and `pull_request`. **Checked:**
  both triggers, and a `run: <test_command>` step with `GENESIS.md`'s test command exactly.
- **The detection file** — the file that makes `issue-implementer` find `test_command`, from the
  table below. **Checked:** it exists and holds what detection needs, and no file of an earlier
  row exists: detection takes the first match, so that row's command would run instead.
- **One module and one test** — in the stack's usual layout. The test imports the module and
  checks one real behavior, so the test command passes because a test ran: `pytest` fails when it
  collects no test, and a runner that passes on zero tests proves nothing.
- **The scenario evals** — `evals/run.sh`, `evals/guard.sh`, `.github/workflows/evals.yml`,
  `.github/workflows/evals-guard.yml`, and one `evals/<id>/` per PRD scenario, as
  `references/evals.md` says. **Checked** there.

| `test_command` | Detection file holds | Must not exist | CI setup and install |
|---|---|---|---|
| `npm test` | `package.json`: `"scripts": {"test": …}`, e.g. `node --test` | — | `actions/setup-node`, `npm install` |
| `make test` | `Makefile`: a `test:` target that runs the stack's runner, beside the stack's manifest (`Cargo.toml`, …), which is committed too | `package.json` | the toolchain's setup, its install if any |
| `pytest` | `pyproject.toml`: a `[tool.pytest.ini_options]` table | `package.json`, `Makefile` | `actions/setup-python`, `pip install pytest` |
| `go test ./...` | `go.mod`: `module github.com/<repo>` | `package.json`, `Makefile`, `pyproject.toml` | `actions/setup-go` with `go-version-file: go.mod` |

`make test` is for a stack the other rows don't fit, such as Rust with `cargo test`: the target
runs the stack's own runner. The ADR's Consequences say what the skeleton needs; when they disagree
with this table, the table wins, and say so at the end of the run.

### `ci.yml`

The shape, for `npm test`; swap the setup and install steps for the stack's row:

```yaml
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm install
      - run: npm test
```

Workflow files are in `approval_paths` (below), so `auto` never merges a change to CI, the evals
workflow, or the evals guard without a human. `evals.yml` and `evals-guard.yml`'s `must-fail` job
take the same setup and install steps as `ci.yml` (`references/evals.md`).

## Settings

After `gh repo create`, genesis runs setup's procedure
(`${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md`) by reference, with fixed answers instead of
questions:

- **Probe** — `octo-setup.sh --repo <repo>`, as setup's step 1. An `error` stops the run.
- **Existing settings** — when `.claude/octoperator.local.md` exists and its `repo:` is
  `GENESIS.md`'s `repo` (case aside), keep it. If its `approval_paths` lacks
  `.github/workflows/`, add that one entry with Edit and change nothing else. Any other `repo:`,
  or none, is a file from another project: stop with `settings repo mismatch` before any label,
  so plan-epic never files issues in that repo. Genesis doesn't edit or delete it; the human
  does, then runs `--approve` again.
- **Board** — none, whatever the probe says. The human can run `/octoperator:setup` later to add
  one.
- **Write** — otherwise, write the file below (schema:
  `${CLAUDE_PLUGIN_ROOT}/skills/github-conventions/references/settings.md`).
- **Exclude** — skipped: the skeleton's `.gitignore` already lists both local paths, and genesis
  writes that file itself, unlike setup in an existing repo.
- **Labels** — yes: the cookbook's "Ensure labels exist" labels, one `gh label create … --force`
  call each, so a re-run updates them instead of failing.

```markdown
---
# Written by /octoperator:genesis --approve, following settings.md. No board: run
# /octoperator:setup to add one.

# Target repository (owner/name).
repo: <repo>

# Branch name pattern. Tokens: {number}, {slug}.
branch_pattern: "{number}-{slug}"

# Status names; used only once a board is added.
statuses:
  todo: Todo
  in_progress: In Progress
  in_review: In Review
  blocked: Blocked
  done: Done

# Files a human must approve: auto holds any PR that touches one. This covers
# .github/workflows/evals-guard.yml; evals/ stays out, so PRs that only add
# must-fail evals merge (the guard holds the rest).
approval_paths:
  - ".github/workflows/"
---

# Notes
Free-form project notes for humans; Octoperator ignores this section.
```
